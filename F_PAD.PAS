{*+
	F_PAD.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The two controllers: pad_buttons latched by $4016 bit 0, shifted
	out by $4016 and $4017 reads (A first, then 1s); up with down or
	left with right let go, as a real pad cannot.
-*}
{$S-}		{ no stack check at every call }
unit	f_pad;

interface

const
	PAD_A		= $01;
	PAD_B		= $02;
	PAD_SELECT	= $04;
	PAD_START	= $08;
	PAD_UP		= $10;
	PAD_DOWN	= $20;
	PAD_LEFT	= $40;
	PAD_RIGHT	= $80;

var	pad_buttons	: array[0 .. 1] of longint;

procedure	pad_power;
procedure	pad_write(v: longint);			{ $4016 }
function	pad_read(n: longint): longint;		{ $4016 (0) or $4017 (1): bit 0 }

implementation

var	strobe	: boolean;
	shift	: array[0 .. 1] of longint;

function	held(n: longint): longint;
var	b	: longint;
begin
	b := pad_buttons[n] and $FF;
	if b and (PAD_UP or PAD_DOWN) = PAD_UP or PAD_DOWN then b := b and not PAD_DOWN;
	if b and (PAD_LEFT or PAD_RIGHT) = PAD_LEFT or PAD_RIGHT then b := b and not PAD_RIGHT;
	held := b;
end;

procedure	pad_power;
begin
	strobe := FALSE;
	shift[0] := 0;
	shift[1] := 0;
end;

procedure	pad_write(v: longint);
begin
	strobe := v and 1 <> 0;
	if strobe then
	begin
		shift[0] := held(0);
		shift[1] := held(1);
	end;
end;

function	pad_read(n: longint): longint;
begin
	if strobe then shift[n] := held(n);
	pad_read := shift[n] and 1;
	shift[n] := (shift[n] shr 1) or $80;
end;

begin
	pad_buttons[0] := 0;
	pad_buttons[1] := 0;
	pad_power;
end.
