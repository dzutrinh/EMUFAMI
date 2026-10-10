{*+
	F_MMC3.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	Mapper 4, MMC3: $8000 picks a register and the modes, $8001
	writes it (two 2 KB and four 1 KB CHR banks, two 8 KB PRG
	banks); $A000 mirroring, $A001 the RAM.  The scanline counter
	clocked by A12's rises raises the IRQ; revision A (submapper 4)
	only on reaching 0.
-*}
unit	f_mmc3;

interface

uses	f_cart, f_map;

type	PMMC3	= ^TMMC3;
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

implementation

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
	case addr and $E001 of
	$8000:	begin
			select := v;
			Apply;
		end;
	$8001:	begin
			regs[select and 7] := v;
			Apply;
		end;
	$A000:	if cart^.mirror <> MIRROR_FOUR then mirroring := 1 - (v and 1);
	$A001:	begin
			wram_on := (ram <> nil) and (v and $80 <> 0);
			wram_write := v and $40 = 0;
		end;
	$C000:	latch := v;
	$C001:	begin
			counter := 0;
			reload := TRUE;
		end;
	$E000:	begin
			enabled := FALSE;
			irq := FALSE;
		end;
	$E001:	enabled := TRUE;
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

end.
