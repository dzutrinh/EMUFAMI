{*+
	F_DISC.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The boards of plain logic chips, one latch at $8000-$FFFF:
	2 UxROM (16 KB at $8000, the last at $C000), 3 CNROM (8 KB of
	CHR), 7 AxROM (32 KB, bit 4 the one screen), 11 Color Dreams (32
	KB bits 0-1, CHR bits 4-7), 66 GxROM (32 KB bits 4-5, CHR bits
	0-1).  Bus conflicts on 2, 3, 7 with NES 2.0 submapper 2.
-*}
unit	f_disc;

interface

uses	f_cart, f_map;

type	PUXROM	= ^TUXROM;
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

implementation

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

end.
