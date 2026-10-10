{*+
	F_PAL.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The NES's 64 colours in DAC entries 0-63, from a model of the
	2C02's signal (NESdev's "NTSC video") decoded as YIQ; eight sets,
	one per emphasis.
-*}
{$ifdef VER70}{$F+}{$N+}{$E+}{$endif}
unit	f_pal;

interface

const
	NES_COLOURS	= 64;

type
	NES_RGB		= packed record
		r, g, b	: byte;
	end;
	NES_SET		= array[0 .. NES_COLOURS - 1] of NES_RGB;

var	nes_sets	: array[0 .. 7] of NES_SET;	{ 8-bit channels, by emphasis }

procedure	pal_make;
procedure	pal_show(emphasis: longint);		{ entries 0..63, when it changed }
procedure	pal_forget;				{ the DAC was changed: show again }

implementation

uses
	f_vga;

const
	DAMP	= 0.746;

var
	shown	: longint;

function	channel(v: double): byte;
begin
	if v <= 0 then channel := 0
	else if v >= 1 then channel := 255
	else	channel := round(v * 255);
end;

procedure	pal_make;
const
	LEVELS	: array[0 .. 7] of double =
		(0.350, 0.518, 0.962, 1.550,	{ the signal low, by luma }
		 1.094, 1.506, 1.962, 1.962);	{ and high }
	BLACK	= 0.518;
	WHITE	= 1.962;
	HUE	= 3.75;
var	e, n, c, l, p		: longint;
	lo, hi, s, y, i, q, a	: double;

	function in_phase(k: longint): boolean;
	begin
		in_phase := (k + p) mod 12 < 6;
	end;

begin
	for e := 0 to 7 do
		for n := 0 to NES_COLOURS - 1 do
		begin
			c := n and 15;
			l := n shr 4;
			if c > 13 then l := 1;
			lo := LEVELS[l];
			hi := LEVELS[4 + l];
			if c = 0 then lo := hi;
			if c > 12 then hi := lo;
			y := 0;
			i := 0;
			q := 0;
			for p := 0 to 11 do
			begin
				if in_phase(c) then s := hi else s := lo;
				if ((e and 1 <> 0) and in_phase(0)) or ((e and 2 <> 0) and in_phase(4))
				or ((e and 4 <> 0) and in_phase(8)) then s := s * DAMP;
				s := (s - BLACK) / (WHITE - BLACK);
				a := pi / 6 * (p + HUE);
				y := y + s;
				i := i + s * cos(a);
				q := q + s * sin(a);
			end;
			y := y / 12;
			i := i / 6;
			q := q / 6;
			nes_sets[e][n].r := channel(y + 0.946882 * i + 0.623557 * q);
			nes_sets[e][n].g := channel(y - 0.274788 * i - 0.635691 * q);
			nes_sets[e][n].b := channel(y - 1.108545 * i + 1.709007 * q);
		end;
	shown := -1;
end;

procedure	pal_show(emphasis: longint);
var	n	: longint;
begin
	emphasis := emphasis and 7;
	if emphasis = shown then exit;
	for n := 0 to NES_COLOURS - 1 do
		with nes_sets[emphasis][n] do vga_colour(n, r, g, b);
	shown := emphasis;
end;

procedure	pal_forget;
begin
	shown := -1;
end;

begin
	shown := -1;
end.
