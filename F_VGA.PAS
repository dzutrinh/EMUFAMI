{*+
	F_VGA.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The screen: VGA tweaked to 256x240 at 60 Hz (mode 13h, chain-4,
	the CRTC at 64 characters and 480 lines shown twice), only on a
	VGA (vga_present); a 256x240 buffer flipped after the retrace;
	text in the BIOS's 8x8 font.
-*}
{$X+}
{$ifdef VER70}{$F+}{$endif}
unit	f_vga;

interface

uses
	f_sys;

const
	VGA_W		= 256;
	VGA_H		= 240;
	VGA_SIZE	= VGA_W * VGA_H;

type
	PSCREEN	= ^SCREEN;
	SCREEN	= array[0 .. VGA_H - 1, 0 .. VGA_W - 1] of byte;

function	vga_present: boolean;		{ a VGA, by the BIOS }
procedure	vga_start;			{ 256x240, the font read }
procedure	vga_end;			{ back to 80x25 text }
procedure	vga_retrace;			{ the next vertical retrace begun }
procedure	vga_colour(i, r, g, b: longint);	{ DAC entry i, 8-bit channels }
procedure	vga_flip(buf: pointer);		{ a 256x240 buffer to the screen }
{ into a 256x240 buffer: text in the 8x8 font (codes 32-127), a bar }
procedure	vga_text(buf: PSCREEN; x, y: longint; const s: string; c: longint);
procedure	vga_bar(buf: PSCREEN; x, y, w, h, c: longint);

implementation

uses
	f_dos;

const
	TWEAK_MISC	= $E3;
	{ the CRTC by index: horizontal from Tweak's 256-wide modes,
	  vertical from Mode X's 480 lines }
	TWEAK_CRTC	: array[0 .. 17, 0 .. 1] of byte = (
		($00, $5F), ($01, $3F), ($02, $40), ($03, $82), ($04, $4A),
		($05, $9A), ($06, $0D), ($07, $3E), ($08, $00), ($09, $41),
		($10, $EA), ($11, $AC), ($12, $DF), ($13, $20), ($14, $40),
		($15, $E7), ($16, $06), ($17, $A3));

var	font	: array[0 .. 127, 0 .. 7] of byte;
	active	: boolean;
	hooked	: boolean;

{ the display combination (INT 10h 1A00h): a VGA, colour or mono }
function	vga_present: boolean;
var	ax, bx, es, bp	: longint;
begin
	ax := $1A00;
	bx := 0;
	real_int($10, ax, bx, es, bp);
	vga_present := (ax and $FF = $1A) and ((bx and $FF = 7) or (bx and $FF = 8));
end;

procedure	set_mode(m: longint);
var	ax, bx, es, bp	: longint;
begin
	ax := m;
	bx := 0;
	real_int($10, ax, bx, es, bp);
end;

{ the VGA BIOS's 8x8 font (INT 10h 1130h, BH 3): its first 128 }
procedure	read_font;
var	ax, bx, es, bp	: longint;
begin
	ax := $1130;
	bx := $0300;
	real_int($10, ax, bx, es, bp);
	low_get(es * 16 + bp, font, sizeof(font));
end;

{ whatever ends the program, the screen goes back to text }
procedure	vga_exit;
begin
	vga_end;
end;

{ the 64 KB window at $A0000 cleared }
procedure	vga_clear;
var	zero	: array[0 .. 4095] of byte;
	i	: longint;
begin
	fillchar(zero, sizeof(zero), 0);
	for i := 0 to 15 do low_put($A0000 + i * 4096, zero, 4096);
end;

procedure	vga_start;
var	i	: longint;
begin
	read_font;
	set_mode($13);
	port[$3C4] := $00;		{ sequencer held while the clock changes }
	port[$3C5] := $01;
	port[$3C2] := TWEAK_MISC;
	port[$3C4] := $00;
	port[$3C5] := $03;
	port[$3D4] := $11;		{ CRTC 0-7 writable }
	port[$3D5] := port[$3D5] and $7F;
	for i := 0 to 17 do
	begin
		port[$3D4] := TWEAK_CRTC[i, 0];
		port[$3D5] := TWEAK_CRTC[i, 1];
	end;
	vga_clear;
	if not hooked then on_exit({$ifdef FPC}@{$endif}vga_exit);
	hooked := TRUE;
	active := TRUE;
end;

procedure	vga_end;
begin
	if not active then exit;
	active := FALSE;
	set_mode($03);
end;

procedure	vga_retrace;
begin
	while port[$3DA] and 8 <> 0 do;
	while port[$3DA] and 8 = 0 do;
end;

procedure	vga_colour(i, r, g, b: longint);
begin
	port[$3C8] := i;
	port[$3C9] := r shr 2;
	port[$3C9] := g shr 2;
	port[$3C9] := b shr 2;
end;

procedure	vga_flip(buf: pointer);
begin
	if active then low_put($A0000, buf^, VGA_SIZE);
end;

procedure	vga_text(buf: PSCREEN; x, y: longint; const s: string; c: longint);
var	i, k, row, bits, px	: longint;
begin
	for i := 1 to length(s) do
	begin
		k := ord(s[i]) and 127;
		for row := 0 to 7 do
		begin
			if (y + row < 0) or (y + row >= VGA_H) then continue;
			bits := font[k, row];
			for px := 0 to 7 do
				if (bits shl px) and $80 <> 0 then
					if (x + px >= 0) and (x + px < VGA_W) then buf^[y + row, x + px] := c;
		end;
		inc(x, 8);
	end;
end;

procedure	vga_bar(buf: PSCREEN; x, y, w, h, c: longint);
var	j	: longint;
begin
	if x < 0 then
	begin
		inc(w, x);
		x := 0;
	end;
	if x + w > VGA_W then w := VGA_W - x;
	if w <= 0 then exit;
	for j := y to y + h - 1 do
		if (j >= 0) and (j < VGA_H) then fillchar(buf^[j, x], w, c);
end;

begin
	active := FALSE;
	hooked := FALSE;
end.
