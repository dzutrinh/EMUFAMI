{*+
	F_TEXT.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The picture in VGA text mode: mode 3 on 480 lines (60 Hz) with
	8-dot cells four scan lines high (80 x 120 cells) and a font of its
	own, the 256 ways to fill a cell's 4 x 2 blocks (2 dots by 2 lines
	each): every NES pixel one square block, the picture 64 x 120
	cells in the middle, black on both sides.  A cell shows two
	colours (blinking off: 16 backgrounds); a third in it is drawn as
	the nearer of the two.  NES black and each frame's 15 most used
	colours are kept in 16 DAC entries (a colour keeps its entry while
	it stays), the rest drawn as the nearest of them; counted every
	8th frame.  Only what changed is done again: the NES rows
	unlike last frame's given their entries, the cells on them made;
	a cell whose blocks' entries are as before is left as it is, one
	made before (by its entries) taken from a cache.
-*}
{$S-}		{ no stack check at every call }
unit	f_text;

interface

uses	f_sys;

function	txt_start: boolean;			{ the text mode set; FALSE: no memory for it }
procedure	txt_flip(pic: pointer; emphasis: longint);	{ a 256x240 NES picture to the screen }

implementation

uses	f_dos, f_vga, f_pal;

const	COLS		= 80;
	ROWS		= 120;
	LEFT		= 8;			{ the picture's first cell column }
	PIC_COLS	= 64;			{ its cells across: 256 pixels }
	BLACK		= $0F;			{ NES black, the sides }
	PAGE_BYTES	= COLS * ROWS * 2;	{ character, attribute }
	FONT_BYTES	= 256 * 32;		{ the font block: 32 bytes a character }

type	CELL_BLOCKS	= array[0 .. 7] of byte;
	CELL_KEYS	= array[0 .. PIC_COLS * ROWS - 1] of word;
	PCELL_KEYS	= ^CELL_KEYS;
	ROW_LONGS	= array[0 .. 63] of longint;	{ a NES row, compared four at a time }
	PROW_LONGS	= ^ROW_LONGS;
	{ cells made, by their entries: the key's two words, the character
	  and attribute (a slot is free while its attribute's word is 0FFFFh) }
	MADE		= record
		lo, hi	: word;
		ch, attr: word;
	end;
	MADE_CACHE	= array[0 .. 4095] of MADE;
	PMADE_CACHE	= ^MADE_CACHE;

var	page		: PBYTES;		{ the text page, made then copied }
	{ each cell's blocks' entries as last made, four to a word (no
	  longint shifts past 16: BP7 gets them wrong) }
	key_lo, key_hi	: PCELL_KEYS;
	fresh		: boolean;		{ every cell to be made }
	last		: PBYTES;		{ the picture as last shown, 256 x 240 }
	slots		: PBYTES;		{ its pixels' entries }
	dirty		: array[0 .. 239] of boolean;	{ a NES row changed this frame }
	rows_new	: boolean;		{ last holds nothing yet }
	cache		: PMADE_CACHE;
	frames		: longint;		{ flips since the mode was set }
	emphasis_was	: longint;
	map_was		: array[0 .. 63] of byte;	{ map as the entries were made with }
	tally		: array[0 .. 15] of byte;	{ a cell's blocks by entry, kept 0 }
	count		: array[0 .. 63] of longint;	{ a frame's pixels by colour }
	map		: array[0 .. 63] of byte;	{ a colour's DAC entry }
	slot_of		: array[0 .. 63] of longint;	{ the entry a colour holds, -1 }
	held		: array[0 .. 15] of longint;	{ the colour each entry holds, -1 }
	shown		: array[0 .. 15] of longint;	{ what the DAC has: colour + 64 x emphasis }
	nearer		: array[0 .. 15, 0 .. 15] of longint;	{ the entries' distances }
	related		: longint;		{ the emphasis nearer and map were made for, -1 none }

procedure	seq(i, v: longint);
begin
	port[$3C4] := i;
	port[$3C5] := v;
end;

procedure	gc(i, v: longint);
begin
	port[$3CE] := i;
	port[$3CF] := v;
end;

procedure	crtc(i, v: longint);
begin
	port[$3D4] := i;
	port[$3D5] := v;
end;

{ the font: character p fills block k (row k shr 2, column k and 3)
  when bit k of p is set - its two dots on that row's two lines }
procedure	load_font;
var	p, k, b	: longint;
begin
	fillchar(page^, FONT_BYTES, 0);
	for p := 0 to 255 do
		for k := 0 to 7 do
			if (p shr k) and 1 <> 0 then
			begin
				b := p * 32 + (k shr 2) * 2;
				page^[b] := page^[b] or ($C0 shr ((k and 3) * 2));
				page^[b + 1] := page^[b];
			end;
	{ plane 2 open at A0000h, then the text mode's settings back }
	seq(0, 1);
	seq(2, 4);
	seq(4, 7);
	seq(0, 3);
	gc(4, 2);
	gc(5, 0);
	gc(6, 4);
	low_put($A0000, page^, FONT_BYTES);
	seq(0, 1);
	seq(2, 3);
	seq(4, 3);
	seq(0, 3);
	gc(4, 0);
	gc(5, $10);
	gc(6, $0E);
end;

function	txt_start: boolean;
var	i, ax, bx, es, bp	: longint;
begin
	txt_start := FALSE;
	if page = nil then page := malloc(PAGE_BYTES);
	if key_lo = nil then key_lo := malloc(sizeof(CELL_KEYS));
	if key_hi = nil then key_hi := malloc(sizeof(CELL_KEYS));
	if last = nil then last := malloc(256 * 240);
	if slots = nil then slots := malloc(256 * 240);
	if cache = nil then cache := malloc(sizeof(MADE_CACHE));
	if (page = nil) or (key_lo = nil) or (key_hi = nil) or (last = nil) or (slots = nil) or (cache = nil) then exit;
	ax := 3;
	bx := 0;
	real_int($10, ax, bx, es, bp);
	{ 8-dot cells on the 25 MHz clock (640 dots): every block as wide }
	seq(0, 1);
	port[$3C4] := 1;
	port[$3C5] := port[$3C5] or 1;
	port[$3C2] := (port[$3CC] and $F3) or $C0;
	seq(0, 3);
	{ 480 lines, mode 12h's vertical timing (640 x 480 dots: square
	  blocks); four scan lines a cell: 120 rows; no cursor }
	crtc($11, $0C);
	crtc(6, $0B);
	crtc(7, $3E);
	crtc($10, $EA);
	crtc($11, $8C);
	crtc($12, $DF);
	crtc($15, $E7);
	crtc($16, $04);
	port[$3D4] := 9;
	port[$3D5] := (port[$3D5] and $E0) or 3;
	port[$3D4] := $0A;
	port[$3D5] := port[$3D5] or $20;
	{ the attribute controller, in the retrace (reading 3DAh also makes
	  its next write an index): entry i is DAC i, no blinking, no
	  panning, the overscan DAC 16 (black) }
	while port[$3DA] and 8 = 0 do;
	for i := 0 to 15 do
	begin
		port[$3C0] := i;
		port[$3C0] := i;
	end;
	port[$3C0] := $10;
	port[$3C0] := $04;
	port[$3C0] := $11;
	port[$3C0] := 16;
	port[$3C0] := $13;
	port[$3C0] := 0;
	port[$3C0] := $20;
	vga_colour(16, 0, 0, 0);
	load_font;
	fillchar(page^, PAGE_BYTES, 0);
	fresh := TRUE;
	rows_new := TRUE;
	frames := 0;
	emphasis_was := -1;
	related := -1;
	fillchar(map_was, sizeof(map_was), 255);
	for i := 0 to 63 do slot_of[i] := -1;
	for i := 0 to 15 do
	begin
		held[i] := -1;
		shown[i] := -1;
	end;
	txt_start := TRUE;
end;

{ the distance between NES colours a and b, as emphasis shows them }
function	distance(emphasis, a, b: longint): longint;
begin
	distance := sqr(longint(nes_sets[emphasis][a].r) - nes_sets[emphasis][b].r)
		  + sqr(longint(nes_sets[emphasis][a].g) - nes_sets[emphasis][b].g)
		  + sqr(longint(nes_sets[emphasis][a].b) - nes_sets[emphasis][b].b);
end;

{ NES black and the 15 most used colours: those held keep their
  entries, the others take the free ones; every colour drawn as its
  entry or the nearest's }
procedure	pick(emphasis: longint);
var	i, k, j, best, n	: longint;
	d, bd			: longint;
	keep			: array[0 .. 63] of boolean;
	moved			: boolean;	{ an entry let go or given }
begin
	for i := 0 to 63 do keep[i] := FALSE;
	keep[BLACK] := TRUE;
	for n := 2 to 16 do
	begin
		best := -1;
		for i := 0 to 63 do
			if not keep[i] and (count[i] > 0) and ((best < 0) or (count[i] > count[best])) then best := i;
		if best < 0 then break;
		keep[best] := TRUE;
	end;
	{ entries let go, then given to the newcomers }
	moved := FALSE;
	for k := 0 to 15 do
		if (held[k] >= 0) and not keep[held[k]] then
		begin
			slot_of[held[k]] := -1;
			held[k] := -1;
			moved := TRUE;
		end;
	for i := 0 to 63 do
		if keep[i] and (slot_of[i] < 0) then
			for k := 0 to 15 do
				if held[k] < 0 then
				begin
					held[k] := i;
					slot_of[i] := k;
					moved := TRUE;
					break;
				end;
	{ the DAC where an entry's colour or the emphasis changed }
	for k := 0 to 15 do
		if (held[k] >= 0) and (shown[k] <> held[k] + 64 * emphasis) then
		begin
			with nes_sets[emphasis][held[k]] do vga_colour(k, r, g, b);
			shown[k] := held[k] + 64 * emphasis;
			fresh := TRUE;		{ a third colour's nearer may change }
		end;
	{ the same entries and emphasis: nearer and map are as they were }
	if not moved and (emphasis = related) then exit;
	related := emphasis;
	{ the entries' distances, for a cell's third colour }
	for k := 0 to 15 do
		for j := 0 to 15 do
			if (held[k] >= 0) and (held[j] >= 0) then nearer[k, j] := distance(emphasis, held[k], held[j])
			else	nearer[k, j] := $7FFFFFFF;
	{ each colour drawn: its own entry, else the nearest held one's (a
	  colour not counted too: it may come before the next count) }
	for i := 0 to 63 do
		if slot_of[i] >= 0 then map[i] := slot_of[i]
		else
		begin
			bd := -1;
			for k := 0 to 15 do
				if held[k] >= 0 then
				begin
					d := distance(emphasis, held[k], i);
					if (bd < 0) or (d < bd) then
					begin
						bd := d;
						map[i] := k;
					end;
				end;
		end;
end;

{ a cell from its 8 blocks' entries: the most used as the background,
  the most used other one as the foreground, a third drawn as the
  nearer of the two; the character those blocks make }
procedure	cell(const t: CELL_BLOCKS; var ch, attr: byte);
var	k, a, b	: longint;
	p	: byte;
begin
	for k := 0 to 7 do inc(tally[t[k]]);
	a := t[0];
	for k := 1 to 7 do
		if tally[t[k]] > tally[a] then a := t[k];
	b := -1;
	for k := 0 to 7 do
		if (t[k] <> a) and ((b < 0) or (tally[t[k]] > tally[b])) then b := t[k];
	for k := 0 to 7 do tally[t[k]] := 0;
	p := 0;
	if b < 0 then b := a
	else
		for k := 0 to 7 do
			if (t[k] = b) or ((t[k] <> a) and (nearer[t[k], b] < nearer[t[k], a])) then
				p := p or (1 shl k);
	ch := p;
	attr := b or a shl 4;
end;

{ a NES row: in the picture, last shown, its entries }
function	row_of(base: pointer; y: U16): PBYTES;
begin
	row_of := PBYTES(padd(base, longint(y) * 256));
end;

procedure	txt_flip(pic: pointer; emphasis: longint);
var	x, y, o, c, b, h	: U16;
	p0, p1, p2, p3		: U16;
	lo, hi			: U16;
	src, old, r0, r1	: PBYTES;
	t			: CELL_BLOCKS;
	ch, attr		: byte;
	same, any, remap	: boolean;
begin
	emphasis := emphasis and 7;
	{ the rows unlike last frame's, kept }
	for y := 0 to 239 do
	begin
		src := row_of(pic, y);
		old := row_of(last, y);
		same := not rows_new;
		x := 0;
		while same and (x < 64) do
		begin
			if PROW_LONGS(src)^[x] <> PROW_LONGS(old)^[x] then same := FALSE;
			inc(x);
		end;
		dirty[y] := not same;
		if not same then move(src^, old^, 256);
	end;
	rows_new := FALSE;
	{ every 8th frame the colours counted and the entries picked again;
	  the DAC whenever the emphasis changes }
	if frames and 7 = 0 then
	begin
		for x := 0 to 63 do count[x] := 0;
		for y := 0 to 239 do
		begin
			old := row_of(last, y);
			for x := 0 to 255 do inc(count[old^[x]]);
		end;
	end;
	if (frames and 7 = 0) or (emphasis <> emphasis_was) then pick(emphasis);
	emphasis_was := emphasis;
	inc(frames);
	{ the changed rows' entries; every row's when a colour's entry or
	  the DAC changed (and the cache then let go) }
	remap := fresh;
	for x := 0 to 63 do
		if map[x] <> map_was[x] then
		begin
			map_was[x] := map[x];
			remap := TRUE;
		end;
	if fresh then
		for h := 0 to 4095 do cache^[h].attr := $FFFF;
	for y := 0 to 239 do
		if remap or dirty[y] then
		begin
			old := row_of(last, y);
			r0 := row_of(slots, y);
			for x := 0 to 255 do r0^[x] := map[old^[x]];
			dirty[y] := TRUE;
		end;
	{ the sides, black (its entry kept while the mode is) }
	if fresh then
	begin
		attr := slot_of[BLACK] shl 4;
		for y := 0 to ROWS - 1 do
			for x := 0 to LEFT - 1 do
			begin
				o := (y * COLS + x) * 2;
				page^[o] := 0;
				page^[o + 1] := attr;
				o := (y * COLS + COLS - 1 - x) * 2;
				page^[o] := 0;
				page^[o + 1] := attr;
			end;
	end;
	{ the cells on changed rows: two NES rows a cell row }
	any := FALSE;
	c := 0;
	for y := 0 to ROWS - 1 do
	begin
		if not dirty[y * 2] and not dirty[y * 2 + 1] then
		begin
			inc(c, PIC_COLS);
			continue;
		end;
		r0 := row_of(slots, y * 2);
		r1 := row_of(slots, y * 2 + 1);
		o := (y * COLS + LEFT) * 2;
		b := 0;
		for x := 0 to PIC_COLS - 1 do
		begin
			p0 := b;
			p1 := b + 1;
			p2 := b + 2;
			p3 := b + 3;
			inc(b, 4);
			lo := r0^[p0] or r0^[p1] shl 4 or r0^[p2] shl 8 or r0^[p3] shl 12;
			hi := r1^[p0] or r1^[p1] shl 4 or r1^[p2] shl 8 or r1^[p3] shl 12;
			if not fresh and (key_lo^[c] = lo) and (key_hi^[c] = hi) then
			begin
				inc(o, 2);
				inc(c);
				continue;
			end;
			key_lo^[c] := lo;
			key_hi^[c] := hi;
			inc(c);
			if (lo = hi) and (lo = (lo and 15) * $1111) then
			begin
				{ one colour: the background alone }
				ch := 0;
				attr := (lo and 15) shl 4;
			end
			else
			begin
				h := (lo xor (hi shl 3) xor (hi shr 5)) and 4095;
				if (cache^[h].attr <> $FFFF) and (cache^[h].lo = lo) and (cache^[h].hi = hi) then
				begin
					ch := cache^[h].ch;
					attr := cache^[h].attr;
				end
				else
				begin
					t[0] := r0^[p0];
					t[1] := r0^[p1];
					t[2] := r0^[p2];
					t[3] := r0^[p3];
					t[4] := r1^[p0];
					t[5] := r1^[p1];
					t[6] := r1^[p2];
					t[7] := r1^[p3];
					cell(t, ch, attr);
					cache^[h].lo := lo;
					cache^[h].hi := hi;
					cache^[h].ch := ch;
					cache^[h].attr := attr;
				end;
			end;
			page^[o] := ch;
			page^[o + 1] := attr;
			inc(o, 2);
			any := TRUE;
		end;
	end;
	fresh := FALSE;
	if any then low_put($B8000, page^, PAGE_BYTES);
end;

var	k	: longint;

begin
	page := nil;
	cache := nil;
	last := nil;
	slots := nil;
	key_lo := nil;
	key_hi := nil;
	fresh := TRUE;
	fillchar(tally, sizeof(tally), 0);
	for k := 0 to 63 do map[k] := 0;
end.
