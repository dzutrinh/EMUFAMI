{*+
	F_MAP.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The board as the machine sees it and the interface every mapper
	keeps (TMAPPER, also NROM): PRG in four 8 KB slots, CHR in eight
	1 KB slots, plain pointers moved only by the mapper; $6000 RAM;
	writes with their cycle, Rebase, A12's rises; irq its line.
-*}
unit	f_map;

interface

uses	f_sys, f_cart;

const	MIRROR_ONE_A	= 3;	{ one screen, the first 1 KB }
	MIRROR_ONE_B	= 4;	{ one screen, the second }

var	prg_slot	: array[0 .. 3] of PBYTE;	{ $8000, $A000, $C000, $E000 }
	chr_slot	: array[0 .. 7] of PBYTE;	{ PPU $0000-$1FFF by 1 KB }
	chr_writable	: boolean;			{ CHR RAM }
	chr_rw		: array[0 .. 7] of boolean;	{ by slot: RAM, written to }
	wram		: PBYTE;			{ $6000-$7FFF, nil for none }
	wram_on		: boolean;
	wram_write	: boolean;			{ writes let through }
	a12_board	: boolean;			{ the board wants A12 rises }
	bus_conflicts	: boolean;			{ a write ANDed with the ROM's byte there }
	mirroring	: longint;			{ MIRROR_* of F_CART or above }

type	PMAPPER	= ^TMAPPER;
	TMAPPER	= object
		cart	: PCART;
		chr_mem	: PBYTE;	{ CHR ROM, or the RAM made for it }
		chr_len	: longint;
		ram	: PBYTE;	{ the board's RAM at $6000 }
		ram_len	: longint;
		irq	: boolean;
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

implementation

constructor	TMAPPER.Init(c: PCART);
begin
	cart := c;
	if c^.chr_size > 0 then
	begin
		chr_mem := c^.chr;
		chr_len := c^.chr_size;
		chr_writable := FALSE;
	end
	else
	begin
		chr_len := c^.chr_ram + c^.chr_nvram;
		if chr_len < 8192 then chr_len := 8192;
		chr_mem := malloc(chr_len);
		fillchar(chr_mem^, chr_len, 0);
		chr_writable := TRUE;
	end;
	ram_len := c^.prg_ram + c^.prg_nvram;
	if ram_len > 0 then
	begin
		if ram_len < 8192 then ram_len := 8192;
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
	if cart^.chr_size = 0 then free(pointer(chr_mem));
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
	prg_slot[slot and 3] := cart^.prg + (bank mod n) shl 13;
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
	chr_slot[slot and 7] := chr_mem + (bank mod n) shl 10;
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
