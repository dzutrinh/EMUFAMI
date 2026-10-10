{*+
	F_BUS.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The CPU's memory map and the clock: 2 KB of RAM, the PPU's and
	APU's registers, the pads, the board's RAM and PRG through a map
	of 2 KB pages.  The PPU and APU catch up when touched, bus_sync at
	events; a board write first brings the PPU to the step's start.
	What nothing answers reads as the last value on the bus.
-*}
{$X+}
unit	f_bus;

interface

uses	f_sys, f_map;

var	ram		: array[0 .. 2047] of byte;
	cycles		: longint;	{ CPU cycles since the last rebase }
	cycles_base	: longint;	{ what rebases took off }
	bus_next_event	: longint;
	bus_open	: longint;	{ the data bus's last value }
	dma_page	: longint;	{ an OAM DMA asked for, or -1 }
	step_cycle	: longint;	{ the cycle the CPU's step began on }
	{ the CPU's map by 2 KB pages, what reads and writes reach as plain
	  memory (the page's address taken off), nil where the bus decides }
	bus_rpage	: array[0 .. 31] of PBYTE;
	bus_wpage	: array[0 .. 31] of PBYTE;

procedure	bus_power;

procedure	bus_map;			{ the pages made again }
function	bus_read(addr: longint): longint;
procedure	bus_write(addr, v: longint);
procedure	bus_sync;			{ the PPU and APU up to cycles }
function	bus_irq: boolean;		{ the IRQ line }
function	bus_irq_at: longint;		{ the cycle it went high, when it is }
procedure	bus_rebase;			{ cycles back to 0, all with it }

implementation

uses	f_cart, f_ppu, f_apu, f_pad;

procedure	bus_power;
begin
	fillchar(ram, sizeof(ram), 0);
	cycles := 0;
	cycles_base := 0;
	bus_next_event := 0;
	bus_open := 0;
	dma_page := -1;
	step_cycle := 0;
	pad_power;
	ppu_power;
	apu_power;
	apu_dmc_read := {$ifdef FPC}@{$endif}bus_read;
end;

procedure	bus_map;
var	i, s	: longint;
begin
	for i := 0 to 31 do
	begin
		bus_rpage[i] := nil;
		bus_wpage[i] := nil;
	end;
	for i := 0 to 3 do
	begin
		bus_rpage[i] := PBYTE(@ram) - i * $800;
		bus_wpage[i] := bus_rpage[i];
	end;
	if wram_on and (wram <> nil) then
		for i := 12 to 15 do
		begin
			bus_rpage[i] := wram - $6000;
			if wram_write then bus_wpage[i] := bus_rpage[i];
		end;
	if board <> nil then
		for i := 16 to 31 do
		begin
			s := (i - 16) shr 2;
			bus_rpage[i] := prg_slot[s] - ($8000 + s * $2000);
		end;
end;

function	bus_read(addr: longint): longint;
var	v	: longint;
begin
	case addr shr 13 of
	0:	v := ram[addr and $7FF];
	1:	begin
			v := ppu_read(addr and 7, cycles);
			{ $2007 moves A12: the board's IRQ may rise }
			if addr and 7 = 7 then bus_next_event := cycles;
		end;
	2:	if addr < $4020 then
		begin
			case addr of
			$4015:	begin
					v := apu_read(addr, cycles) or (bus_open and $20);
					bus_next_event := cycles;	{ a stall; the IRQ cleared }
				end;
			$4016, $4017:
				v := (bus_open and $E0) or pad_read(addr - $4016);
			else	v := bus_open;
			end;
		end
		else	v := bus_open;
	3:	if wram_on then v := (wram + (addr and $1FFF))^
		else	v := bus_open;
	else	v := (prg_slot[(addr shr 13) and 3] + (addr and $1FFF))^;
	end;
	bus_open := v;
	bus_read := v;
end;

procedure	bus_write(addr, v: longint);
begin
	bus_open := v;
	case addr shr 13 of
	0:	ram[addr and $7FF] := v;
	1:	begin
			ppu_write(addr and 7, v, cycles);
			bus_next_event := cycles;
		end;
	2:	if addr < $4020 then
		begin
			if addr = $4014 then
			begin
				dma_page := v;
				bus_next_event := cycles;
			end
			else if addr <= $4017 then
			begin
				if addr = $4016 then pad_write(v)
				else	apu_write(addr, v, cycles);
				bus_next_event := cycles;
			end;
		end;
	3:	if wram_on and wram_write then (wram + (addr and $1FFF))^ := v;
	else
	begin
		if bus_conflicts then v := v and (prg_slot[(addr shr 13) and 3] + (addr and $1FFF))^;
		ppu_run(step_cycle);
		board^.Write(addr, v, cycles);
		ppu_split(cycles, SPLIT_FETCH);	{ its banks from there on the line }
		bus_map;
		bus_next_event := cycles;	{ its IRQ may have gone }
	end;
	end;
end;

procedure	bus_sync;
var	a, b	: longint;
begin
	ppu_run(cycles);
	b := apu_next;
	if cycles >= b then
	begin
		apu_run(cycles);
		b := apu_next;
	end;
	a := ppu_next;
	if a < b then bus_next_event := a else bus_next_event := b;
	if (apu_stall > 0) or (dma_page >= 0) then bus_next_event := cycles;
end;

function	bus_irq: boolean;
begin
	bus_irq := (apu_irq_at <> APU_NEVER) or board^.irq;
end;

function	bus_irq_at: longint;
var	c	: longint;
begin
	c := apu_irq_at;
	if board^.irq and (board^.irq_at < c) then c := board^.irq_at;
	bus_irq_at := c;
end;

procedure	rebase_by(e: longint);
var	k, j	: longint;
begin
	k := cycles and not 1;		{ even: the odd and even cycles stay so }
	if ppu_region = TV_PAL then k := cycles - cycles mod 10;	{ and whole dots at 16/5 }
	j := k - e;			{ the PPU's, APU's and board's }
	dec(cycles, k);
	inc(cycles_base, k);
	dec(bus_next_event, k);
	dec(step_cycle, k);
	ppu_rebase(j);
	apu_rebase(j);
	board^.Rebase(j);
	dec(board^.irq_at, j);
	{ a line long high stays in the past (no wrap after hours) }
	if board^.irq_at < -$40000000 then board^.irq_at := -$40000000;
end;

procedure	bus_rebase;
begin
	rebase_by(0);
end;


end.
