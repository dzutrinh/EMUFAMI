{*+
	F_MAP.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The board as the machine sees it and the eight mappers played.
	The interface every mapper keeps (TMAPPER, also 0 NROM): PRG in
	four 8 KB slots, CHR in eight 1 KB slots, plain pointers moved
	only by the mapper; $6000 RAM; writes with their cycle, Rebase,
	A12's rises; irq its line.  Then 1 MMC1, the plain logic boards
	(2 UxROM, 3 CNROM, 7 AxROM, 11 Color Dreams, 66 GxROM) and 4
	MMC3, each made by map_new from the cartridge's number.
-*}
{$ifdef VER70}{$F+}{$endif}
{$S-}		{ no stack check at every call }
unit	f_map;

interface

uses	f_sys, f_cart;

const
	MIRROR_ONE_A	= 3;	{ one screen, the first 1 KB }
	MIRROR_ONE_B	= 4;	{ one screen, the second }

var	prg_slot		: array[0 .. 3] of PBYTE;	{ $8000, $A000, $C000, $E000 }
	chr_slot		: array[0 .. 7] of PBYTE;	{ PPU $0000-$1FFF by 1 KB }
	chr_page		: array[0 .. 7] of longint;	{ and the 1 KB page each shows }
	chr_writable	: boolean;			{ CHR RAM }
	chr_rw			: array[0 .. 7] of boolean;	{ by slot: RAM, written to }
	wram			: PBYTE;			{ $6000-$7FFF, nil for none }
	wram_on			: boolean;
	wram_write		: boolean;			{ writes let through }
	a12_board		: boolean;			{ the board wants A12 rises }
	bus_conflicts	: boolean;			{ a write ANDed with the ROM's byte there }
	mirroring		: longint;			{ MIRROR_* of F_CART or above }

type
	PMAPPER	= ^TMAPPER;
	TMAPPER	= object
		cart	: PCART;
		chr_mem	: PBYTE;	{ the CHR RAM, nil for CHR ROM (the cartridge's) }
		chr_len	: longint;
		ram		: PBYTE;	{ the board's RAM at $6000 }
		ram_len	: longint;
		irq		: boolean;
		irq_at	: longint;	{ the CPU cycle irq was raised on }
		constructor	Init(c: PCART);
		destructor	Done; virtual;
		procedure	Reset; virtual;			{ the slots as at power-up }
		procedure	Write(addr, v, at: longint); virtual;	{ $8000-$FFFF, at cycle at }
		procedure	Rebase(k: longint); virtual;
		procedure	A12Rise(cycle: longint); virtual;	{ seen on that CPU cycle }
		procedure	RaiseIrq(cycle: longint);
		{ ---- for the mappers: banks counted modulo what there is ---- }
		procedure	Prg8(slot, bank: longint);
		procedure	Prg16(half, bank: longint);	{ half 0: $8000, 1: $C000 }
		procedure	Prg32(bank: longint);
		procedure	Chr1(slot, bank: longint);
		procedure	Chr4(half, bank: longint);
		procedure	Chr8(bank: longint);
	end;

var	board	: PMAPPER;	{ the cartridge's, nil when none }

function	map_has(mapper: longint): boolean;	{ a mapper played }
function	map_new(c: PCART): PMAPPER;		{ the cartridge's board, nil if not played }

implementation

constructor	TMAPPER.Init(c: PCART);
begin
	cart := c;
	if c^.chr_size > 0 then
	begin
		chr_mem := nil;
		chr_len := c^.chr_size;
		chr_writable := FALSE;
	end
	else
	begin
		{ 8 KB at least, 32 KB at most: one block }
		chr_len := c^.chr_ram + c^.chr_nvram;
		if chr_len < 8192 then chr_len := 8192;
		if chr_len > 32768 then chr_len := 32768;
		chr_mem := malloc(chr_len);
		fillchar(chr_mem^, chr_len, 0);
		chr_writable := TRUE;
	end;
	ram_len := c^.prg_ram + c^.prg_nvram;
	if ram_len > 0 then
	begin
		if ram_len < 8192 then ram_len := 8192;
		if ram_len > 32768 then ram_len := 32768;
		ram := malloc(ram_len);
		fillchar(ram^, ram_len, 0);
	end
	else	ram := nil;
	wram := ram;
	wram_on := ram <> nil;
	wram_write := TRUE;
	a12_board := FALSE;
	bus_conflicts := FALSE;
	irq := FALSE;
	irq_at := 0;
	mirroring := c^.mirror;
end;

destructor	TMAPPER.Done;
begin
	free(pointer(chr_mem));
	if ram <> nil then free(pointer(ram));
	wram := nil;
	wram_on := FALSE;
	a12_board := FALSE;
	bus_conflicts := FALSE;
end;

procedure	TMAPPER.Reset;
begin
	Prg32(0);
	if cart^.prg_size = 16384 then Prg16(1, 0);
	Chr8(0);
end;

procedure	TMAPPER.Write(addr, v, at: longint);
begin
end;

procedure	TMAPPER.Rebase(k: longint);
begin
end;

procedure	TMAPPER.A12Rise(cycle: longint);
begin
end;

procedure	TMAPPER.RaiseIrq(cycle: longint);
begin
	if not irq then irq_at := cycle;
	irq := TRUE;
end;

procedure	TMAPPER.Prg8(slot, bank: longint);
var	n	: longint;
begin
	n := cart^.prg_size shr 13;
	prg_slot[slot and 3] := cart_prg(cart^, (bank mod n) shl 13);
end;

procedure	TMAPPER.Prg16(half, bank: longint);
begin
	Prg8(half * 2, bank * 2);
	Prg8(half * 2 + 1, bank * 2 + 1);
end;

procedure	TMAPPER.Prg32(bank: longint);
begin
	Prg16(0, bank * 2);
	Prg16(1, bank * 2 + 1);
end;

procedure	TMAPPER.Chr1(slot, bank: longint);
var	n	: longint;
begin
	n := chr_len shr 10;
	bank := bank mod n;
	if chr_mem = nil then chr_slot[slot and 7] := cart_chr(cart^, bank shl 10)
	else	chr_slot[slot and 7] := padd(chr_mem, bank shl 10);
	chr_page[slot and 7] := bank;
	chr_rw[slot and 7] := chr_writable;
end;

procedure	TMAPPER.Chr4(half, bank: longint);
var	i	: longint;
begin
	for i := 0 to 3 do Chr1(half * 4 + i, bank * 4 + i);
end;

procedure	TMAPPER.Chr8(bank: longint);
begin
	Chr4(0, bank * 2);
	Chr4(1, bank * 2 + 1);
end;


{ ======== 1 MMC1 ======== }

{ Mapper 1, MMC1: five one-bit writes fill a register (the fifth's
  address picks it), bit 7 resets; the second of two writes in a
  row ignored.  Mirroring, PRG modes, 8 or 4+4 KB of CHR, the RAM
  off by PRG bit 4; 512 KB boards' outer bank, SOROM/SXROM's RAM
  banks from CHR 0. }

type	PMMC1	= ^TMMC1;
	TMMC1	= object(TMAPPER)
		shift, count	: longint;
		control		: longint;
		bank0, bank1, prg	: longint;	{ CHR 0, CHR 1, PRG }
		last_write	: longint;
		procedure	Reset; virtual;
		procedure	Write(addr, v, at: longint); virtual;
		procedure	Rebase(k: longint); virtual;
		procedure	Apply;
	end;

procedure	TMMC1.Apply;
var	outer, b	: longint;
begin
	case control and 3 of
	0:	mirroring := MIRROR_ONE_A;
	1:	mirroring := MIRROR_ONE_B;
	2:	mirroring := MIRROR_V;
	3:	mirroring := MIRROR_H;
	end;
	outer := 0;
	if cart^.prg_size > 262144 then outer := bank0 and $10;
	b := prg and $0F;
	case (control shr 2) and 3 of
	0, 1:	Prg32((outer or b) shr 1);
	2:	begin
			Prg16(0, outer);
			Prg16(1, outer or b);
		end;
	3:	begin
			Prg16(0, outer or b);
			Prg16(1, outer or $0F);
		end;
	end;
	if control and $10 = 0 then Chr8(bank0 shr 1)
	else
	begin
		Chr4(0, bank0);
		Chr4(1, bank1);
	end;
	wram_on := (ram <> nil) and (prg and $10 = 0);
	if ram_len >= 32768 then wram := padd(ram, ((bank0 shr 2) and 3) shl 13)
	else if ram_len >= 16384 then wram := padd(ram, ((bank0 shr 3) and 1) shl 13);
end;

procedure	TMMC1.Reset;
begin
	shift := 0;
	count := 0;
	control := $0C;
	bank0 := 0;
	bank1 := 0;
	prg := 0;
	last_write := -10;
	Apply;
end;

procedure	TMMC1.Write(addr, v, at: longint);
var	follows	: boolean;
begin
	if addr < $8000 then exit;
	follows := at = last_write + 1;
	last_write := at;
	if follows then exit;
	if v and $80 <> 0 then
	begin
		shift := 0;
		count := 0;
		control := control or $0C;
		Apply;
		exit;
	end;
	shift := shift or (v and 1) shl count;
	inc(count);
	if count < 5 then exit;
	case (addr shr 13) and 3 of
	0:	control := shift;
	1:	bank0 := shift;
	2:	bank1 := shift;
	3:	prg := shift;
	end;
	shift := 0;
	count := 0;
	Apply;
end;

procedure	TMMC1.Rebase(k: longint);
begin
	dec(last_write, k);
end;

{ ======== the plain logic boards ======== }

{ The boards of plain logic chips, one latch at $8000-$FFFF:
  2 UxROM (16 KB at $8000, the last at $C000), 3 CNROM (8 KB of
  CHR), 7 AxROM (32 KB, bit 4 the one screen), 11 Color Dreams (32
  KB bits 0-1, CHR bits 4-7), 66 GxROM (32 KB bits 4-5, CHR bits
  0-1).  Bus conflicts on 2, 3, 7 with NES 2.0 submapper 2. }

type
	PUXROM	= ^TUXROM;
	TUXROM	= object(TMAPPER)
		procedure	Reset; virtual;
		procedure	Write(addr, v, at: longint); virtual;
	end;

	PCNROM	= ^TCNROM;
	TCNROM	= object(TMAPPER)
		procedure	Write(addr, v, at: longint); virtual;
	end;

	PAXROM	= ^TAXROM;
	TAXROM	= object(TMAPPER)
		procedure	Reset; virtual;
		procedure	Write(addr, v, at: longint); virtual;
	end;

	PCOLOR	= ^TCOLOR;
	TCOLOR	= object(TMAPPER)
		procedure	Write(addr, v, at: longint); virtual;
	end;

	PGXROM	= ^TGXROM;
	TGXROM	= object(TMAPPER)
		procedure	Write(addr, v, at: longint); virtual;
	end;

{ ---- UxROM ---- }

procedure	TUXROM.Reset;
begin
	TMAPPER.Reset;
	Prg16(0, 0);
	Prg16(1, cart^.prg_size shr 14 - 1);
end;

procedure	TUXROM.Write(addr, v, at: longint);
begin
	if addr >= $8000 then Prg16(0, v);
end;

{ ---- CNROM ---- }

procedure	TCNROM.Write(addr, v, at: longint);
begin
	if addr >= $8000 then Chr8(v);
end;

{ ---- AxROM ---- }

procedure	TAXROM.Reset;
begin
	TMAPPER.Reset;
	mirroring := MIRROR_ONE_A;
end;

procedure	TAXROM.Write(addr, v, at: longint);
begin
	if addr < $8000 then exit;
	Prg32(v and 7);
	mirroring := MIRROR_ONE_A + (v shr 4) and 1;
end;

{ ---- Color Dreams ---- }

procedure	TCOLOR.Write(addr, v, at: longint);
begin
	if addr < $8000 then exit;
	Prg32(v and 3);
	Chr8(v shr 4);
end;

{ ---- GxROM ---- }

procedure	TGXROM.Write(addr, v, at: longint);
begin
	if addr < $8000 then exit;
	Prg32((v shr 4) and 3);
	Chr8(v and 3);
end;

{ ======== 4 MMC3 ======== }

{ Mapper 4, MMC3: $8000 picks a register and the modes, $8001
  writes it (two 2 KB and four 1 KB CHR banks, two 8 KB PRG
  banks); $A000 mirroring, $A001 the RAM.  The scanline counter
  clocked by A12's rises raises the IRQ; revision A (submapper 4)
  only on reaching 0. }

type
	PMMC3	= ^TMMC3;
	TMMC3	= object(TMAPPER)
		select	: longint;
		regs	: array[0 .. 7] of longint;
		latch	: longint;
		counter	: longint;
		reload	: boolean;
		enabled	: boolean;
		rev_a	: boolean;	{ NEC's revision A }
		procedure	Reset; virtual;
		procedure	Write(addr, v, at: longint); virtual;
		procedure	A12Rise(cycle: longint); virtual;
		procedure	Apply;
	end;

procedure	TMMC3.Apply;
var	n, inv	: longint;
begin
	n := cart^.prg_size shr 13;
	if select and $40 = 0 then
	begin
		Prg8(0, regs[6]);
		Prg8(2, n - 2);
	end
	else
	begin
		Prg8(0, n - 2);
		Prg8(2, regs[6]);
	end;
	Prg8(1, regs[7]);
	Prg8(3, n - 1);
	inv := (select shr 5) and 4;
	Chr1(0 xor inv, regs[0] and $FE);
	Chr1(1 xor inv, regs[0] or 1);
	Chr1(2 xor inv, regs[1] and $FE);
	Chr1(3 xor inv, regs[1] or 1);
	Chr1(4 xor inv, regs[2]);
	Chr1(5 xor inv, regs[3]);
	Chr1(6 xor inv, regs[4]);
	Chr1(7 xor inv, regs[5]);
end;

procedure	TMMC3.Reset;
begin
	select := 0;
	regs[0] := 0;
	regs[1] := 2;
	regs[2] := 4;
	regs[3] := 5;
	regs[4] := 6;
	regs[5] := 7;
	regs[6] := 0;
	regs[7] := 1;
	latch := 0;
	counter := 0;
	reload := FALSE;
	enabled := FALSE;
	irq := FALSE;
	a12_board := TRUE;
	rev_a := cart^.submapper = 4;
	Apply;
end;

procedure	TMMC3.Write(addr, v, at: longint);
begin
	if addr < $8000 then exit;
	{ the register: A13-A15 and A0, $8000 is 8, $8001 9 ... $E001 15 }
	case ((addr shr 12) and $E) or (addr and 1) of
	8:	begin
			select := v;
			Apply;
		end;
	9:	begin
			regs[select and 7] := v;
			Apply;
		end;
	$A:	if cart^.mirror <> MIRROR_FOUR then mirroring := 1 - (v and 1);
	$B:	begin
			wram_on := (ram <> nil) and (v and $80 <> 0);
			wram_write := v and $40 = 0;
		end;
	$C:	latch := v;
	$D:	begin
			counter := 0;
			reload := TRUE;
		end;
	$E:	begin
			enabled := FALSE;
			irq := FALSE;
		end;
	$F:	enabled := TRUE;
	end;
end;

procedure	TMMC3.A12Rise(cycle: longint);
var	was	: longint;
	fresh	: boolean;
begin
	was := counter;
	fresh := reload;
	if (counter = 0) or reload then
	begin
		counter := latch;
		reload := FALSE;
	end
	else	dec(counter);
	if (counter = 0) and enabled then
		if not rev_a or (was <> 0) or fresh then RaiseIrq(cycle);
end;

{ ======== a cartridge's board ======== }

function	map_has(mapper: longint): boolean;
begin
	case mapper of
	0, 1, 2, 3, 4, 7, 11, 66:
		map_has := TRUE;
	else	map_has := FALSE;
	end;
end;

function	map_new(c: PCART): PMAPPER;
var	b	: PMAPPER;
begin
	case c^.mapper of
	0:	b := new(PMAPPER, Init(c));
	1:	b := new(PMMC1, Init(c));
	2:	b := new(PUXROM, Init(c));
	3:	b := new(PCNROM, Init(c));
	4:	b := new(PMMC3, Init(c));
	7:	b := new(PAXROM, Init(c));
	11:	b := new(PCOLOR, Init(c));
	66:	b := new(PGXROM, Init(c));
	else	b := nil;
	end;
	{ UxROM, CNROM, AxROM boards that AND a write with the ROM's byte:
	  NES 2.0 submapper 2 }
	if b <> nil then bus_conflicts := (c^.mapper in [2, 3, 7]) and (c^.submapper = 2);
	map_new := b;
end;

begin
	{ TMT leaves globals as memory had them }
	board := nil;
	bus_conflicts := FALSE;
	wram := nil;
	wram_on := FALSE;
	wram_write := FALSE;
	a12_board := FALSE;
	chr_writable := FALSE;
	fillchar(chr_rw, sizeof(chr_rw), 0);
end.
