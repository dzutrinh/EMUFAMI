{*+
	F_CPU.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The 2A03's 6502: 151 official and 93 unofficial opcodes, NMI,
	IRQ, BRK, OAM DMA.  Each bus access one cycle (rd, wr), the
	chip's dummy reads and writes included; N and Z kept as the
	value that set them.  Interrupts between instructions, with the
	I flag CLI, SEI and PLP left for the poll (i_poll).  The run's
	end, NMI, IRQ, DMA and the DMC's stalls looked at only at events
	(bus_next_event).  Each opcode its own procedure, found in a
	table (OPS).
-*}
{$X+}
{$ifdef FPC}{$modeswitch classicprocvars}{$endif}	{ OPS as BP7 and TMT write it }
{$S-}		{ no stack check at every call }
unit	f_cpu;

interface

uses
	f_sys;

{ the registers and flags as U16: words for BP7's 16-bit code }
type
	CPU_REGS	= record
		a, x, y, s, pc	: U16;
		c, i, d, v		: U16;		{ 0 or 1 }
		n, z			: U16;		{ N: bit 7 of n; Z: z = 0 }
		jammed			: boolean;
		jam_op			: longint;
	end;

var
	cpu		: CPU_REGS;
	i_poll	: longint;	{ the I flag the next poll sees, -1: cpu.i }

procedure	cpu_start;			{ nothing to make: kept for the callers }
procedure	cpu_power;			{ registers cleared, the reset vector; 7 cycles }
procedure	cpu_reset;			{ the reset button }
function	cpu_p: U16;			{ the flags, bit 5 set, B clear }
procedure	cpu_set_p(p: U16);
procedure	cpu_step;			{ one instruction, or one interrupt taken }
procedure	cpu_run(until_cycle: longint);	{ steps until cycles reaches it }

implementation

uses
	f_map, f_bus, f_ppu, f_apu;

var
	run_until	: longint;
	irq_seen	: longint;	{ bus_irq_at as the last event left it }
	sh_high		: U16;		{ the base's high byte as the last indexed wrt left it (SHA, SHX, SHY, TAS) }

{ ---- one cycle each ---- }

{ a byte read: plain memory through the page map, else the bus }
function	rd(addr: U16): U16;
var	p	: PBYTE;
	v	: U16;
begin
	inc(cycles);
	p := bus_rpage[addr shr 11];
	if p <> nil then
	begin
		v := PBYTES(p)^[addr];
		bus_open := v;
		rd := v;
	end
	else	rd := bus_read(addr);
end;

procedure	wr(addr, v: U16);
var	p	: PBYTE;
begin
	inc(cycles);
	p := bus_wpage[addr shr 11];
	if p <> nil then
	begin
		PBYTES(p)^[addr] := v;
		bus_open := v;
	end
	else	bus_write(addr, v);
end;

{ the byte at PC, PC on (rd's work done here: the call saved) }
function	fetch: U16;
var	p	: PBYTE;
	v	: U16;
begin
	p := bus_rpage[cpu.pc shr 11];
	if p <> nil then
	begin
		inc(cycles);
		v := PBYTES(p)^[cpu.pc];
		bus_open := v;
	end
	else	v := rd(cpu.pc);
	cpu.pc := (cpu.pc + 1) and $FFFF;
	fetch := v;
end;

{ the two bytes at PC (an address, low byte first), PC on: at once when
  both are plain memory on one page, as two fetches would read them }
function	fetch2: U16;
var	p	: PBYTE;
	lo	: U16;
begin
	p := bus_rpage[cpu.pc shr 11];
	if (p <> nil) and (cpu.pc and $7FF <> $7FF) then
	begin
		inc(cycles, 2);
		lo := PBYTES(p)^[cpu.pc];
		bus_open := PBYTES(p)^[cpu.pc + 1];
		cpu.pc := (cpu.pc + 2) and $FFFF;
		fetch2 := lo or bus_open shl 8;
	end
	else
	begin
		lo := fetch;
		fetch2 := lo or fetch shl 8;
	end;
end;

{ an implied instruction's second cycle: PC read again, the byte let go }
procedure	implied;
begin
	rd(cpu.pc);
end;

{ the stack: always RAM }
procedure	push(v: U16);
begin
	inc(cycles);
	ram[$100 + cpu.s] := v;
	bus_open := v;
	cpu.s := (cpu.s - 1) and $FF;
end;

function	pop: U16;
var	v	: U16;
begin
	cpu.s := (cpu.s + 1) and $FF;
	inc(cycles);
	v := ram[$100 + cpu.s];
	bus_open := v;
	pop := v;
end;

{ ---- the flags ---- }

function	cpu_p: U16;
var	p	: U16;
begin
	p := (cpu.n and $80) or cpu.v shl 6 or $20 or cpu.d shl 3 or cpu.i shl 2 or cpu.c;
	if cpu.z and $FF = 0 then p := p or 2;
	cpu_p := p;
end;

procedure	cpu_set_p(p: U16);
begin
	cpu.n := p;
	cpu.v := (p shr 6) and 1;
	cpu.d := (p shr 3) and 1;
	cpu.i := (p shr 2) and 1;
	cpu.z := (not p) and 2;
	cpu.c := p and 1;
end;

procedure	set_nz(v: U16);
begin
	cpu.n := v;
	cpu.z := v;
end;

{ ---- where the operand is: its address ---- }

function	ea_zp: U16;
begin
	ea_zp := fetch;
end;

{ zero page indexed: the base read while the index is added }
function	ea_zpi(index: U16): U16;
var	b	: U16;
begin
	b := fetch;
	rd(b);
	ea_zpi := (b + index) and $FF;
end;

function	ea_abs: U16;
begin
	ea_abs := fetch2;
end;

{ base + index: the read made before the carry reaches the high byte -
  only when the page is crossed for a read, always for a wrt (whose
  base's high byte SHA, SHX, SHY and TAS use) }
function	cross(base, index: U16; wrt: boolean): U16;
var	a	: U16;
begin
	a := (base + index) and $FFFF;
	if wrt or ((base xor a) and $FF00 <> 0) then rd((base and $FF00) or (a and $FF));
	if wrt then sh_high := base and $FF00;
	cross := a;
end;

function	ea_absi(index: U16; wrt: boolean): U16;
begin
	ea_absi := cross(ea_abs, index, wrt);
end;

{ (zp,X): the pointer read, X added, its two bytes read in the zero page }
function	ea_izx: U16;
var	b, lo	: U16;
begin
	b := fetch;
	rd(b);
	b := (b + cpu.x) and $FF;
	lo := rd(b);
	ea_izx := lo or rd((b + 1) and $FF) shl 8;
end;

{ (zp),Y }
function	ea_izy(wrt: boolean): U16;
var	b, lo	: U16;
begin
	b := fetch;
	lo := rd(b);
	lo := lo or rd((b + 1) and $FF) shl 8;
	ea_izy := cross(lo, cpu.y, wrt);
end;

{ ---- what the instructions do ---- }

procedure	lda(v: U16);
begin
	cpu.a := v;
	cpu.n := v;
	cpu.z := v;
end;

procedure	adc(v: U16);
var	t	: U16;
begin
	t := cpu.a + v + cpu.c;
	cpu.v := ((cpu.a xor t) and not (cpu.a xor v) and $80) shr 7;
	cpu.c := t shr 8;
	lda(t and $FF);
end;

procedure	sbc(v: U16);
begin
	adc(v xor $FF);
end;

procedure	compare(reg, v: U16);
begin
	cpu.c := ord(reg >= v);
	set_nz((reg - v) and $FF);
end;

procedure	f_bit(v: U16);
begin
	cpu.n := v;
	cpu.z := v and cpu.a;
	cpu.v := (v shr 6) and 1;
end;

{ the shifts and steps, N and Z set }
function	f_asl(v: U16): U16;
begin
	cpu.c := v shr 7;
	v := (v shl 1) and $FF;
	set_nz(v);
	f_asl := v;
end;

function	f_lsr(v: U16): U16;
begin
	cpu.c := v and 1;
	v := v shr 1;
	set_nz(v);
	f_lsr := v;
end;

function	f_rol(v: U16): U16;
var	c	: U16;
begin
	c := v shr 7;
	v := ((v shl 1) or cpu.c) and $FF;
	cpu.c := c;
	set_nz(v);
	f_rol := v;
end;

function	f_ror(v: U16): U16;
var	c	: U16;
begin
	c := v and 1;
	v := (v shr 1) or cpu.c shl 7;
	cpu.c := c;
	set_nz(v);
	f_ror := v;
end;

{ read-modify-wrt: read, the old value written back, the new written -
  the chip's three steps.  kind: the operation }
const
	K_ASL	= 0;
	K_ROL	= 1;
	K_LSR	= 2;
	K_ROR	= 3;
	K_DEC	= 4;
	K_INC	= 5;

function	rmw(addr, kind: U16): U16;
var	v	: U16;
begin
	v := rd(addr);
	wr(addr, v);
	case kind of
	K_ASL:	v := f_asl(v);
	K_ROL:	v := f_rol(v);
	K_LSR:	v := f_lsr(v);
	K_ROR:	v := f_ror(v);
	K_DEC:	begin
			v := (v - 1) and $FF;
			set_nz(v);
		end;
	K_INC:	begin
			v := (v + 1) and $FF;
			set_nz(v);
		end;
	end;
	wr(addr, v);
	rmw := v;
end;

{ a branch: the offset read; taken, a read at PC, and one more when the
  page changes }
procedure	branch(taken: boolean);
var	off, t	: U16;
begin
	off := fetch;
	if not taken then exit;
	if off >= $80 then dec(off, $100);
	rd(cpu.pc);
	t := (cpu.pc + off) and $FFFF;
	if (t xor cpu.pc) and $FF00 <> 0 then rd((cpu.pc and $FF00) or (t and $FF));
	cpu.pc := t;
end;

{ NMI, IRQ and BRK: the return address and the flags pushed (b: the B
  flag), I set, the vector read }
procedure	take_interrupt(vector, b: U16);
var	lo	: U16;
begin
	push(cpu.pc shr 8);
	push(cpu.pc and $FF);
	push(cpu_p or b);
	cpu.i := 1;
	lo := rd(vector);
	cpu.pc := lo or rd(vector + 1) shl 8;
end;

{ SHA, SHX, SHY, TAS: v and'ed with the base's high byte + 1, written; a
  page crossed puts that value in the address's high byte }
procedure	sh_store(addr, v: U16);
begin
	v := v and ((sh_high shr 8) + 1);
	if addr and $FF00 <> sh_high then addr := (addr and $FF) or v shl 8;
	wr(addr, v);
end;

{ ---- the instructions: a procedure each, run through the opcode
  table (OPS) - one lookup and a call, where a case statement of 244
  labels makes BP7 and TMT compare them one by one ---- }

type	OP_PROC	= procedure;

{$ifdef VER70}{$F+}{$endif}	{ called through OPS: far under BP7 }

{ loads, stores, transfers }
procedure	lda_imm;	begin lda(fetch); end;	{ $A9: LDA IMM }
procedure	lda_zp;		begin lda(rd(ea_zp)); end;	{ $A5: LDA ZP }
procedure	lda_zpx;	begin lda(rd(ea_zpi(cpu.x))); end;	{ $B5: LDA ZPX }
procedure	lda_abs;	begin lda(rd(ea_abs)); end;	{ $AD: LDA ABS }
procedure	lda_abx;	begin lda(rd(ea_absi(cpu.x, FALSE))); end;	{ $BD: LDA ABX }
procedure	lda_aby;	begin lda(rd(ea_absi(cpu.y, FALSE))); end;	{ $B9: LDA ABY }
procedure	lda_izx;	begin lda(rd(ea_izx)); end;	{ $A1: LDA IZX }
procedure	lda_izy;	begin lda(rd(ea_izy(FALSE))); end;	{ $B1: LDA IZY }
procedure	ldx_imm;	begin cpu.x := fetch; set_nz(cpu.x); end;	{ $A2: LDX IMM }
procedure	ldx_zp;		begin cpu.x := rd(ea_zp); set_nz(cpu.x); end;	{ $A6: LDX ZP }
procedure	ldx_zpy;	begin cpu.x := rd(ea_zpi(cpu.y)); set_nz(cpu.x); end;	{ $B6: LDX ZPY }
procedure	ldx_abs;	begin cpu.x := rd(ea_abs); set_nz(cpu.x); end;	{ $AE: LDX ABS }
procedure	ldx_aby;	begin cpu.x := rd(ea_absi(cpu.y, FALSE)); set_nz(cpu.x); end;	{ $BE: LDX ABY }
procedure	ldy_imm;	begin cpu.y := fetch; set_nz(cpu.y); end;	{ $A0: LDY IMM }
procedure	ldy_zp;		begin cpu.y := rd(ea_zp); set_nz(cpu.y); end;	{ $A4: LDY ZP }
procedure	ldy_zpx;	begin cpu.y := rd(ea_zpi(cpu.x)); set_nz(cpu.y); end;	{ $B4: LDY ZPX }
procedure	ldy_abs;	begin cpu.y := rd(ea_abs); set_nz(cpu.y); end;	{ $AC: LDY ABS }
procedure	ldy_abx;	begin cpu.y := rd(ea_absi(cpu.x, FALSE)); set_nz(cpu.y); end;	{ $BC: LDY ABX }
procedure	sta_zp;		begin wr(ea_zp, cpu.a); end;	{ $85: STA ZP }
procedure	sta_zpx;	begin wr(ea_zpi(cpu.x), cpu.a); end;	{ $95: STA ZPX }
procedure	sta_abs;	begin wr(ea_abs, cpu.a); end;	{ $8D: STA ABS }
procedure	sta_abx;	begin wr(ea_absi(cpu.x, TRUE), cpu.a); end;	{ $9D: STA ABX }
procedure	sta_aby;	begin wr(ea_absi(cpu.y, TRUE), cpu.a); end;	{ $99: STA ABY }
procedure	sta_izx;	begin wr(ea_izx, cpu.a); end;	{ $81: STA IZX }
procedure	sta_izy;	begin wr(ea_izy(TRUE), cpu.a); end;	{ $91: STA IZY }
procedure	stx_zp;		begin wr(ea_zp, cpu.x); end;	{ $86: STX ZP }
procedure	stx_zpy;	begin wr(ea_zpi(cpu.y), cpu.x); end;	{ $96: STX ZPY }
procedure	stx_abs;	begin wr(ea_abs, cpu.x); end;	{ $8E: STX ABS }
procedure	sty_zp;		begin wr(ea_zp, cpu.y); end;	{ $84: STY ZP }
procedure	sty_zpx;	begin wr(ea_zpi(cpu.x), cpu.y); end;	{ $94: STY ZPX }
procedure	sty_abs;	begin wr(ea_abs, cpu.y); end;	{ $8C: STY ABS }
procedure	tax;		begin implied; cpu.x := cpu.a; set_nz(cpu.x); end;	{ $AA: TAX }
procedure	tay;		begin implied; cpu.y := cpu.a; set_nz(cpu.y); end;	{ $A8: TAY }
procedure	txa;		begin implied; lda(cpu.x); end;	{ $8A: TXA }
procedure	tya;		begin implied; lda(cpu.y); end;	{ $98: TYA }
procedure	tsx;		begin implied; cpu.x := cpu.s; set_nz(cpu.x); end;	{ $BA: TSX }
procedure	txs;		begin implied; cpu.s := cpu.x; end;	{ $9A: TXS }

{ arithmetic and logic }
procedure	ora_imm;	begin lda(cpu.a or fetch); end;	{ $09: ORA IMM }
procedure	ora_zp;		begin lda(cpu.a or rd(ea_zp)); end;	{ $05: ORA ZP }
procedure	ora_zpx;	begin lda(cpu.a or rd(ea_zpi(cpu.x))); end;	{ $15: ORA ZPX }
procedure	ora_abs;	begin lda(cpu.a or rd(ea_abs)); end;	{ $0D: ORA ABS }
procedure	ora_abx;	begin lda(cpu.a or rd(ea_absi(cpu.x, FALSE))); end;	{ $1D: ORA ABX }
procedure	ora_aby;	begin lda(cpu.a or rd(ea_absi(cpu.y, FALSE))); end;	{ $19: ORA ABY }
procedure	ora_izx;	begin lda(cpu.a or rd(ea_izx)); end;	{ $01: ORA IZX }
procedure	ora_izy;	begin lda(cpu.a or rd(ea_izy(FALSE))); end;	{ $11: ORA IZY }
procedure	and_imm;	begin lda(cpu.a and fetch); end;	{ $29: AND IMM }
procedure	and_zp;		begin lda(cpu.a and rd(ea_zp)); end;	{ $25: AND ZP }
procedure	and_zpx;	begin lda(cpu.a and rd(ea_zpi(cpu.x))); end;	{ $35: AND ZPX }
procedure	and_abs;	begin lda(cpu.a and rd(ea_abs)); end;	{ $2D: AND ABS }
procedure	and_abx;	begin lda(cpu.a and rd(ea_absi(cpu.x, FALSE))); end;	{ $3D: AND ABX }
procedure	and_aby;	begin lda(cpu.a and rd(ea_absi(cpu.y, FALSE))); end;	{ $39: AND ABY }
procedure	and_izx;	begin lda(cpu.a and rd(ea_izx)); end;	{ $21: AND IZX }
procedure	and_izy;	begin lda(cpu.a and rd(ea_izy(FALSE))); end;	{ $31: AND IZY }
procedure	eor_imm;	begin lda(cpu.a xor fetch); end;	{ $49: EOR IMM }
procedure	eor_zp;		begin lda(cpu.a xor rd(ea_zp)); end;	{ $45: EOR ZP }
procedure	eor_zpx;	begin lda(cpu.a xor rd(ea_zpi(cpu.x))); end;	{ $55: EOR ZPX }
procedure	eor_abs;	begin lda(cpu.a xor rd(ea_abs)); end;	{ $4D: EOR ABS }
procedure	eor_abx;	begin lda(cpu.a xor rd(ea_absi(cpu.x, FALSE))); end;	{ $5D: EOR ABX }
procedure	eor_aby;	begin lda(cpu.a xor rd(ea_absi(cpu.y, FALSE))); end;	{ $59: EOR ABY }
procedure	eor_izx;	begin lda(cpu.a xor rd(ea_izx)); end;	{ $41: EOR IZX }
procedure	eor_izy;	begin lda(cpu.a xor rd(ea_izy(FALSE))); end;	{ $51: EOR IZY }
procedure	adc_imm;	begin adc(fetch); end;	{ $69: ADC IMM }
procedure	adc_zp;		begin adc(rd(ea_zp)); end;	{ $65: ADC ZP }
procedure	adc_zpx;	begin adc(rd(ea_zpi(cpu.x))); end;	{ $75: ADC ZPX }
procedure	adc_abs;	begin adc(rd(ea_abs)); end;	{ $6D: ADC ABS }
procedure	adc_abx;	begin adc(rd(ea_absi(cpu.x, FALSE))); end;	{ $7D: ADC ABX }
procedure	adc_aby;	begin adc(rd(ea_absi(cpu.y, FALSE))); end;	{ $79: ADC ABY }
procedure	adc_izx;	begin adc(rd(ea_izx)); end;	{ $61: ADC IZX }
procedure	adc_izy;	begin adc(rd(ea_izy(FALSE))); end;	{ $71: ADC IZY }
procedure	sbc_imm;	begin sbc(fetch); end;	{ $E9 $EB: SBC IMM (EB unofficial) }
procedure	sbc_zp;		begin sbc(rd(ea_zp)); end;	{ $E5: SBC ZP }
procedure	sbc_zpx;	begin sbc(rd(ea_zpi(cpu.x))); end;	{ $F5: SBC ZPX }
procedure	sbc_abs;	begin sbc(rd(ea_abs)); end;	{ $ED: SBC ABS }
procedure	sbc_abx;	begin sbc(rd(ea_absi(cpu.x, FALSE))); end;	{ $FD: SBC ABX }
procedure	sbc_aby;	begin sbc(rd(ea_absi(cpu.y, FALSE))); end;	{ $F9: SBC ABY }
procedure	sbc_izx;	begin sbc(rd(ea_izx)); end;	{ $E1: SBC IZX }
procedure	sbc_izy;	begin sbc(rd(ea_izy(FALSE))); end;	{ $F1: SBC IZY }
procedure	cmp_imm;	begin compare(cpu.a, fetch); end;	{ $C9: CMP IMM }
procedure	cmp_zp;		begin compare(cpu.a, rd(ea_zp)); end;	{ $C5: CMP ZP }
procedure	cmp_zpx;	begin compare(cpu.a, rd(ea_zpi(cpu.x))); end;	{ $D5: CMP ZPX }
procedure	cmp_abs;	begin compare(cpu.a, rd(ea_abs)); end;	{ $CD: CMP ABS }
procedure	cmp_abx;	begin compare(cpu.a, rd(ea_absi(cpu.x, FALSE))); end;	{ $DD: CMP ABX }
procedure	cmp_aby;	begin compare(cpu.a, rd(ea_absi(cpu.y, FALSE))); end;	{ $D9: CMP ABY }
procedure	cmp_izx;	begin compare(cpu.a, rd(ea_izx)); end;	{ $C1: CMP IZX }
procedure	cmp_izy;	begin compare(cpu.a, rd(ea_izy(FALSE))); end;	{ $D1: CMP IZY }
procedure	cpx_imm;	begin compare(cpu.x, fetch); end;	{ $E0: CPX IMM }
procedure	cpx_zp;		begin compare(cpu.x, rd(ea_zp)); end;	{ $E4: CPX ZP }
procedure	cpx_abs;	begin compare(cpu.x, rd(ea_abs)); end;	{ $EC: CPX ABS }
procedure	cpy_imm;	begin compare(cpu.y, fetch); end;	{ $C0: CPY IMM }
procedure	cpy_zp;		begin compare(cpu.y, rd(ea_zp)); end;	{ $C4: CPY ZP }
procedure	cpy_abs;	begin compare(cpu.y, rd(ea_abs)); end;	{ $CC: CPY ABS }
procedure	bit_zp;		begin f_bit(rd(ea_zp)); end;	{ $24: BIT ZP }
procedure	bit_abs;	begin f_bit(rd(ea_abs)); end;	{ $2C: BIT ABS }

{ shifts and steps: the accumulator, or memory read-modify-written }
procedure	asl_a;		begin implied; cpu.a := f_asl(cpu.a); end;	{ $0A: ASL A }
procedure	lsr_a;		begin implied; cpu.a := f_lsr(cpu.a); end;	{ $4A: LSR A }
procedure	rol_a;		begin implied; cpu.a := f_rol(cpu.a); end;	{ $2A: ROL A }
procedure	ror_a;		begin implied; cpu.a := f_ror(cpu.a); end;	{ $6A: ROR A }
procedure	asl_zp;		begin rmw(ea_zp, K_ASL); end;	{ $06: ASL ZP }
procedure	asl_zpx;	begin rmw(ea_zpi(cpu.x), K_ASL); end;	{ $16: ASL ZPX }
procedure	asl_abs;	begin rmw(ea_abs, K_ASL); end;	{ $0E: ASL ABS }
procedure	asl_abx;	begin rmw(ea_absi(cpu.x, TRUE), K_ASL); end;	{ $1E: ASL ABX }
procedure	lsr_zp;		begin rmw(ea_zp, K_LSR); end;	{ $46: LSR ZP }
procedure	lsr_zpx;	begin rmw(ea_zpi(cpu.x), K_LSR); end;	{ $56: LSR ZPX }
procedure	lsr_abs;	begin rmw(ea_abs, K_LSR); end;	{ $4E: LSR ABS }
procedure	lsr_abx;	begin rmw(ea_absi(cpu.x, TRUE), K_LSR); end;	{ $5E: LSR ABX }
procedure	rol_zp;		begin rmw(ea_zp, K_ROL); end;	{ $26: ROL ZP }
procedure	rol_zpx;	begin rmw(ea_zpi(cpu.x), K_ROL); end;	{ $36: ROL ZPX }
procedure	rol_abs;	begin rmw(ea_abs, K_ROL); end;	{ $2E: ROL ABS }
procedure	rol_abx;	begin rmw(ea_absi(cpu.x, TRUE), K_ROL); end;	{ $3E: ROL ABX }
procedure	ror_zp;		begin rmw(ea_zp, K_ROR); end;	{ $66: ROR ZP }
procedure	ror_zpx;	begin rmw(ea_zpi(cpu.x), K_ROR); end;	{ $76: ROR ZPX }
procedure	ror_abs;	begin rmw(ea_abs, K_ROR); end;	{ $6E: ROR ABS }
procedure	ror_abx;	begin rmw(ea_absi(cpu.x, TRUE), K_ROR); end;	{ $7E: ROR ABX }
procedure	dec_zp;		begin rmw(ea_zp, K_DEC); end;	{ $C6: DEC ZP }
procedure	dec_zpx;	begin rmw(ea_zpi(cpu.x), K_DEC); end;	{ $D6: DEC ZPX }
procedure	dec_abs;	begin rmw(ea_abs, K_DEC); end;	{ $CE: DEC ABS }
procedure	dec_abx;	begin rmw(ea_absi(cpu.x, TRUE), K_DEC); end;	{ $DE: DEC ABX }
procedure	inc_zp;		begin rmw(ea_zp, K_INC); end;	{ $E6: INC ZP }
procedure	inc_zpx;	begin rmw(ea_zpi(cpu.x), K_INC); end;	{ $F6: INC ZPX }
procedure	inc_abs;	begin rmw(ea_abs, K_INC); end;	{ $EE: INC ABS }
procedure	inc_abx;	begin rmw(ea_absi(cpu.x, TRUE), K_INC); end;	{ $FE: INC ABX }
procedure	dex;		begin implied; cpu.x := (cpu.x - 1) and $FF; set_nz(cpu.x); end;	{ $CA: DEX }
procedure	dey;		begin implied; cpu.y := (cpu.y - 1) and $FF; set_nz(cpu.y); end;	{ $88: DEY }
procedure	inx;		begin implied; cpu.x := (cpu.x + 1) and $FF; set_nz(cpu.x); end;	{ $E8: INX }
procedure	iny;		begin implied; cpu.y := (cpu.y + 1) and $FF; set_nz(cpu.y); end;	{ $C8: INY }

{ branches }
procedure	bpl;		begin branch(cpu.n and $80 = 0); end;	{ $10: BPL }
procedure	bmi;		begin branch(cpu.n and $80 <> 0); end;	{ $30: BMI }
procedure	bvc;		begin branch(cpu.v = 0); end;	{ $50: BVC }
procedure	bvs;		begin branch(cpu.v <> 0); end;	{ $70: BVS }
procedure	bcc;		begin branch(cpu.c = 0); end;	{ $90: BCC }
procedure	bcs;		begin branch(cpu.c <> 0); end;	{ $B0: BCS }
procedure	bne;		begin branch(cpu.z and $FF <> 0); end;	{ $D0: BNE }
procedure	beq;		begin branch(cpu.z and $FF = 0); end;	{ $F0: BEQ }

{ jumps, calls, returns }
procedure	jmp_abs;	begin cpu.pc := ea_abs; end;	{ $4C: JMP ABS }

procedure	jmp_ind;	{ $6C: JMP IND, the page not crossed }
var	a, lo	: U16;
begin
	a := ea_abs;
	lo := rd(a);
	cpu.pc := lo or rd((a and $FF00) or ((a + 1) and $FF)) shl 8;
end;

procedure	jsr;	{ $20: JSR }
var	lo	: U16;
begin
	lo := fetch;
	rd($100 + cpu.s);
	push(cpu.pc shr 8);
	push(cpu.pc and $FF);
	cpu.pc := lo or rd(cpu.pc) shl 8;
end;

procedure	rts;	{ $60: RTS }
var	a, lo	: U16;
begin
	implied;
	rd($100 + cpu.s);
	lo := pop;
	a := lo or pop shl 8;
	rd(a);
	cpu.pc := (a + 1) and $FFFF;
end;

procedure	rti;	{ $40: RTI }
var	lo	: U16;
begin
	implied;
	rd($100 + cpu.s);
	cpu_set_p(pop);
	lo := pop;
	cpu.pc := lo or pop shl 8;
end;

procedure	brk;	{ $00: BRK }
begin
	fetch;
	take_interrupt($FFFE, $10);
end;

{ the stack and the flags }
procedure	pha;		begin implied; push(cpu.a); end;	{ $48: PHA }
procedure	php;		begin implied; push(cpu_p or $10); end;	{ $08: PHP }

procedure	pla;	{ $68: PLA }
begin
	implied;
	rd($100 + cpu.s);
	lda(pop);
end;

procedure	plp;	{ $28: PLP }
begin
	implied;
	rd($100 + cpu.s);
	i_poll := cpu.i;
	cpu_set_p(pop);
end;

procedure	clc;		begin implied; cpu.c := 0; end;	{ $18: CLC }
procedure	sec;		begin implied; cpu.c := 1; end;	{ $38: SEC }
procedure	cli;		begin implied; i_poll := cpu.i; cpu.i := 0; end;	{ $58: CLI }
procedure	sei;		begin implied; i_poll := cpu.i; cpu.i := 1; end;	{ $78: SEI }
procedure	clv;		begin implied; cpu.v := 0; end;	{ $B8: CLV }
procedure	cld;		begin implied; cpu.d := 0; end;	{ $D8: CLD }
procedure	sed;		begin implied; cpu.d := 1; end;	{ $F8: SED }

{ the NOPs, official and not: their reads all the same }
procedure	nop;		begin implied; end;	{ $1A $3A $5A $7A $DA $EA $FA: NOP }
procedure	nop_imm;	begin fetch; end;	{ $80 $82 $89 $C2 $E2: NOP IMM }
procedure	nop_zp;		begin rd(ea_zp); end;	{ $04 $44 $64: NOP ZP }
procedure	nop_zpx;	begin rd(ea_zpi(cpu.x)); end;	{ $14 $34 $54 $74 $D4 $F4: NOP ZPX }
procedure	nop_abs;	begin rd(ea_abs); end;	{ $0C: NOP ABS }
procedure	nop_abx;	begin rd(ea_absi(cpu.x, FALSE)); end;	{ $1C $3C $5C $7C $DC $FC: NOP ABX }

{ the unofficial read-modify-writes: the step, then a second
  operation on its result }
procedure	slo_zp;		begin lda(cpu.a or rmw(ea_zp, K_ASL)); end;	{ $07: SLO ZP }
procedure	slo_zpx;	begin lda(cpu.a or rmw(ea_zpi(cpu.x), K_ASL)); end;	{ $17: SLO ZPX }
procedure	slo_abs;	begin lda(cpu.a or rmw(ea_abs, K_ASL)); end;	{ $0F: SLO ABS }
procedure	slo_abx;	begin lda(cpu.a or rmw(ea_absi(cpu.x, TRUE), K_ASL)); end;	{ $1F: SLO ABX }
procedure	slo_aby;	begin lda(cpu.a or rmw(ea_absi(cpu.y, TRUE), K_ASL)); end;	{ $1B: SLO ABY }
procedure	slo_izx;	begin lda(cpu.a or rmw(ea_izx, K_ASL)); end;	{ $03: SLO IZX }
procedure	slo_izy;	begin lda(cpu.a or rmw(ea_izy(TRUE), K_ASL)); end;	{ $13: SLO IZY }
procedure	rla_zp;		begin lda(cpu.a and rmw(ea_zp, K_ROL)); end;	{ $27: RLA ZP }
procedure	rla_zpx;	begin lda(cpu.a and rmw(ea_zpi(cpu.x), K_ROL)); end;	{ $37: RLA ZPX }
procedure	rla_abs;	begin lda(cpu.a and rmw(ea_abs, K_ROL)); end;	{ $2F: RLA ABS }
procedure	rla_abx;	begin lda(cpu.a and rmw(ea_absi(cpu.x, TRUE), K_ROL)); end;	{ $3F: RLA ABX }
procedure	rla_aby;	begin lda(cpu.a and rmw(ea_absi(cpu.y, TRUE), K_ROL)); end;	{ $3B: RLA ABY }
procedure	rla_izx;	begin lda(cpu.a and rmw(ea_izx, K_ROL)); end;	{ $23: RLA IZX }
procedure	rla_izy;	begin lda(cpu.a and rmw(ea_izy(TRUE), K_ROL)); end;	{ $33: RLA IZY }
procedure	sre_zp;		begin lda(cpu.a xor rmw(ea_zp, K_LSR)); end;	{ $47: SRE ZP }
procedure	sre_zpx;	begin lda(cpu.a xor rmw(ea_zpi(cpu.x), K_LSR)); end;	{ $57: SRE ZPX }
procedure	sre_abs;	begin lda(cpu.a xor rmw(ea_abs, K_LSR)); end;	{ $4F: SRE ABS }
procedure	sre_abx;	begin lda(cpu.a xor rmw(ea_absi(cpu.x, TRUE), K_LSR)); end;	{ $5F: SRE ABX }
procedure	sre_aby;	begin lda(cpu.a xor rmw(ea_absi(cpu.y, TRUE), K_LSR)); end;	{ $5B: SRE ABY }
procedure	sre_izx;	begin lda(cpu.a xor rmw(ea_izx, K_LSR)); end;	{ $43: SRE IZX }
procedure	sre_izy;	begin lda(cpu.a xor rmw(ea_izy(TRUE), K_LSR)); end;	{ $53: SRE IZY }
procedure	rra_zp;		begin adc(rmw(ea_zp, K_ROR)); end;	{ $67: RRA ZP }
procedure	rra_zpx;	begin adc(rmw(ea_zpi(cpu.x), K_ROR)); end;	{ $77: RRA ZPX }
procedure	rra_abs;	begin adc(rmw(ea_abs, K_ROR)); end;	{ $6F: RRA ABS }
procedure	rra_abx;	begin adc(rmw(ea_absi(cpu.x, TRUE), K_ROR)); end;	{ $7F: RRA ABX }
procedure	rra_aby;	begin adc(rmw(ea_absi(cpu.y, TRUE), K_ROR)); end;	{ $7B: RRA ABY }
procedure	rra_izx;	begin adc(rmw(ea_izx, K_ROR)); end;	{ $63: RRA IZX }
procedure	rra_izy;	begin adc(rmw(ea_izy(TRUE), K_ROR)); end;	{ $73: RRA IZY }
procedure	dcp_zp;		begin compare(cpu.a, rmw(ea_zp, K_DEC)); end;	{ $C7: DCP ZP }
procedure	dcp_zpx;	begin compare(cpu.a, rmw(ea_zpi(cpu.x), K_DEC)); end;	{ $D7: DCP ZPX }
procedure	dcp_abs;	begin compare(cpu.a, rmw(ea_abs, K_DEC)); end;	{ $CF: DCP ABS }
procedure	dcp_abx;	begin compare(cpu.a, rmw(ea_absi(cpu.x, TRUE), K_DEC)); end;	{ $DF: DCP ABX }
procedure	dcp_aby;	begin compare(cpu.a, rmw(ea_absi(cpu.y, TRUE), K_DEC)); end;	{ $DB: DCP ABY }
procedure	dcp_izx;	begin compare(cpu.a, rmw(ea_izx, K_DEC)); end;	{ $C3: DCP IZX }
procedure	dcp_izy;	begin compare(cpu.a, rmw(ea_izy(TRUE), K_DEC)); end;	{ $D3: DCP IZY }
procedure	isc_zp;		begin sbc(rmw(ea_zp, K_INC)); end;	{ $E7: ISC ZP }
procedure	isc_zpx;	begin sbc(rmw(ea_zpi(cpu.x), K_INC)); end;	{ $F7: ISC ZPX }
procedure	isc_abs;	begin sbc(rmw(ea_abs, K_INC)); end;	{ $EF: ISC ABS }
procedure	isc_abx;	begin sbc(rmw(ea_absi(cpu.x, TRUE), K_INC)); end;	{ $FF: ISC ABX }
procedure	isc_aby;	begin sbc(rmw(ea_absi(cpu.y, TRUE), K_INC)); end;	{ $FB: ISC ABY }
procedure	isc_izx;	begin sbc(rmw(ea_izx, K_INC)); end;	{ $E3: ISC IZX }
procedure	isc_izy;	begin sbc(rmw(ea_izy(TRUE), K_INC)); end;	{ $F3: ISC IZY }

{ the other unofficial ones }
procedure	lax_zp;		begin cpu.x := rd(ea_zp); lda(cpu.x); end;	{ $A7: LAX ZP }
procedure	lax_zpy;	begin cpu.x := rd(ea_zpi(cpu.y)); lda(cpu.x); end;	{ $B7: LAX ZPY }
procedure	lax_abs;	begin cpu.x := rd(ea_abs); lda(cpu.x); end;	{ $AF: LAX ABS }
procedure	lax_aby;	begin cpu.x := rd(ea_absi(cpu.y, FALSE)); lda(cpu.x); end;	{ $BF: LAX ABY }
procedure	lax_izx;	begin cpu.x := rd(ea_izx); lda(cpu.x); end;	{ $A3: LAX IZX }
procedure	lax_izy;	begin cpu.x := rd(ea_izy(FALSE)); lda(cpu.x); end;	{ $B3: LAX IZY }
procedure	lxa_imm;	begin cpu.x := fetch; lda(cpu.x); end;	{ $AB: LXA IMM: A = X = the operand }
procedure	sax_zp;		begin wr(ea_zp, cpu.a and cpu.x); end;	{ $87: SAX ZP }
procedure	sax_zpy;	begin wr(ea_zpi(cpu.y), cpu.a and cpu.x); end;	{ $97: SAX ZPY }
procedure	sax_abs;	begin wr(ea_abs, cpu.a and cpu.x); end;	{ $8F: SAX ABS }
procedure	sax_izx;	begin wr(ea_izx, cpu.a and cpu.x); end;	{ $83: SAX IZX }

procedure	anc_imm;	{ $0B $2B: ANC IMM }
begin
	lda(cpu.a and fetch);
	cpu.c := cpu.a shr 7;
end;

procedure	alr_imm;	begin cpu.a := f_lsr(cpu.a and fetch); end;	{ $4B: ALR IMM }

procedure	arr_imm;	{ $6B: ARR IMM }
var	v	: U16;
begin
	v := ((cpu.a and fetch) shr 1) or cpu.c shl 7;
	lda(v);
	cpu.c := (v shr 6) and 1;
	cpu.v := ((v shr 5) and 1) xor cpu.c;
end;

procedure	xaa_imm;	begin lda((cpu.a or $EE) and cpu.x and fetch); end;	{ $8B: XAA IMM }

procedure	axs_imm;	{ $CB: AXS IMM }
var	a, v	: U16;
begin
	v := fetch;
	a := cpu.a and cpu.x;
	cpu.c := ord(a >= v);
	cpu.x := (a - v) and $FF;
	set_nz(cpu.x);
end;

procedure	las_aby;	{ $BB: LAS ABY }
var	v	: U16;
begin
	v := rd(ea_absi(cpu.y, FALSE)) and cpu.s;
	cpu.s := v;
	cpu.x := v;
	lda(v);
end;

procedure	sha_izy;	{ $93: SHA IZY }
var	a	: U16;
begin
	a := ea_izy(TRUE);
	sh_store(a, cpu.a and cpu.x);
end;

procedure	sha_aby;	{ $9F: SHA ABY }
var	a	: U16;
begin
	a := ea_absi(cpu.y, TRUE);
	sh_store(a, cpu.a and cpu.x);
end;

procedure	shx_aby;	{ $9E: SHX ABY }
var	a	: U16;
begin
	a := ea_absi(cpu.y, TRUE);
	sh_store(a, cpu.x);
end;

procedure	shy_abx;	{ $9C: SHY ABX }
var	a	: U16;
begin
	a := ea_absi(cpu.x, TRUE);
	sh_store(a, cpu.y);
end;

procedure	tas_aby;	{ $9B: TAS ABY }
var	a	: U16;
begin
	a := ea_absi(cpu.y, TRUE);
	cpu.s := cpu.a and cpu.x;
	sh_store(a, cpu.s);
end;

{ the twelve that stop the chip }
procedure	jam;
begin
	cpu.jammed := TRUE;
	cpu.jam_op := bus_open;		{ the opcode just fetched }
	run_until := cycles;
	bus_next_event := cycles;
	cpu.pc := (cpu.pc - 1) and $FFFF;
end;
{$ifdef VER70}{$F-}{$endif}

{ the opcode table: OPS[op] runs instruction op }
const
	OPS	: array[0 .. 255] of OP_PROC = (
	{ $00 }	brk, ora_izx, jam, slo_izx, nop_zp, ora_zp, asl_zp, slo_zp,
			php, ora_imm, asl_a, anc_imm, nop_abs, ora_abs, asl_abs, slo_abs,
	{ $10 } bpl, ora_izy, jam, slo_izy, nop_zpx, ora_zpx, asl_zpx, slo_zpx,
		 	clc, ora_aby, nop, slo_aby, nop_abx, ora_abx, asl_abx, slo_abx,
	{ $20 } jsr, and_izx, jam, rla_izx, bit_zp, and_zp, rol_zp, rla_zp,
			plp, and_imm, rol_a, anc_imm, bit_abs, and_abs, rol_abs, rla_abs,
	{ $30 } bmi, and_izy, jam, rla_izy, nop_zpx, and_zpx, rol_zpx, rla_zpx,
		 	sec, and_aby, nop, rla_aby, nop_abx, and_abx, rol_abx, rla_abx,
	{ $40 } rti, eor_izx, jam, sre_izx, nop_zp, eor_zp, lsr_zp, sre_zp,
		 	pha, eor_imm, lsr_a, alr_imm, jmp_abs, eor_abs, lsr_abs, sre_abs,
	{ $50 } bvc, eor_izy, jam, sre_izy, nop_zpx, eor_zpx, lsr_zpx, sre_zpx,
		 	cli, eor_aby, nop, sre_aby, nop_abx, eor_abx, lsr_abx, sre_abx,
	{ $60 } rts, adc_izx, jam, rra_izx, nop_zp, adc_zp, ror_zp, rra_zp,
		 	pla, adc_imm, ror_a, arr_imm, jmp_ind, adc_abs, ror_abs, rra_abs,
	{ $70 } bvs, adc_izy, jam, rra_izy, nop_zpx, adc_zpx, ror_zpx, rra_zpx,
			sei, adc_aby, nop, rra_aby, nop_abx, adc_abx, ror_abx, rra_abx,
	{ $80 } nop_imm, sta_izx, nop_imm, sax_izx, sty_zp, sta_zp, stx_zp, sax_zp,
		 	dey, nop_imm, txa, xaa_imm, sty_abs, sta_abs, stx_abs, sax_abs,
	{ $90 } bcc, sta_izy, jam, sha_izy, sty_zpx, sta_zpx, stx_zpy, sax_zpy,
			tya, sta_aby, txs, tas_aby, shy_abx, sta_abx, shx_aby, sha_aby,
	{ $A0 } ldy_imm, lda_izx, ldx_imm, lax_izx, ldy_zp, lda_zp, ldx_zp, lax_zp,
		 	tay, lda_imm, tax, lxa_imm, ldy_abs, lda_abs, ldx_abs, lax_abs,
	{ $B0 } bcs, lda_izy, jam, lax_izy, ldy_zpx, lda_zpx, ldx_zpy, lax_zpy,
		 	clv, lda_aby, tsx, las_aby, ldy_abx, lda_abx, ldx_aby, lax_aby,
	{ $C0 } cpy_imm, cmp_izx, nop_imm, dcp_izx, cpy_zp, cmp_zp, dec_zp, dcp_zp,
		 	iny, cmp_imm, dex, axs_imm, cpy_abs, cmp_abs, dec_abs, dcp_abs,
	{ $D0 } bne, cmp_izy, jam, dcp_izy, nop_zpx, cmp_zpx, dec_zpx, dcp_zpx,
		 	cld, cmp_aby, nop, dcp_aby, nop_abx, cmp_abx, dec_abx, dcp_abx,
	{ $E0 } cpx_imm, sbc_izx, nop_imm, isc_izx, cpx_zp, sbc_zp, inc_zp, isc_zp,
		 	inx, sbc_imm, nop, sbc_imm, cpx_abs, sbc_abs, inc_abs, isc_abs,
	{ $F0 } beq, sbc_izy, jam, isc_izy, nop_zpx, sbc_zpx, inc_zpx, isc_zpx,
		 	sed, sbc_aby, nop, isc_aby, nop_abx, sbc_abx, inc_abx, isc_abx);

{ ---- running ---- }

procedure	cpu_power;
var	lo	: U16;
begin
	bus_map;			{ the page map of the cartridge just put in }
	fillchar(cpu, sizeof(cpu), 0);
	i_poll := -1;
	cpu.s := $FD;
	cpu_set_p($24);
	inc(cycles, 5);
	lo := rd($FFFC);
	cpu.pc := lo or rd($FFFD) shl 8;
end;

procedure	cpu_reset;
var	lo	: U16;
begin
	bus_map;
	cpu.s := (cpu.s - 3) and $FF;
	cpu.i := 1;
	i_poll := -1;
	cpu.jammed := FALSE;
	inc(cycles, 5);
	lo := rd($FFFC);
	cpu.pc := lo or rd($FFFD) shl 8;
end;

procedure	oam_dma;
var	k, base	: U16;
begin
	base := dma_page shl 8;
	dma_page := -1;
	inc(cycles);
	if odd(cycles) then inc(cycles);
	for k := 0 to 255 do wr($2004, rd(base + k));
end;

{ an IRQ due now: the line high since before the last cycle, and I (as
  CLI, SEI or PLP left it for this poll) clear }
function	irq_wanted: boolean;
begin
	if irq_seen > cycles - 1 then irq_wanted := FALSE
	else if i_poll > 0 then irq_wanted := FALSE
	else if i_poll = 0 then irq_wanted := TRUE
	else	irq_wanted := cpu.i = 0;
end;

procedure	cpu_run(until_cycle: longint);
var	interrupted	: boolean;
begin
	run_until := until_cycle;
	if cpu.jammed then exit;
	bus_map;
	repeat
		{ at an event: the run's end, then an NMI seen before the last
		  cycle of the instruction before }
		if cycles >= run_until then exit;
		if ppu_nmi_cycle <= cycles - 1 then
		begin
			step_cycle := cycles;
			ppu_nmi_cycle := PPU_NEVER;
			i_poll := -1;		{ the NMI's I, not a CLI's, SEI's or PLP's }
			implied;
			implied;
			take_interrupt($FFFA, 0);
		end
		else
		begin
			{ the next event no later than the run's end or the NMI }
			irq_seen := bus_irq_at;
			if run_until < bus_next_event then bus_next_event := run_until;
			if (ppu_nmi_cycle <> PPU_NEVER) and (ppu_nmi_cycle + 1 < bus_next_event) then
				bus_next_event := ppu_nmi_cycle + 1;
			{ instructions until it }
			interrupted := FALSE;
			repeat
				step_cycle := cycles;
				if (irq_seen < cycles) and irq_wanted then
				begin
					i_poll := -1;
					implied;
					implied;
					take_interrupt($FFFE, 0);
					interrupted := TRUE;
				end
				else
				begin
					i_poll := -1;
					OPS[fetch];
				end;
			until interrupted or (cycles >= bus_next_event);
			{ an OAM DMA or the DMC's stall: only at an event (F_BUS
			  makes them one) }
			if not interrupted then
			begin
				if dma_page >= 0 then oam_dma;
				if apu_stall > 0 then
				begin
					inc(cycles, apu_stall);	{ the DMC's fetches }
					apu_stall := 0;
				end;
			end;
		end;
		if cycles >= bus_next_event then bus_sync;
	until FALSE;
end;

procedure	cpu_start;
begin
end;

procedure	cpu_step;
begin
	cpu_run(cycles + 1);
end;

begin
	run_until := 0;
	irq_seen := 0;
	sh_high := 0;
end.
