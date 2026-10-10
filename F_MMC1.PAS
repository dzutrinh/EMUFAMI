{*+
	F_MMC1.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	Mapper 1, MMC1: five one-bit writes fill a register (the fifth's
	address picks it), bit 7 resets; the second of two writes in a
	row ignored.  Mirroring, PRG modes, 8 or 4+4 KB of CHR, the RAM
	off by PRG bit 4; 512 KB boards' outer bank, SOROM/SXROM's RAM
	banks from CHR 0.
-*}
unit	f_mmc1;

interface

uses	f_cart, f_map;

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


implementation

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
	if ram_len >= 32768 then wram := ram + ((bank0 shr 2) and 3) shl 13
	else if ram_len >= 16384 then wram := ram + ((bank0 shr 3) and 1) shl 13;
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

end.
