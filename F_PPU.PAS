{*+
	F_PPU.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The 2C02 PPU, a line at a time: each visible line drawn at its
	start from the CPU's state, again from a change in its middle
	(ppu_split).  Loopy's scroll registers, 8 sprites a line, flags
	to the dot (VBlank and its read races, NMI, sprite 0 hit, the
	overflow and its bug, the short odd frame), A12's rises for the
	board.  The background's lines kept by nametable row and fine y
	(after NESticle), drawn again only when what made them changed.
-*}
{$X+}
{$S-}		{ no stack check at every call }
unit	f_ppu;

interface

uses
	f_sys;

const
	PPU_W		= 256;
	PPU_H		= 240;
	PPU_NEVER	= $7FFFFFFF;

type
	PPU_PICTURE	= array[0 .. PPU_H - 1, 0 .. PPU_W - 1] of byte;
	PPPU_PICTURE	= ^PPU_PICTURE;

var	ppu_screen		: PPPU_PICTURE;	{ the picture (made by ppu_start) }
	ppu_nmi_cycle	: longint;	{ the CPU cycle an NMI was seen on, or PPU_NEVER }
	ppu_frames		: longint;	{ frames ended since power }
	ppu_mask		: U16;		{ $2001 }
	oam				: array[0 .. 255] of byte;
	{ the TV system (F_CART's TV_NTSC, TV_PAL, TV_DENDY), set before
	  ppu_power: PAL 3.2 dots a CPU cycle, 312 lines, no short odd frame;
	  Dendy 3 dots, 312 lines, VBlank at line 291 }
	ppu_region		: longint;

procedure	ppu_start;				{ the pixel tables made (else by ppu_power) }
procedure	ppu_power;
procedure	ppu_reset(at: longint);			{ the reset button: $2000, $2001, w, the buffer }
function	ppu_emphasis: longint;			{ $2001's bits 5-7, as NTSC orders them }
procedure	ppu_run(at: longint);			{ up to CPU cycle at }
function	ppu_line_now: longint;			{ the line ppu_run left it on (0-239 the picture) }
function	ppu_next: longint;			{ the CPU cycle of what happens next }
function	ppu_frame_end: longint;			{ the CPU cycle the frame ends by }
function	ppu_read(reg: U16; at: longint): U16;	{ reg 0..7 }
procedure	ppu_write(reg, v: U16; at: longint);
function	ppu_peek(reg: longint): longint;	{ no side effects }
procedure	ppu_rebase(k: longint);			{ k CPU cycles taken off every time }

{ a change at CPU cycle at that the line being drawn shows from its point
  on: what the fetches see (SPLIT_FETCH, two tiles on) or the output
  (SPLIT_NOW) }
const
	SPLIT_FETCH	= 0;
	SPLIT_NOW	= 1;

procedure	ppu_split(at, kind: longint);

implementation

uses
	f_cart, f_map;

type
	EV_LIST		= array[0 .. 8] of longint;
	SPR_LIST	= array[0 .. 63] of byte;	{ sprites' numbers }
	SLOTS		= array[0 .. 7] of PBYTE;
	PSLOTS		= ^SLOTS;
	PEV_LIST	= ^EV_LIST;

const
	PPU_ALIGN	= -1;	{ dot = 3 * cycle + PPU_ALIGN }
	SPLIT_JUMP	= 2;	{ ppu_split's: $2006 moved v (fetched from it) }
	HIT_DELAY	= 2;	{ sprite 0 hit: dots after its pixel's line start }
	LINE_DOTS	= 341;
	VBL_LINE	= 241;

	{ what happens on a line, by dot }
	A_RENDER	= 0;
	A_YINC		= 1;
	A_HCOPY		= 2;
	A_VBL		= 3;
	A_CLEAR		= 4;
	A_VCOPY		= 5;
	A_SKIP		= 6;
	A_END		= 7;
	A_SPR		= 8;	{ the sprite fetches: A12 to the sprite table }
	A_BG		= 9;	{ background fetches: A12 to its table }

	EV_VIS_DOT	: array[0 .. 6] of longint = (0, 5, 256, 257, 261, 325, LINE_DOTS);
	EV_VIS_ACT	: array[0 .. 6] of longint = (A_RENDER, A_BG, A_YINC, A_HCOPY, A_SPR, A_BG, A_END);
	EV_VBL_DOT	: array[0 .. 1] of longint = (1, LINE_DOTS);
	EV_VBL_ACT	: array[0 .. 1] of longint = (A_VBL, A_END);
	EV_PRE_DOT	: array[0 .. 8] of longint = (1, 5, 256, 257, 261, 280, 325, 338, LINE_DOTS);
	EV_PRE_ACT	: array[0 .. 8] of longint = (A_CLEAR, A_BG, A_YINC, A_HCOPY, A_SPR, A_VCOPY, A_BG, A_SKIP, A_END);
	EV_NONE_DOT	: array[0 .. 0] of longint = (LINE_DOTS);
	EV_NONE_ACT	: array[0 .. 0] of longint = (A_END);

	{ nametables by mirroring: which 1 KB each of the four is }
	NT_MAP	: array[0 .. 4, 0 .. 3] of byte = (
		(0, 0, 1, 1),		{ horizontal }
		(0, 1, 0, 1),		{ vertical }
		(0, 1, 2, 3),		{ four screens }
		(0, 0, 0, 0),		{ one screen A }
		(1, 1, 1, 1));		{ one screen B }

	{ blargg's NES at power-up (power_up_palette); any would do }
	POWER_PAL	: array[0 .. 31] of byte = (
		$09, $01, $00, $01, $00, $02, $02, $0D, $08, $10, $08, $24, $00, $00, $04, $2C,
		$09, $01, $34, $03, $00, $04, $00, $14, $08, $3A, $00, $02, $00, $20, $2C, $08);

var
	vram		: array[0 .. 4095] of byte;	{ 4 KB of nametables }
	pal			: array[0 .. 31] of byte;
	frame_start	: longint;	{ the dot the frame began at }
	line,
	line_start	: longint;
	line_len	: longint;
	ev			: longint;	{ the next event on this line }
	next_dot	: longint;
	odd_frame	: boolean;
	vbl_at		: longint;	{ the dot VBlank was set, or PPU_NEVER while clear }
	vbl_dot		: longint;	{ this frame's VBlank dot, for the read races }
	no_vbl		: boolean;	{ a read just before kept it from being set }
	hit_at		: longint;
	over_at		: longint;
	ctrl		: U16;
	oam_addr	: U16;
	latch		: U16;
	vaddr, taddr: U16;		{ loopy v and t }
	fine_x		: U16;
	w			: boolean;
	buffer		: U16;		{ $2007's read buffer }
	a12			: boolean;	{ the address line A12 as the board sees it }
	{ the sprites the line before found for this line, and for the next }
	cur_n,
	next_n		: longint;
	cur_spr		: SPR_LIST;
	next_spr	: SPR_LIST;
	cur_zero	: boolean;
	next_zero	: boolean;
	{ two pattern bytes to eight pixels: SPREAD[b][i] is bit 7-i of b,
	  SPREAD_HI the same times 2; FLIP[b] is b backwards }
	SPREAD		: array[0 .. 255, 0 .. 7] of byte;
	SPREAD_HI	: array[0 .. 255, 0 .. 7] of byte;
	FLIP		: array[0 .. 255] of byte;
	{ a line being drawn: the background from bg_line[8] (a pixel with
	  bits 0-1 clear is see-through), the sprites' pixels (0 none, else
	  the palette entry $10-$1F, $40 behind the background, $80 sprite
	  0's); the four 1 KB nametables as mirrored; the colours by pixel }
	bg_line		: array[0 .. PPU_W + 15] of byte;
	sp_line		: array[0 .. PPU_W + 15] of byte;
	nt_page		: array[0 .. 3] of PBYTE;
	bg_colour	: array[0 .. 15] of byte;
	sp_colour	: array[0 .. 31] of byte;
	bg_row		: array[0 .. 1] of PBYTE;	{ the line's nametable row, then the next table's }
	bg_attr		: array[0 .. 1] of PBYTE;	{ their attribute rows }
	bg_x		: U16;				{ the column the line starts at }
	attr_y		: U16;			{ 0 or 4: the attribute's shift by the row }
	row_now		: PBYTE;
	attr_now	: PBYTE;
	colours_grey: longint;			{ the mask bg_colour was made with, -1 none }
	{ the first 8 sprites of each line (and how many were looked at) as
	  OAM has them, made again when it or the sprites' height changes }
	line_spr	: array[0 .. PPU_H - 1, 0 .. 7] of byte;
	line_n		: array[0 .. PPU_H - 1] of byte;
	line_scan	: array[0 .. PPU_H - 1] of byte;
	lines_h		: longint;			{ the height they were made for, 0 none }
	sp_from,
	sp_to		: longint;		{ the span the sprites drew in }
	drawn_line	: longint;		{ the line render_line drew last, -1 none }
	redrawing	: boolean;		{ render_line drawing a line again: no side effects }
	redraw_out	: array[0 .. PPU_W - 1] of byte;

	{ the background's lines kept: by nametable (of the 4 KB), row, fine
	  y; what each was made from; the colours made from its pixels with }
const
	NT_LINES	= 4 * 30 * 8;
	
type
	LINE_KEY	= record
		gen, half, row	: longint;
		slot, slot_gen	: array[0 .. 3] of longint;
	end;
	NT_KEYS		= array[0 .. NT_LINES - 1] of LINE_KEY;
	NT_COLOUR_KEYS	= array[0 .. NT_LINES - 1] of longint;
	{ a nametable's kept lines: their pixels and their colours }
	NT_STORE	= record
		nc_pix	: PPPU_PICTURE;
		nc_col	: PPPU_PICTURE;
	end;

{ in blocks of 240 lines: no compiler's block holds them all in 16 bits }
var
	nt_cache	: array[0 .. 3] of NT_STORE;
	nt_key		: ^NT_KEYS;
	nt_colours	: ^NT_COLOUR_KEYS;	{ on the heap: BP7's data segment is short }
	row_gen		: array[0 .. 3, 0 .. 29] of longint;	{ by nametable row: its writes }
	bg_slot		: array[0 .. 7] of PBYTE;	{ the background's CHR slots for the line }
	bg_page		: array[0 .. 7] of longint;	{ and their pages }
	chr_gen		: array[0 .. 255] of longint;		{ by KB of CHR RAM: its writes }
	cache_gen	: longint;	{ every line made before a change of it is stale }
	line_vbl	: longint;	{ the region's: VBlank's line, the pre-render line, all }
	line_pre	: longint;
	frame_lines	: longint;
	pal_gen		: longint;	{ the background's palette written }

{ ---- the region's clock: PPU dots and CPU cycles ---- }

{ the dot CPU cycle c reads and writes at: 3c (PAL 16c/5) + PPU_ALIGN }
function	dot_of(c: longint): longint;
begin
	if ppu_region = TV_PAL then dot_of := c * 16 div 5 + PPU_ALIGN
	else	dot_of := c + c + c + PPU_ALIGN;	{ adds: BP7 multiplies a longint by a call }
end;

{ the first CPU cycle at least x dots on (x = a dot less PPU_ALIGN) }
function	cyc_ceil(x: longint): longint;
begin
	if ppu_region = TV_PAL then cyc_ceil := (x * 5 + 15) div 16
	else	cyc_ceil := (x + 2) div 3;
end;

function	ppu_emphasis: longint;
var	e	: longint;
begin
	e := (ppu_mask shr 5) and 7;
	{ PAL's and Dendy's red and green the other way round }
	if ppu_region <> TV_NTSC then e := (e and 4) or (e and 1) shl 1 or (e and 2) shr 1;
	ppu_emphasis := e;
end;

{ ---- memory ---- }

{ the 1 KB of vram nametable k is }
function	nt_of(k: U16): U16;
begin
	nt_of := NT_MAP[mirroring][k];
end;

function	nt_offset(addr: U16): U16;
begin
	nt_offset := nt_of((addr shr 10) and 3) shl 10 + (addr and $3FF);
end;

function	pal_index(addr: U16): U16;
var	i	: U16;
begin
	i := addr and $1F;
	if i and $13 = $10 then i := i and $0F;
	pal_index := i;
end;

function	mem(addr: U16): U16;
begin
	addr := addr and $3FFF;
	if addr < $2000 then
	begin
		mem := PBYTES(chr_slot[addr shr 10])^[addr and $3FF];
	end
	else if addr < $3F00 then mem := vram[nt_offset(addr)]
	else	mem := pal[pal_index(addr)];
end;

{ a write; a change marks what the kept lines were made from }
procedure	mem_write(addr, v: U16);
var	p, o, i	: U16;
	b	: PBYTE;
begin
	addr := addr and $3FFF;
	if addr < $2000 then
	begin
		if not chr_rw[addr shr 10] then exit;
		i := chr_page[addr shr 10] and 255;
		b := chr_slot[addr shr 10];
		if PBYTES(b)^[addr and $3FF] = v then exit;
		PBYTES(b)^[addr and $3FF] := v;
		inc(chr_gen[i]);
	end
	else if addr < $3F00 then
	begin
		o := nt_offset(addr);
		if vram[o] = v then exit;
		vram[o] := v;
		p := o shr 10;
		o := o and $3FF;
		if o < 960 then inc(row_gen[p, o shr 5])
		else
			for i := ((o - 960) shr 3) * 4 to ((o - 960) shr 3) * 4 + 3 do
				if i < 30 then inc(row_gen[p, i]);
	end
	else
	begin
		{ a colour written again as it was (games rewrite the whole
		  palette every frame): the kept lines' colours still good }
		i := pal_index(addr);
		if pal[i] = v and $3F then exit;
		pal[i] := v and $3F;
		colours_grey := -1;
		if i < 16 then inc(pal_gen);
	end;
end;

{ A12 to high (a rise for the board) or low, at dot d }
procedure	set_a12(high: boolean; d: longint);
begin
	if high and not a12 and a12_board then board^.A12Rise(cyc_ceil(d - 1 - PPU_ALIGN));
	a12 := high;
end;

function	rendering: boolean;
begin
	rendering := ppu_mask and $18 <> 0;
end;

{ the PPU's own fetches on the bus (A12 theirs, not v's) }
function	fetching: boolean;
begin
	fetching := rendering and ((line < PPU_H) or (line = line_pre));
end;

{ ---- the scroll registers' steps while rendering ---- }

procedure	y_increment;
var	y	: U16;
begin
	if vaddr and $7000 <> $7000 then inc(vaddr, $1000)
	else
	begin
		vaddr := vaddr and $0FFF;
		y := (vaddr shr 5) and 31;
		if y = 29 then
		begin
			y := 0;
			vaddr := vaddr xor $0800;
		end
		else if y = 31 then y := 0
		else	inc(y);
		vaddr := (vaddr and not $03E0) or y shl 5;
	end;
end;

{ ---- sprites ---- }

{ OAM's sprites on line l, for the next: the first 8, then the overflow
  search with the PPU's bug (after 8 it steps the byte as well as the
  sprite); dots from 65, two a sprite looked at, eight one taken }
{ line_spr and the rest from OAM: each sprite into the lines it covers,
  in its order, 8 a line }
procedure	make_lines(h: U16);
var	n, r, l, c	: U16;
begin
	fillchar(line_n, sizeof(line_n), 0);
	fillchar(line_scan, sizeof(line_scan), 64);
	for n := 0 to 63 do
		for r := 0 to h - 1 do
		begin
			l := oam[n * 4] + r;
			if l >= PPU_H then break;
			c := line_n[l];
			if c < 8 then
			begin
				line_spr[l][c] := n;
				line_n[l] := c + 1;
				if c = 7 then line_scan[l] := n + 1;
			end;
		end;
	lines_h := h;
end;

procedure	evaluate(l: longint);
var	n, m, h	: U16;
	d, y	: longint;
begin
	if ctrl and $20 <> 0 then h := 16 else h := 8;
	if lines_h <> h then make_lines(h);
	next_n := line_n[l];
	if next_n > 0 then move(line_spr[l], next_spr, next_n);
	n := line_scan[l];
	next_zero := (next_n > 0) and (next_spr[0] = 0);
	{ two dots a sprite looked at, eight one taken }
	d := 65 + n * 2 + next_n * 6;
	if next_n < 8 then exit;
	m := 0;
	while n < 64 do
	begin
		y := l - oam[n * 4 + m];
		if (y >= 0) and (y < h) then
		begin
			if over_at = PPU_NEVER then over_at := line_start + d;
			exit;
		end;
		inc(n);
		m := (m + 1) and 3;
		inc(d, 2);
	end;
end;


{ a tile's eight pixels into dest from x on: the low pattern byte's bit
  0, the high one's bit 1 (by table, SPREAD and SPREAD_HI), the
  attribute's bits 2-3 (where both pattern bits are clear the pixel shows
  nothing all the same); base is the pattern table plus fine y.  The
  eight written out, not looped: no counter to step and test }
procedure	tile_pixels(dest: PBYTES; x, tile, attr, base: U16; slots: PSLOTS);
var	a, lo, hi, ab	: U16;
	p		: PBYTES;
begin
	a := tile shl 4 + base;
	p := PBYTES(slots^[a shr 10]);
	a := a and $3FF;
	lo := p^[a];
	hi := p^[a + 8];
	ab := attr shl 2;
	dest^[x] := SPREAD[lo, 0] or SPREAD_HI[hi, 0] or ab;
	dest^[x + 1] := SPREAD[lo, 1] or SPREAD_HI[hi, 1] or ab;
	dest^[x + 2] := SPREAD[lo, 2] or SPREAD_HI[hi, 2] or ab;
	dest^[x + 3] := SPREAD[lo, 3] or SPREAD_HI[hi, 3] or ab;
	dest^[x + 4] := SPREAD[lo, 4] or SPREAD_HI[hi, 4] or ab;
	dest^[x + 5] := SPREAD[lo, 5] or SPREAD_HI[hi, 5] or ab;
	dest^[x + 6] := SPREAD[lo, 6] or SPREAD_HI[hi, 6] or ab;
	dest^[x + 7] := SPREAD[lo, 7] or SPREAD_HI[hi, 7] or ab;
end;

{ tile col's attribute in the row attr_now, attr_y points to: 0-3 }
function	tile_attr(col: U16): U16;
begin
	tile_attr := (PBYTES(attr_now)^[col shr 2] shr ((col and 2) + attr_y)) and 3;
end;

{ the 33 tiles of a line into bg_line, fine x off the first; base is
  the pattern table plus fine y.  The nametable's row and attribute row
  (bg_row, bg_attr, the second pair for the nametable the line runs into)
  and the column to start at (bg_x) made by render_line }
procedure	bg_tiles(base: U16);
var	col, t, x	: U16;
begin
	col := bg_x;
	row_now := bg_row[0];
	attr_now := bg_attr[0];
	x := 8 - fine_x;
	for t := 1 to 33 do
	begin
		tile_pixels(@bg_line, x, PBYTES(row_now)^[col], tile_attr(col), base, @bg_slot);
		inc(x, 8);
		{ the next column, into the next nametable at the edge }
		inc(col);
		if col = 32 then
		begin
			col := 0;
			row_now := bg_row[1];
			attr_now := bg_attr[1];
		end;
	end;
end;

{ a sprite's row: its eight pixels (lo, hi already flipped when it is,
  spread by table) into sp_line from x where nothing is yet, from the
  pixel first on; value, the palette and the flags, ored in }
procedure	sprite_row(x, lo, hi, value: U16; first: longint);
var	i, px	: U16;
begin
	for i := 0 to 7 do
	begin
		px := SPREAD_HI[hi, i] or SPREAD[lo, i];
		if (px <> 0) and (i >= first) and (sp_line[x + i] = 0) then sp_line[x + i] := (px or value) and $FF;
	end;
end;

{ the line's colours into out: the background's (unless kept: out has
  them already); then, from x0 to x1, a sprite's pixel where there is
  one, in front or over a see-through background }
procedure	compose(out: PBYTE; x0, x1: longint; kept: boolean);
var	x, s	: longint;
begin
	if not kept then
		for x := 0 to PPU_W - 1 do PBYTES(out)^[x] := bg_colour[bg_line[8 + x]];
	for x := x0 to x1 - 1 do
	begin
		s := sp_line[x];
		if s = 0 then continue;
		{ behind the background: shown only where it shows nothing }
		if (s and $40 <> 0) and (bg_line[8 + x] and 3 <> 0) then continue;
		PBYTES(out)^[x] := sp_colour[s and $1F];
	end;
end;

{ a nametable row's 32 tiles from row_now, attr_now, attr_y into dest,
  as bg_tiles does: base the pattern table plus fine y }
procedure	nt_tiles(base: U16; dest: PBYTES);
var	col	: U16;
begin
	for col := 0 to 31 do
		tile_pixels(dest, col * 8, PBYTES(row_now)^[col], tile_attr(col), base, @bg_slot);
end;

{ 256 pixels' colours: out[i] := bg_colour[pix[i]] }
procedure	nt_colour(pix, out: PBYTE);
var	i	: U16;
begin
	for i := 0 to PPU_W - 1 do PBYTES(out)^[i] := bg_colour[PBYTES(pix)^[i]];
end;

{ kept line e's pixels and colours }
function	pix_line(e: U16): PBYTE;
begin
	pix_line := @nt_cache[e div PPU_H].nc_pix^[e mod PPU_H, 0];
end;

function	col_line(e: U16): PBYTE;
begin
	col_line := @nt_cache[e div PPU_H].nc_col^[e mod PPU_H, 0];
end;

{ the kept line of nametable p, row r, fine y fy (pattern table half),
  made again if stale, coloured as the palette is now }
function	nt_line(p, r, fy, hf: U16): U16;
var	e, k	: U16;
	g, sl	: longint;
	fresh		: boolean;
	key		: ^LINE_KEY;
begin
	e := (p * 30 + r) * 8 + fy;
	key := @nt_key^[e];
	fresh := (key^.gen = cache_gen) and (key^.half = hf) and (key^.row = row_gen[p, r]);
	for k := 0 to 3 do
	begin
		sl := bg_page[hf * 4 + k];
		g := chr_gen[sl and 255];
		if (key^.slot[k] <> sl) or (key^.slot_gen[k] <> g) then
		begin
			fresh := FALSE;
			key^.slot[k] := sl;
			key^.slot_gen[k] := g;
		end;
	end;
	if not fresh then
	begin
		row_now := @vram[p shl 10 + r * 32];
		attr_now := @vram[p shl 10 + $3C0 + (r shr 2) * 8];
		attr_y := (r and 2) * 2;
		nt_tiles(hf shl 12 + fy, PBYTES(pix_line(e)));
		key^.gen := cache_gen;
		key^.half := hf;
		key^.row := row_gen[p, r];
		nt_colours^[e] := -1;
	end;
	if nt_colours^[e] <> pal_gen shl 8 + colours_grey then
	begin
		nt_colour(pix_line(e), col_line(e));
		nt_colours^[e] := pal_gen shl 8 + colours_grey;
	end;
	nt_line := e;
end;

procedure	render_line;
var	k, a, lo, hi, attr, tile, row, h, at, c, value	: U16;
	ea, eb, grey	: U16;
	x, n, first	: longint;	{ loops that may end at -1: longint }
	show_bg, show_sp, kept	: boolean;
	out		: PBYTE;
begin
	out := @ppu_screen^[line, 0];
	if redrawing then out := @redraw_out;
	if ppu_mask and 1 <> 0 then grey := $30 else grey := $3F;
	if not rendering then
	begin
		c := pal[0];
		if vaddr and $3F00 = $3F00 then c := pal[pal_index(vaddr)];
		fillchar(out^, PPU_W, c and grey);
		if redrawing then exit;
		cur_n := 0;
		next_n := 0;
		exit;
	end;
	show_bg := ppu_mask and $08 <> 0;
	kept := FALSE;
	show_sp := ppu_mask and $10 <> 0;
	move(chr_slot, bg_slot, sizeof(bg_slot));
	move(chr_page, bg_page, sizeof(bg_page));
	if grey <> colours_grey then
	begin
		for k := 0 to 15 do
			if k and 3 = 0 then bg_colour[k] := pal[0] and grey
			else	bg_colour[k] := pal[k] and grey;
		for k := 16 to 31 do sp_colour[k] := pal[k] and grey;
		colours_grey := grey;
	end;

	{ the sprites found on the line before, fetched in their order; the
	  lowest number in front (sp_line is clear but for the span drawn
	  in, cleared after) }
	sp_from := PPU_W;
	sp_to := 0;
	if show_sp then
	begin
		if ctrl and $20 <> 0 then h := 16 else h := 8;
		for n := 0 to cur_n - 1 do
		begin
			at := cur_spr[n] * 4;
			row := line - 1 - oam[at];
			attr := oam[at + 2];
			if attr and $80 <> 0 then row := h - 1 - row;
			tile := oam[at + 1];
			if h = 16 then
			begin
				a := (tile and 1) shl 12 + (tile and $FE) shl 4;
				if row >= 8 then inc(a, 16 + row - 8) else inc(a, row);
			end
			else	a := (ctrl and $08) shl 9 + tile shl 4 + row;
			lo := PBYTES(chr_slot[a shr 10])^[a and $3FF];
			a := a + 8;
			hi := PBYTES(chr_slot[a shr 10])^[a and $3FF];
			x := oam[at + 3];
			if attr and $40 <> 0 then
			begin
				lo := FLIP[lo];
				hi := FLIP[hi];
			end;
			value := $10 or (attr and 3) shl 2 or (attr and $20) shl 1;
			if cur_spr[n] = 0 then value := value or $80;
			first := 0;
			if ppu_mask and $04 = 0 then first := 8 - x;
			sprite_row(x, lo, hi, value, first);
			if x < sp_from then sp_from := x;
			if x + 8 > sp_to then sp_to := x + 8;
		end;
	end;

	{ the background: 33 tiles from v, fine x off the first - two kept
	  lines when the row is a real one; their colours straight to out }
	row := (vaddr shr 5) and 31;
	if show_bg and (row < 30) then
	begin
		k := (vaddr shr 10) and 3;
		ea := nt_line(nt_of(k), row, (vaddr shr 12) and 7, (ctrl shr 4) and 1);
		x := (vaddr and 31) * 8;
		move(PBYTES(pix_line(ea))^[x], bg_line[8 - fine_x], PPU_W - x);
		{ the next table's line, unless the picture starts on a tile's
		  edge at its left: then none of it shows }
		if x + fine_x > 0 then
		begin
			eb := nt_line(nt_of(k xor 1), row, (vaddr shr 12) and 7, (ctrl shr 4) and 1);
			move(pix_line(eb)^, bg_line[8 - fine_x + PPU_W - x], 8 + x);
		end;
		x := x + fine_x;
		move(PBYTES(col_line(ea))^[x], out^, PPU_W - x);
		if x > 0 then move(col_line(eb)^, PBYTES(out)^[PPU_W - x], x);
		if ppu_mask and $02 = 0 then
		begin
			fillchar(bg_line[8], 8, 0);
			fillchar(out^, 8, bg_colour[0]);
		end;
		kept := TRUE;
	end
	else if show_bg then
	begin
		for k := 0 to 3 do nt_page[k] := @vram[nt_of(k) shl 10];
		row := (vaddr shr 5) and 31;
		k := (vaddr shr 10) and 3;
		bg_row[0] := padd(nt_page[k], row * 32);
		bg_attr[0] := padd(nt_page[k], $3C0 + (row shr 2) * 8);
		bg_row[1] := padd(nt_page[k xor 1], row * 32);
		bg_attr[1] := padd(nt_page[k xor 1], $3C0 + (row shr 2) * 8);
		attr_y := (row and 2) * 2;
		bg_x := vaddr and 31;
		bg_tiles((ctrl and $10) shl 8 + (vaddr shr 12) and 7);
		if ppu_mask and $02 = 0 then fillchar(bg_line[8], 8, 0);
	end
	else	fillchar(bg_line[8], PPU_W, 0);

	{ sprite 0 hit: its pixel over the background's, not at 255 }
	if sp_to > PPU_W then n := PPU_W else n := sp_to;
	if n > 255 then n := 255;
	if show_sp and cur_zero and show_bg and (hit_at = PPU_NEVER) and not redrawing then
		for x := sp_from to n - 1 do
			if (sp_line[x] and $80 <> 0) and (bg_line[x + 8] and 3 <> 0) then
			begin
				hit_at := line_start + x + HIT_DELAY;
				break;
			end;

	if sp_to > PPU_W then n := PPU_W else n := sp_to;
	compose(out, sp_from, n, kept);
	if sp_to > sp_from then fillchar(sp_line[sp_from], sp_to - sp_from, 0);
end;

procedure	act(a: longint);
begin
	case a of
	A_RENDER:
		begin
			{ what the line before found is this one's (kept for a
			  redraw: ppu_split) }
			cur_n := next_n;
			cur_spr := next_spr;
			cur_zero := next_zero;
			render_line;
			drawn_line := line;
			if rendering then evaluate(line)
			else	next_n := 0;
		end;
	A_YINC:	if rendering then y_increment;
	A_HCOPY:if rendering then vaddr := (vaddr and not $041F) or (taddr and $041F);
	A_VCOPY:if rendering then vaddr := (vaddr and not $7BE0) or (taddr and $7BE0);
	A_VBL:	begin
			if not no_vbl then
			begin
				vbl_at := next_dot;
				if ctrl and $80 <> 0 then
					ppu_nmi_cycle := cyc_ceil(next_dot - 1 - PPU_ALIGN);
			end;
			no_vbl := FALSE;
		end;
	A_CLEAR:begin
			next_n := 0;		{ no sprites on line 0 }
			next_zero := FALSE;
			vbl_at := PPU_NEVER;
			hit_at := PPU_NEVER;
			over_at := PPU_NEVER;
		end;
	A_SKIP:	if odd_frame and rendering and (ppu_region = TV_NTSC) then line_len := LINE_DOTS - 1;
	A_SPR:	if rendering then set_a12((ctrl and $28) <> 0, next_dot);
	A_BG:	if rendering then set_a12((ctrl and $10) <> 0, next_dot);
	end;
end;

{ the events of this line: their dots and what they are }
procedure	line_events(var dots, acts: PEV_LIST);
begin
	if line < PPU_H then
	begin
		dots := @EV_VIS_DOT;
		acts := @EV_VIS_ACT;
	end
	else if line = line_vbl then
	begin
		dots := @EV_VBL_DOT;
		acts := @EV_VBL_ACT;
	end
	else if line = line_pre then
	begin
		dots := @EV_PRE_DOT;
		acts := @EV_PRE_ACT;
	end
	else
	begin
		dots := @EV_NONE_DOT;
		acts := @EV_NONE_ACT;
	end;
end;

{ the dot of the line's event ev }
function	event_dot: longint;
var	dots, acts	: PEV_LIST;
	d		: longint;
begin
	line_events(dots, acts);
	d := dots^[ev];
	if d = LINE_DOTS then d := line_len;
	event_dot := line_start + d;
end;

function	ppu_line_now: longint;
begin
	ppu_line_now := line;
end;

procedure	ppu_run(at: longint);
var	target, a, d	: longint;
	dots, acts	: PEV_LIST;
begin
	target := dot_of(at);
	if next_dot > target then exit;
	line_events(dots, acts);
	repeat
		if (ev = 0) and (line < PPU_H) and not a12_board and (line_start + LINE_DOTS <= target) then
		begin
			{ a visible line wholly past, no board watching A12: its
			  events at once - drawn, v's steps, A12 left as its last
			  fetch left it, the next line }
			act(A_RENDER);
			if rendering then
			begin
				y_increment;
				vaddr := (vaddr and not $041F) or (taddr and $041F);
				a12 := ctrl and $10 <> 0;
			end;
			inc(line_start, line_len);
			line_len := LINE_DOTS;
			inc(line);
			line_events(dots, acts);
		end
		else
		begin
			a := acts^[ev];
			if a = A_END then
			begin
				inc(line_start, line_len);
				line_len := LINE_DOTS;
				inc(line);
				if line > line_pre then
				begin
					line := 0;
					frame_start := line_start;
					odd_frame := not odd_frame;
					inc(ppu_frames);
					vbl_dot := frame_start + line_vbl * LINE_DOTS + 1;
				end;
				ev := 0;
				line_events(dots, acts);
			end
			else
			begin
				act(a);
				inc(ev);
			end;
		end;
		d := dots^[ev];
		if d = LINE_DOTS then d := line_len;
		next_dot := line_start + d;
	until next_dot > target;
end;

{ the CPU cycle of the next event the CPU must not run past: VBlank (its
  NMI), the frame's end and, for a board that counts A12's rises, the
  pattern fetches.  The rest wait for the CPU's next access to the PPU or
  to the board (bus_write catches the PPU up first): a line is drawn
  then from the state it began with all the same }
function	ppu_next: longint;
var	l, e, base, d, a	: longint;
begin
	if not a12_board and ((line < line_vbl) or ((line = line_vbl) and (ev = 0))) then
		d := vbl_dot
	else
	begin
		l := line;
		e := ev;
		base := line_start;
		repeat
			if l < PPU_H then
			begin
				d := EV_VIS_DOT[e];
				a := EV_VIS_ACT[e];
			end
			else if l = line_vbl then
			begin
				d := EV_VBL_DOT[e];
				a := EV_VBL_ACT[e];
			end
			else if l = line_pre then
			begin
				d := EV_PRE_DOT[e];
				a := EV_PRE_ACT[e];
			end
			else
			begin
				d := LINE_DOTS;
				a := A_END;
			end;
			if a = A_END then
			begin
				if l = line_pre then
				begin
					if l = line then d := base + line_len else d := base + LINE_DOTS;
					break;
				end;
				inc(base, LINE_DOTS);
				inc(l);
				e := 0;
			end
			else if (a = A_VBL) or (a12_board and ((a = A_BG) or (a = A_SPR))) then
			begin
				d := base + d;
				break;
			end
			else	inc(e);
		until FALSE;
	end;
	ppu_next := cyc_ceil(d - PPU_ALIGN);
end;

function	ppu_frame_end: longint;
begin
	ppu_frame_end := cyc_ceil(frame_start + frame_lines * LINE_DOTS - PPU_ALIGN);
end;

{ ---- a change in a line's middle ---- }

{ the line being drawn again, as things are now, from pixel x0 on; for a
  jump of v ($2006), its tiles from x0 from the new v }
procedure	ppu_split(at, kind: longint);
var	d, x0, t0, v0, c	: longint;
begin
	if (line >= PPU_H) or (drawn_line <> line) or not rendering then exit;
	d := dot_of(at) - line_start;
	if (d < 1) or (d >= PPU_W) then exit;
	if kind = SPLIT_NOW then
	begin
		x0 := d;
		t0 := 0;
	end
	else
	begin
		{ a tile's patterns are fetched two tiles before it shows }
		t0 := (d + 3) div 8 + 2;
		x0 := t0 * 8 - fine_x;
		if x0 >= PPU_W then exit;
		if x0 < 0 then x0 := 0;
	end;
	v0 := vaddr;
	if kind = SPLIT_JUMP then
	begin
		{ v's tile at x0: the line drawn as if it started t0 tiles before }
		c := (vaddr and 31) - t0;
		vaddr := vaddr and not 31;
		while c < 0 do
		begin
			inc(c, 32);
			vaddr := vaddr xor $0400;
		end;
		vaddr := vaddr or c;
	end;
	redrawing := TRUE;
	render_line;
	redrawing := FALSE;
	vaddr := v0;
	move(redraw_out[x0], ppu_screen^[line, x0], PPU_W - x0);
end;

{ ---- registers ---- }

function	ppu_read(reg: U16; at: longint): U16;
var	d	: longint;
	r	: U16;
begin
	ppu_run(at);
	case reg of
	2:	begin
			d := dot_of(at);
			r := latch and $1F;
			if (hit_at <> PPU_NEVER) and (d >= hit_at) then r := r or $40;
			if (over_at <> PPU_NEVER) and (d >= over_at) then r := r or $20;
			if d = vbl_dot - 1 then no_vbl := TRUE		{ just before: never set }
			else if vbl_at <> PPU_NEVER then
			begin
				r := r or $80;
				if d - vbl_at <= 1 then ppu_nmi_cycle := PPU_NEVER;
			end;
			vbl_at := PPU_NEVER;
			w := FALSE;
			latch := r;
		end;
	4:	latch := oam[oam_addr];
	7:	begin
			if not fetching then set_a12(vaddr and $1000 <> 0, dot_of(at));
			r := vaddr and $3FFF;
			if r >= $3F00 then
			begin
				d := mem(r);
				if ppu_mask and 1 <> 0 then d := d and $30;
				latch := d or (latch and $C0);
				buffer := mem(r - $1000);
			end
			else
			begin
				latch := buffer;
				buffer := mem(r);
			end;
			if ctrl and 4 <> 0 then vaddr := (vaddr + 32) and $7FFF
			else	vaddr := (vaddr + 1) and $7FFF;
			if not fetching then set_a12(vaddr and $1000 <> 0, dot_of(at));
		end;
	end;
	ppu_read := latch;
end;

procedure	ppu_write(reg, v: U16; at: longint);
var	oc	: U16;
begin
	ppu_run(at);
	latch := v;
	case reg of
	0:	begin
			oc := ctrl;
			{ the CPU samples NMI a dot after its writes land }
			if (v and $80 <> 0) and (ctrl and $80 = 0) and (vbl_at <> PPU_NEVER)
			and (dot_of(at) + 1 < frame_start + line_pre * LINE_DOTS + 1) then
				ppu_nmi_cycle := at;
			if (v and $80 = 0) and (ppu_nmi_cycle >= at) then ppu_nmi_cycle := PPU_NEVER;
			ctrl := v;
			taddr := (taddr and $F3FF) or (v and 3) shl 10;
			if (oc xor v) and $10 <> 0 then ppu_split(at, SPLIT_FETCH);
		end;
	1:	if v <> ppu_mask then
		begin
			ppu_mask := v;
			ppu_split(at, SPLIT_NOW);
		end;
	3:	oam_addr := v;
	4:	begin
			if oam_addr and 3 = 2 then v := v and $E3;
			oam[oam_addr] := v;
			lines_h := 0;
			oam_addr := (oam_addr + 1) and $FF;
		end;
	5:	begin
			if not w then
			begin
				taddr := (taddr and $7FE0) or v shr 3;
				if fine_x <> v and 7 then
				begin
					fine_x := v and 7;
					ppu_split(at, SPLIT_NOW);
				end;
			end
			else	taddr := (taddr and $0C1F) or (v and 7) shl 12 or (v and $F8) shl 2;
			w := not w;
		end;
	6:	begin
			if not w then taddr := (taddr and $00FF) or (v and $3F) shl 8
			else
			begin
				taddr := (taddr and $7F00) or v;
				vaddr := taddr;
				if not fetching then set_a12(vaddr and $1000 <> 0, dot_of(at));
				ppu_split(at, SPLIT_JUMP);
			end;
			w := not w;
		end;
	7:	begin
			if not fetching then set_a12(vaddr and $1000 <> 0, dot_of(at));
			mem_write(vaddr, v);
			if ctrl and 4 <> 0 then vaddr := (vaddr + 32) and $7FFF
			else	vaddr := (vaddr + 1) and $7FFF;
			if not fetching then set_a12(vaddr and $1000 <> 0, dot_of(at));
		end;
	end;
end;

function	ppu_peek(reg: longint): longint;
begin
	case reg of
	2:	ppu_peek := (latch and $1F) or ord(vbl_at <> PPU_NEVER) shl 7;
	4:	ppu_peek := oam[oam_addr];
	else	ppu_peek := latch;
	end;
end;

var	tables_made	: boolean;

procedure	ppu_start;
var	b, i	: longint;
begin
	if tables_made then exit;
	{ the picture and the kept lines, each block under 64 KB }
	ppu_screen := malloc(sizeof(PPU_PICTURE));
	for i := 0 to 3 do
	begin
		nt_cache[i].nc_pix := malloc(sizeof(PPU_PICTURE));
		nt_cache[i].nc_col := malloc(sizeof(PPU_PICTURE));
	end;
	nt_key := malloc(sizeof(NT_KEYS));
	nt_colours := malloc(sizeof(NT_COLOUR_KEYS));
	for b := 0 to 255 do
	begin
		FLIP[b] := 0;
		for i := 0 to 7 do
		begin
			SPREAD[b][i] := (b shr (7 - i)) and 1;
			SPREAD_HI[b][i] := SPREAD[b][i] shl 1;
			FLIP[b] := FLIP[b] or ((b shr i) and 1) shl (7 - i);
		end;
	end;
	tables_made := TRUE;
end;

procedure	ppu_reset(at: longint);
begin
	ppu_write(0, 0, at);
	ppu_write(1, 0, at);
	w := FALSE;
	buffer := 0;
end;

procedure	ppu_power;
begin
	ppu_start;
	line_vbl := VBL_LINE;
	if ppu_region = TV_DENDY then line_vbl := 291;
	if ppu_region = TV_NTSC then frame_lines := 262 else frame_lines := 312;
	line_pre := frame_lines - 1;
	fillchar(vram, sizeof(vram), 0);
	move(POWER_PAL, pal, 32);
	fillchar(oam, sizeof(oam), 0);
	fillchar(ppu_screen^, sizeof(PPU_PICTURE), 0);
	drawn_line := -1;
	redrawing := FALSE;
	frame_start := 0;
	line := 0;
	line_start := 0;
	line_len := LINE_DOTS;
	ev := 0;
	odd_frame := FALSE;
	vbl_at := PPU_NEVER;
	vbl_dot := line_vbl * LINE_DOTS + 1;
	no_vbl := FALSE;
	hit_at := PPU_NEVER;
	over_at := PPU_NEVER;
	ppu_nmi_cycle := PPU_NEVER;
	ppu_frames := 0;
	ctrl := 0;
	ppu_mask := 0;
	oam_addr := 0;
	latch := 0;
	vaddr := 0;
	taddr := 0;
	fine_x := 0;
	w := FALSE;
	buffer := 0;
	a12 := FALSE;
	cur_n := 0;
	next_n := 0;
	cur_zero := FALSE;
	next_zero := FALSE;
	fillchar(cur_spr, sizeof(cur_spr), 0);
	fillchar(sp_line, sizeof(sp_line), 0);
	colours_grey := -1;
	lines_h := 0;
	fillchar(next_spr, sizeof(next_spr), 0);
	next_dot := event_dot;
	fillchar(nt_key^, sizeof(NT_KEYS), 0);
	fillchar(row_gen, sizeof(row_gen), 0);
	fillchar(chr_gen, sizeof(chr_gen), 0);
	cache_gen := 1;
	pal_gen := 0;
end;

{ k CPU cycles off: their dots (PAL: k a multiple of 5, as F_BUS takes it) }
procedure	ppu_rebase(k: longint);
var	d	: longint;
begin
	if ppu_region = TV_PAL then d := k * 16 div 5 else d := k * 3;
	dec(frame_start, d);
	dec(line_start, d);
	dec(next_dot, d);
	dec(vbl_dot, d);
	if vbl_at <> PPU_NEVER then dec(vbl_at, d);
	if hit_at <> PPU_NEVER then dec(hit_at, d);
	if over_at <> PPU_NEVER then dec(over_at, d);
	if ppu_nmi_cycle <> PPU_NEVER then dec(ppu_nmi_cycle, k);
end;

begin
	{ TMT leaves globals as memory had them }
	tables_made := FALSE;
end.
