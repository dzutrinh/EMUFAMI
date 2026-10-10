{*+
	F_CPU.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The 2A03's 6502: 151 official and 93 unofficial opcodes, NMI,
	IRQ, BRK, OAM DMA.  Each bus access one cycle (rd, wr), the
	chip's dummy reads and writes included; N and Z kept as the
	value that set them.  Interrupts between instructions, with the
	I flag CLI, SEI and PLP left for the poll (i_poll).  The run's
	end, NMI, IRQ, DMA and the DMC's stalls looked at only at events
	(bus_next_event).  One case statement over the opcodes.
-*}
{$X+}
unit	f_cpu;

interface

type	CPU_REGS	= record
		a, x, y, s, pc	: longint;
		c, i, d, v	: longint;	{ 0 or 1 }
		n, z		: longint;	{ N: bit 7 of n; Z: z = 0 }
		jammed		: boolean;
		jam_op		: longint;
	end;

var	cpu		: CPU_REGS;
	i_poll		: longint;	{ the I flag the next poll sees, -1: cpu.i }

procedure	cpu_start;			{ nothing to make: kept for the callers }
procedure	cpu_power;			{ registers cleared, the reset vector; 7 cycles }
procedure	cpu_reset;			{ the reset button }
function	cpu_p: longint;			{ the flags, bit 5 set, B clear }
procedure	cpu_set_p(p: longint);
procedure	cpu_step;			{ one instruction, or one interrupt taken }
procedure	cpu_run(until_cycle: longint);	{ steps until cycles reaches it }

implementation

uses	f_sys, f_map, f_bus, f_ppu, f_apu;

var	run_until	: longint;
	irq_seen	: longint;	{ bus_irq_at as the last event left it }
	sh_high		: longint;	{ the base's high byte as the last indexed wrt left it (SHA, SHX, SHY, TAS) }

{ ---- one cycle each ---- }

{ a byte read: plain memory through the page map, else the bus }
function	rd(addr: longint): longint;
var	p	: PBYTE;
	v	: longint;
begin
	inc(cycles);
	p := bus_rpage[addr shr 11];
	if p <> nil then
	begin
		v := (p + addr)^;
		bus_open := v;
		rd := v;
	end
	else	rd := bus_read(addr);
end;

procedure	wr(addr, v: longint);
var	p	: PBYTE;
begin
	inc(cycles);
	p := bus_wpage[addr shr 11];
	if p <> nil then
	begin
		(p + addr)^ := v;
		bus_open := v;
	end
	else	bus_write(addr, v);
end;

{ the byte at PC, PC on }
function	fetch: longint;
begin
	fetch := rd(cpu.pc);
	cpu.pc := (cpu.pc + 1) and $FFFF;
end;

{ an implied instruction's second cycle: PC read again, the byte let go }
procedure	implied;
begin
	rd(cpu.pc);
end;

{ the stack: always RAM }
procedure	push(v: longint);
begin
	inc(cycles);
	ram[$100 + cpu.s] := v;
	bus_open := v;
	cpu.s := (cpu.s - 1) and $FF;
end;

function	pop: longint;
var	v	: longint;
begin
	cpu.s := (cpu.s + 1) and $FF;
	inc(cycles);
	v := ram[$100 + cpu.s];
	bus_open := v;
	pop := v;
end;

{ ---- the flags ---- }

function	cpu_p: longint;
var	p	: longint;
begin
	p := (cpu.n and $80) or cpu.v shl 6 or $20 or cpu.d shl 3 or cpu.i shl 2 or cpu.c;
	if cpu.z and $FF = 0 then p := p or 2;
	cpu_p := p;
end;

procedure	cpu_set_p(p: longint);
begin
	cpu.n := p;
	cpu.v := (p shr 6) and 1;
	cpu.d := (p shr 3) and 1;
	cpu.i := (p shr 2) and 1;
	cpu.z := (not p) and 2;
	cpu.c := p and 1;
end;

procedure	set_nz(v: longint);
begin
	cpu.n := v;
	cpu.z := v;
end;

{ ---- where the operand is: its address ---- }

function	ea_zp: longint;
begin
	ea_zp := fetch;
end;

{ zero page indexed: the base read while the index is added }
function	ea_zpi(index: longint): longint;
var	b	: longint;
begin
	b := fetch;
	rd(b);
	ea_zpi := (b + index) and $FF;
end;

function	ea_abs: longint;
var	lo	: longint;
begin
	lo := fetch;
	ea_abs := lo or fetch shl 8;
end;

{ base + index: the read made before the carry reaches the high byte -
  only when the page is crossed for a read, always for a wrt (whose
  base's high byte SHA, SHX, SHY and TAS use) }
function	cross(base, index: longint; wrt: boolean): longint;
var	a	: longint;
begin
	a := (base + index) and $FFFF;
	if wrt or ((base xor a) and $FF00 <> 0) then rd((base and $FF00) or (a and $FF));
	if wrt then sh_high := base and $FF00;
	cross := a;
end;

function	ea_absi(index: longint; wrt: boolean): longint;
begin
	ea_absi := cross(ea_abs, index, wrt);
end;

{ (zp,X): the pointer read, X added, its two bytes read in the zero page }
function	ea_inx: longint;
var	b, lo	: longint;
begin
	b := fetch;
	rd(b);
	b := (b + cpu.x) and $FF;
	lo := rd(b);
	ea_inx := lo or rd((b + 1) and $FF) shl 8;
end;

{ (zp),Y }
function	ea_iny(wrt: boolean): longint;
var	b, lo	: longint;
begin
	b := fetch;
	lo := rd(b);
	lo := lo or rd((b + 1) and $FF) shl 8;
	ea_iny := cross(lo, cpu.y, wrt);
end;

{ ---- what the instructions do ---- }

procedure	lda(v: longint);
begin
	cpu.a := v;
	set_nz(v);
end;

procedure	adc(v: longint);
var	t	: longint;
begin
	t := cpu.a + v + cpu.c;
	cpu.v := ((cpu.a xor t) and not (cpu.a xor v) and $80) shr 7;
	cpu.c := t shr 8;
	lda(t and $FF);
end;

procedure	sbc(v: longint);
begin
	adc(v xor $FF);
end;

procedure	compare(reg, v: longint);
begin
	cpu.c := ord(reg >= v);
	set_nz((reg - v) and $FF);
end;

procedure	f_bit(v: longint);
begin
	cpu.n := v;
	cpu.z := v and cpu.a;
	cpu.v := (v shr 6) and 1;
end;

{ the shifts and steps, N and Z set }
function	f_asl(v: longint): longint;
begin
	cpu.c := v shr 7;
	v := (v shl 1) and $FF;
	set_nz(v);
	f_asl := v;
end;

function	f_lsr(v: longint): longint;
begin
	cpu.c := v and 1;
	v := v shr 1;
	set_nz(v);
	f_lsr := v;
end;

function	f_rol(v: longint): longint;
var	c	: longint;
begin
	c := v shr 7;
	v := ((v shl 1) or cpu.c) and $FF;
	cpu.c := c;
	set_nz(v);
	f_rol := v;
end;

function	f_ror(v: longint): longint;
var	c	: longint;
begin
	c := v and 1;
	v := (v shr 1) or cpu.c shl 7;
	cpu.c := c;
	set_nz(v);
	f_ror := v;
end;

{ read-modify-wrt: read, the old value written back, the new written -
  the chip's three steps.  kind: the operation }
const	K_ASL	= 0;
	K_ROL	= 1;
	K_LSR	= 2;
	K_ROR	= 3;
	K_DEC	= 4;
	K_INC	= 5;

function	rmw(addr, kind: longint): longint;
var	v	: longint;
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
var	off, t	: longint;
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
procedure	take_interrupt(vector, b: longint);
var	lo	: longint;
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
procedure	sh_store(addr, v: longint);
begin
	v := v and ((sh_high shr 8) + 1);
	if addr and $FF00 <> sh_high then addr := (addr and $FF) or v shl 8;
	wr(addr, v);
end;

{ ---- one instruction ---- }

procedure	execute(op: longint);
var	a, v, lo	: longint;
begin
	case op of
	{ loads, stores, transfers }
	$A9:	lda(fetch);					{ LDA IMM }
	$A5:	lda(rd(ea_zp));					{ LDA ZP }
	$B5:	lda(rd(ea_zpi(cpu.x)));				{ LDA ZPX }
	$AD:	lda(rd(ea_abs));				{ LDA ABS }
	$BD:	lda(rd(ea_absi(cpu.x, FALSE)));			{ LDA ABX }
	$B9:	lda(rd(ea_absi(cpu.y, FALSE)));			{ LDA ABY }
	$A1:	lda(rd(ea_inx));				{ LDA INX }
	$B1:	lda(rd(ea_iny(FALSE)));				{ LDA INY }
	$A2:	begin cpu.x := fetch; set_nz(cpu.x); end;		{ LDX IMM }
	$A6:	begin cpu.x := rd(ea_zp); set_nz(cpu.x); end;		{ LDX ZP }
	$B6:	begin cpu.x := rd(ea_zpi(cpu.y)); set_nz(cpu.x); end;	{ LDX ZPY }
	$AE:	begin cpu.x := rd(ea_abs); set_nz(cpu.x); end;		{ LDX ABS }
	$BE:	begin cpu.x := rd(ea_absi(cpu.y, FALSE)); set_nz(cpu.x); end;	{ LDX ABY }
	$A0:	begin cpu.y := fetch; set_nz(cpu.y); end;		{ LDY IMM }
	$A4:	begin cpu.y := rd(ea_zp); set_nz(cpu.y); end;		{ LDY ZP }
	$B4:	begin cpu.y := rd(ea_zpi(cpu.x)); set_nz(cpu.y); end;	{ LDY ZPX }
	$AC:	begin cpu.y := rd(ea_abs); set_nz(cpu.y); end;		{ LDY ABS }
	$BC:	begin cpu.y := rd(ea_absi(cpu.x, FALSE)); set_nz(cpu.y); end;	{ LDY ABX }
	$85:	wr(ea_zp, cpu.a);				{ STA ZP }
	$95:	wr(ea_zpi(cpu.x), cpu.a);			{ STA ZPX }
	$8D:	wr(ea_abs, cpu.a);				{ STA ABS }
	$9D:	wr(ea_absi(cpu.x, TRUE), cpu.a);		{ STA ABX }
	$99:	wr(ea_absi(cpu.y, TRUE), cpu.a);		{ STA ABY }
	$81:	wr(ea_inx, cpu.a);				{ STA INX }
	$91:	wr(ea_iny(TRUE), cpu.a);			{ STA INY }
	$86:	wr(ea_zp, cpu.x);				{ STX ZP }
	$96:	wr(ea_zpi(cpu.y), cpu.x);			{ STX ZPY }
	$8E:	wr(ea_abs, cpu.x);				{ STX ABS }
	$84:	wr(ea_zp, cpu.y);				{ STY ZP }
	$94:	wr(ea_zpi(cpu.x), cpu.y);			{ STY ZPX }
	$8C:	wr(ea_abs, cpu.y);				{ STY ABS }
	$AA:	begin implied; cpu.x := cpu.a; set_nz(cpu.x); end;	{ TAX }
	$A8:	begin implied; cpu.y := cpu.a; set_nz(cpu.y); end;	{ TAY }
	$8A:	begin implied; lda(cpu.x); end;			{ TXA }
	$98:	begin implied; lda(cpu.y); end;			{ TYA }
	$BA:	begin implied; cpu.x := cpu.s; set_nz(cpu.x); end;	{ TSX }
	$9A:	begin implied; cpu.s := cpu.x; end;		{ TXS }

	{ arithmetic and logic }
	$09:	lda(cpu.a or fetch);				{ ORA IMM }
	$05:	lda(cpu.a or rd(ea_zp));			{ ORA ZP }
	$15:	lda(cpu.a or rd(ea_zpi(cpu.x)));		{ ORA ZPX }
	$0D:	lda(cpu.a or rd(ea_abs));			{ ORA ABS }
	$1D:	lda(cpu.a or rd(ea_absi(cpu.x, FALSE)));	{ ORA ABX }
	$19:	lda(cpu.a or rd(ea_absi(cpu.y, FALSE)));	{ ORA ABY }
	$01:	lda(cpu.a or rd(ea_inx));			{ ORA INX }
	$11:	lda(cpu.a or rd(ea_iny(FALSE)));		{ ORA INY }
	$29:	lda(cpu.a and fetch);				{ AND IMM }
	$25:	lda(cpu.a and rd(ea_zp));			{ AND ZP }
	$35:	lda(cpu.a and rd(ea_zpi(cpu.x)));		{ AND ZPX }
	$2D:	lda(cpu.a and rd(ea_abs));			{ AND ABS }
	$3D:	lda(cpu.a and rd(ea_absi(cpu.x, FALSE)));	{ AND ABX }
	$39:	lda(cpu.a and rd(ea_absi(cpu.y, FALSE)));	{ AND ABY }
	$21:	lda(cpu.a and rd(ea_inx));			{ AND INX }
	$31:	lda(cpu.a and rd(ea_iny(FALSE)));		{ AND INY }
	$49:	lda(cpu.a xor fetch);				{ EOR IMM }
	$45:	lda(cpu.a xor rd(ea_zp));			{ EOR ZP }
	$55:	lda(cpu.a xor rd(ea_zpi(cpu.x)));		{ EOR ZPX }
	$4D:	lda(cpu.a xor rd(ea_abs));			{ EOR ABS }
	$5D:	lda(cpu.a xor rd(ea_absi(cpu.x, FALSE)));	{ EOR ABX }
	$59:	lda(cpu.a xor rd(ea_absi(cpu.y, FALSE)));	{ EOR ABY }
	$41:	lda(cpu.a xor rd(ea_inx));			{ EOR INX }
	$51:	lda(cpu.a xor rd(ea_iny(FALSE)));		{ EOR INY }
	$69:	adc(fetch);					{ ADC IMM }
	$65:	adc(rd(ea_zp));					{ ADC ZP }
	$75:	adc(rd(ea_zpi(cpu.x)));				{ ADC ZPX }
	$6D:	adc(rd(ea_abs));				{ ADC ABS }
	$7D:	adc(rd(ea_absi(cpu.x, FALSE)));			{ ADC ABX }
	$79:	adc(rd(ea_absi(cpu.y, FALSE)));			{ ADC ABY }
	$61:	adc(rd(ea_inx));				{ ADC INX }
	$71:	adc(rd(ea_iny(FALSE)));				{ ADC INY }
	$E9, $EB:	sbc(fetch);				{ SBC IMM (EB unofficial) }
	$E5:	sbc(rd(ea_zp));					{ SBC ZP }
	$F5:	sbc(rd(ea_zpi(cpu.x)));				{ SBC ZPX }
	$ED:	sbc(rd(ea_abs));				{ SBC ABS }
	$FD:	sbc(rd(ea_absi(cpu.x, FALSE)));			{ SBC ABX }
	$F9:	sbc(rd(ea_absi(cpu.y, FALSE)));			{ SBC ABY }
	$E1:	sbc(rd(ea_inx));				{ SBC INX }
	$F1:	sbc(rd(ea_iny(FALSE)));				{ SBC INY }
	$C9:	compare(cpu.a, fetch);				{ CMP IMM }
	$C5:	compare(cpu.a, rd(ea_zp));			{ CMP ZP }
	$D5:	compare(cpu.a, rd(ea_zpi(cpu.x)));		{ CMP ZPX }
	$CD:	compare(cpu.a, rd(ea_abs));			{ CMP ABS }
	$DD:	compare(cpu.a, rd(ea_absi(cpu.x, FALSE)));	{ CMP ABX }
	$D9:	compare(cpu.a, rd(ea_absi(cpu.y, FALSE)));	{ CMP ABY }
	$C1:	compare(cpu.a, rd(ea_inx));			{ CMP INX }
	$D1:	compare(cpu.a, rd(ea_iny(FALSE)));		{ CMP INY }
	$E0:	compare(cpu.x, fetch);				{ CPX IMM }
	$E4:	compare(cpu.x, rd(ea_zp));			{ CPX ZP }
	$EC:	compare(cpu.x, rd(ea_abs));			{ CPX ABS }
	$C0:	compare(cpu.y, fetch);				{ CPY IMM }
	$C4:	compare(cpu.y, rd(ea_zp));			{ CPY ZP }
	$CC:	compare(cpu.y, rd(ea_abs));			{ CPY ABS }
	$24:	f_bit(rd(ea_zp));					{ BIT ZP }
	$2C:	f_bit(rd(ea_abs));				{ BIT ABS }

	{ shifts and steps: the accumulator, or memory read-modify-written }
	$0A:	begin implied; cpu.a := f_asl(cpu.a); end;	{ ASL A }
	$4A:	begin implied; cpu.a := f_lsr(cpu.a); end;	{ LSR A }
	$2A:	begin implied; cpu.a := f_rol(cpu.a); end;	{ ROL A }
	$6A:	begin implied; cpu.a := f_ror(cpu.a); end;	{ ROR A }
	$06:	rmw(ea_zp, K_ASL);				{ ASL ZP }
	$16:	rmw(ea_zpi(cpu.x), K_ASL);			{ ASL ZPX }
	$0E:	rmw(ea_abs, K_ASL);				{ ASL ABS }
	$1E:	rmw(ea_absi(cpu.x, TRUE), K_ASL);		{ ASL ABX }
	$46:	rmw(ea_zp, K_LSR);				{ LSR ZP }
	$56:	rmw(ea_zpi(cpu.x), K_LSR);			{ LSR ZPX }
	$4E:	rmw(ea_abs, K_LSR);				{ LSR ABS }
	$5E:	rmw(ea_absi(cpu.x, TRUE), K_LSR);		{ LSR ABX }
	$26:	rmw(ea_zp, K_ROL);				{ ROL ZP }
	$36:	rmw(ea_zpi(cpu.x), K_ROL);			{ ROL ZPX }
	$2E:	rmw(ea_abs, K_ROL);				{ ROL ABS }
	$3E:	rmw(ea_absi(cpu.x, TRUE), K_ROL);		{ ROL ABX }
	$66:	rmw(ea_zp, K_ROR);				{ ROR ZP }
	$76:	rmw(ea_zpi(cpu.x), K_ROR);			{ ROR ZPX }
	$6E:	rmw(ea_abs, K_ROR);				{ ROR ABS }
	$7E:	rmw(ea_absi(cpu.x, TRUE), K_ROR);		{ ROR ABX }
	$C6:	rmw(ea_zp, K_DEC);				{ DEC ZP }
	$D6:	rmw(ea_zpi(cpu.x), K_DEC);			{ DEC ZPX }
	$CE:	rmw(ea_abs, K_DEC);				{ DEC ABS }
	$DE:	rmw(ea_absi(cpu.x, TRUE), K_DEC);		{ DEC ABX }
	$E6:	rmw(ea_zp, K_INC);				{ INC ZP }
	$F6:	rmw(ea_zpi(cpu.x), K_INC);			{ INC ZPX }
	$EE:	rmw(ea_abs, K_INC);				{ INC ABS }
	$FE:	rmw(ea_absi(cpu.x, TRUE), K_INC);		{ INC ABX }
	$CA:	begin implied; cpu.x := (cpu.x - 1) and $FF; set_nz(cpu.x); end;	{ DEX }
	$88:	begin implied; cpu.y := (cpu.y - 1) and $FF; set_nz(cpu.y); end;	{ DEY }
	$E8:	begin implied; cpu.x := (cpu.x + 1) and $FF; set_nz(cpu.x); end;	{ INX }
	$C8:	begin implied; cpu.y := (cpu.y + 1) and $FF; set_nz(cpu.y); end;	{ INY }

	{ branches }
	$10:	branch(cpu.n and $80 = 0);			{ BPL }
	$30:	branch(cpu.n and $80 <> 0);			{ BMI }
	$50:	branch(cpu.v = 0);				{ BVC }
	$70:	branch(cpu.v <> 0);				{ BVS }
	$90:	branch(cpu.c = 0);				{ BCC }
	$B0:	branch(cpu.c <> 0);				{ BCS }
	$D0:	branch(cpu.z and $FF <> 0);			{ BNE }
	$F0:	branch(cpu.z and $FF = 0);			{ BEQ }

	{ jumps, calls, returns }
	$4C:	cpu.pc := ea_abs;				{ JMP ABS }
	$6C:	begin						{ JMP IND, the page not crossed }
			a := ea_abs;
			lo := rd(a);
			cpu.pc := lo or rd((a and $FF00) or ((a + 1) and $FF)) shl 8;
		end;
	$20:	begin						{ JSR }
			lo := fetch;
			rd($100 + cpu.s);
			push(cpu.pc shr 8);
			push(cpu.pc and $FF);
			cpu.pc := lo or rd(cpu.pc) shl 8;
		end;
	$60:	begin						{ RTS }
			implied;
			rd($100 + cpu.s);
			lo := pop;
			a := lo or pop shl 8;
			rd(a);
			cpu.pc := (a + 1) and $FFFF;
		end;
	$40:	begin						{ RTI }
			implied;
			rd($100 + cpu.s);
			cpu_set_p(pop);
			lo := pop;
			cpu.pc := lo or pop shl 8;
		end;
	$00:	begin						{ BRK }
			fetch;
			take_interrupt($FFFE, $10);
		end;

	{ the stack and the flags }
	$48:	begin implied; push(cpu.a); end;		{ PHA }
	$08:	begin implied; push(cpu_p or $10); end;		{ PHP }
	$68:	begin						{ PLA }
			implied;
			rd($100 + cpu.s);
			lda(pop);
		end;
	$28:	begin						{ PLP }
			implied;
			rd($100 + cpu.s);
			i_poll := cpu.i;
			cpu_set_p(pop);
		end;
	$18:	begin implied; cpu.c := 0; end;			{ CLC }
	$38:	begin implied; cpu.c := 1; end;			{ SEC }
	$58:	begin implied; i_poll := cpu.i; cpu.i := 0; end;	{ CLI }
	$78:	begin implied; i_poll := cpu.i; cpu.i := 1; end;	{ SEI }
	$B8:	begin implied; cpu.v := 0; end;			{ CLV }
	$D8:	begin implied; cpu.d := 0; end;			{ CLD }
	$F8:	begin implied; cpu.d := 1; end;			{ SED }

	{ the NOPs, official and not: their reads all the same }
	$EA, $1A, $3A, $5A, $7A, $DA, $FA:	implied;		{ NOP }
	$80, $82, $89, $C2, $E2:	fetch;			{ NOP IMM }
	$04, $44, $64:	rd(ea_zp);				{ NOP ZP }
	$14, $34, $54, $74, $D4, $F4:	rd(ea_zpi(cpu.x));	{ NOP ZPX }
	$0C:	rd(ea_abs);					{ NOP ABS }
	$1C, $3C, $5C, $7C, $DC, $FC:	rd(ea_absi(cpu.x, FALSE));	{ NOP ABX }

	{ the unofficial read-modify-writes: the step, then a second
	  operation on its result }
	$07:	lda(cpu.a or rmw(ea_zp, K_ASL));		{ SLO ZP }
	$17:	lda(cpu.a or rmw(ea_zpi(cpu.x), K_ASL));	{ SLO ZPX }
	$0F:	lda(cpu.a or rmw(ea_abs, K_ASL));		{ SLO ABS }
	$1F:	lda(cpu.a or rmw(ea_absi(cpu.x, TRUE), K_ASL));	{ SLO ABX }
	$1B:	lda(cpu.a or rmw(ea_absi(cpu.y, TRUE), K_ASL));	{ SLO ABY }
	$03:	lda(cpu.a or rmw(ea_inx, K_ASL));		{ SLO INX }
	$13:	lda(cpu.a or rmw(ea_iny(TRUE), K_ASL));		{ SLO INY }
	$27:	lda(cpu.a and rmw(ea_zp, K_ROL));		{ RLA ZP }
	$37:	lda(cpu.a and rmw(ea_zpi(cpu.x), K_ROL));	{ RLA ZPX }
	$2F:	lda(cpu.a and rmw(ea_abs, K_ROL));		{ RLA ABS }
	$3F:	lda(cpu.a and rmw(ea_absi(cpu.x, TRUE), K_ROL));	{ RLA ABX }
	$3B:	lda(cpu.a and rmw(ea_absi(cpu.y, TRUE), K_ROL));	{ RLA ABY }
	$23:	lda(cpu.a and rmw(ea_inx, K_ROL));		{ RLA INX }
	$33:	lda(cpu.a and rmw(ea_iny(TRUE), K_ROL));	{ RLA INY }
	$47:	lda(cpu.a xor rmw(ea_zp, K_LSR));		{ SRE ZP }
	$57:	lda(cpu.a xor rmw(ea_zpi(cpu.x), K_LSR));	{ SRE ZPX }
	$4F:	lda(cpu.a xor rmw(ea_abs, K_LSR));		{ SRE ABS }
	$5F:	lda(cpu.a xor rmw(ea_absi(cpu.x, TRUE), K_LSR));	{ SRE ABX }
	$5B:	lda(cpu.a xor rmw(ea_absi(cpu.y, TRUE), K_LSR));	{ SRE ABY }
	$43:	lda(cpu.a xor rmw(ea_inx, K_LSR));		{ SRE INX }
	$53:	lda(cpu.a xor rmw(ea_iny(TRUE), K_LSR));	{ SRE INY }
	$67:	adc(rmw(ea_zp, K_ROR));				{ RRA ZP }
	$77:	adc(rmw(ea_zpi(cpu.x), K_ROR));			{ RRA ZPX }
	$6F:	adc(rmw(ea_abs, K_ROR));			{ RRA ABS }
	$7F:	adc(rmw(ea_absi(cpu.x, TRUE), K_ROR));		{ RRA ABX }
	$7B:	adc(rmw(ea_absi(cpu.y, TRUE), K_ROR));		{ RRA ABY }
	$63:	adc(rmw(ea_inx, K_ROR));			{ RRA INX }
	$73:	adc(rmw(ea_iny(TRUE), K_ROR));			{ RRA INY }
	$C7:	compare(cpu.a, rmw(ea_zp, K_DEC));		{ DCP ZP }
	$D7:	compare(cpu.a, rmw(ea_zpi(cpu.x), K_DEC));	{ DCP ZPX }
	$CF:	compare(cpu.a, rmw(ea_abs, K_DEC));		{ DCP ABS }
	$DF:	compare(cpu.a, rmw(ea_absi(cpu.x, TRUE), K_DEC));	{ DCP ABX }
	$DB:	compare(cpu.a, rmw(ea_absi(cpu.y, TRUE), K_DEC));	{ DCP ABY }
	$C3:	compare(cpu.a, rmw(ea_inx, K_DEC));		{ DCP INX }
	$D3:	compare(cpu.a, rmw(ea_iny(TRUE), K_DEC));	{ DCP INY }
	$E7:	sbc(rmw(ea_zp, K_INC));				{ ISC ZP }
	$F7:	sbc(rmw(ea_zpi(cpu.x), K_INC));			{ ISC ZPX }
	$EF:	sbc(rmw(ea_abs, K_INC));			{ ISC ABS }
	$FF:	sbc(rmw(ea_absi(cpu.x, TRUE), K_INC));		{ ISC ABX }
	$FB:	sbc(rmw(ea_absi(cpu.y, TRUE), K_INC));		{ ISC ABY }
	$E3:	sbc(rmw(ea_inx, K_INC));			{ ISC INX }
	$F3:	sbc(rmw(ea_iny(TRUE), K_INC));			{ ISC INY }

	{ the other unofficial ones }
	$A7:	begin cpu.x := rd(ea_zp); lda(cpu.x); end;		{ LAX ZP }
	$B7:	begin cpu.x := rd(ea_zpi(cpu.y)); lda(cpu.x); end;	{ LAX ZPY }
	$AF:	begin cpu.x := rd(ea_abs); lda(cpu.x); end;		{ LAX ABS }
	$BF:	begin cpu.x := rd(ea_absi(cpu.y, FALSE)); lda(cpu.x); end;	{ LAX ABY }
	$A3:	begin cpu.x := rd(ea_inx); lda(cpu.x); end;		{ LAX INX }
	$B3:	begin cpu.x := rd(ea_iny(FALSE)); lda(cpu.x); end;	{ LAX INY }
	$AB:	begin cpu.x := fetch; lda(cpu.x); end;		{ LXA IMM: A = X = the operand }
	$87:	wr(ea_zp, cpu.a and cpu.x);			{ SAX ZP }
	$97:	wr(ea_zpi(cpu.y), cpu.a and cpu.x);		{ SAX ZPY }
	$8F:	wr(ea_abs, cpu.a and cpu.x);			{ SAX ABS }
	$83:	wr(ea_inx, cpu.a and cpu.x);			{ SAX INX }
	$0B, $2B:	begin					{ ANC IMM }
			lda(cpu.a and fetch);
			cpu.c := cpu.a shr 7;
		end;
	$4B:	cpu.a := f_lsr(cpu.a and fetch);			{ ALR IMM }
	$6B:	begin						{ ARR IMM }
			v := ((cpu.a and fetch) shr 1) or cpu.c shl 7;
			lda(v);
			cpu.c := (v shr 6) and 1;
			cpu.v := ((v shr 5) and 1) xor cpu.c;
		end;
	$8B:	lda((cpu.a or $EE) and cpu.x and fetch);	{ XAA IMM }
	$CB:	begin						{ AXS IMM }
			v := fetch;
			a := cpu.a and cpu.x;
			cpu.c := ord(a >= v);
			cpu.x := (a - v) and $FF;
			set_nz(cpu.x);
		end;
	$BB:	begin						{ LAS ABY }
			v := rd(ea_absi(cpu.y, FALSE)) and cpu.s;
			cpu.s := v;
			cpu.x := v;
			lda(v);
		end;
	$93:	begin a := ea_iny(TRUE); sh_store(a, cpu.a and cpu.x); end;	{ SHA INY }
	$9F:	begin a := ea_absi(cpu.y, TRUE); sh_store(a, cpu.a and cpu.x); end;	{ SHA ABY }
	$9E:	begin a := ea_absi(cpu.y, TRUE); sh_store(a, cpu.x); end;	{ SHX ABY }
	$9C:	begin a := ea_absi(cpu.x, TRUE); sh_store(a, cpu.y); end;	{ SHY ABX }
	$9B:	begin						{ TAS ABY }
			a := ea_absi(cpu.y, TRUE);
			cpu.s := cpu.a and cpu.x;
			sh_store(a, cpu.s);
		end;

	{ the twelve that stop the chip }
	else	begin
			cpu.jammed := TRUE;
			cpu.jam_op := op;
			run_until := cycles;
			bus_next_event := cycles;
			cpu.pc := (cpu.pc - 1) and $FFFF;
		end;
	end;
end;

{ ---- running ---- }

procedure	cpu_power;
var	lo	: longint;
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
var	lo	: longint;
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
var	k, base	: longint;
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
				if irq_wanted then
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
					execute(fetch);
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
