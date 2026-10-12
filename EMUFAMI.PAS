{*+
	EMUFAMI.PAS
	-----------
	EMUFAMI, an educational NES emulator for DOS, fully written in Pascal.
	Version 1.3
	(c) 2026 Trinh D.D. Nguyen
	Infinity Group

	Support compilers:
	- TMT Pascal 3.9
	- Free Pascal 3.2
	- Borland Pascal 7.0
-*}
{$X+}
{$ifdef VER70}{$F+}{$endif}
program	emufami;

uses
	dos,
	f_sys,
	f_dos,
	f_vga,
	f_text,
	f_keys,
	f_sb,
	f_cart,
	f_map,
	f_cpu,
	f_ppu,
	f_apu,
	f_pad,
	f_pal,
	f_nes;

const
	APP_VER		= '1.3';
	RATE		= 22050;	{ samples a second asked of the card }
	HALF_RATE	= 11025;	{ or with F6: half the mixing }
	MAX_ENTRIES	= 1024;
	LIST_Y		= 36;		{ the list's first row, pixels }
	LIST_ROWS	= 21;
	COL_SIZE	= 21;		{ the columns' right ends, in characters }
	COL_MAPPER	= 30;
	{ the program's colours: DAC entries past the NES's 64 }
	C_BG		= 64;
	C_TEXT		= 65;
	C_DIM		= 66;
	C_BAR		= 67;
	C_TITLE		= 68;
	C_BAND		= 69;
	C_WARN		= 70;
	C_DIR		= 71;		{ folders in the list }
	UI_RGB	 	: array[C_BG .. C_DIR, 0 .. 2] of byte = (
		( 16,  16,  28),
		(232, 232, 232),
		(120, 120, 136),
		( 40,  72, 160),
		(230,  40,  40),
		( 32,  32,  52),
		(255, 200,  64),
		(112, 208, 240));

type
	ENTRY	= record
		name	: string[12];
		size	: longint;	{ bytes }
		dir		: boolean;
		mapper	: longint;	{ -1: not iNES }
	end;
	ENTRY_LIST	= array[0 .. MAX_ENTRIES - 1] of ENTRY;

var
	path		: string;		{ the folder shown, ending in \ }
	entries		: ^ENTRY_LIST;		{ the folder's (on the heap: 16-bit data is short) }
	count		: longint;
	cur, top	: longint;
	message		: string;
	sound_on	: boolean;		{ a card playing }
	muted		: boolean;		{ F3: the sound off (the card kept) }
	show_fps	: boolean;		{ F4: frames a second shown }
	text_mode	: boolean;		{ F5 or /TEXT: the game in VGA text mode }
	low_rate	: boolean;		{ F6: the card at 11,025 samples a second }
	base_cycles	: longint;		{ the APU's sample length as made }
	scr			: PSCREEN;		{ the list's and the overlays' buffer }

{ ---- the list ---- }

procedure	ui_colours;
var	i	: longint;
begin
	for i := C_BG to C_DIR do
		vga_colour(i, UI_RGB[i, 0], UI_RGB[i, 1], UI_RGB[i, 2]);
end;

function	less(const a, b: ENTRY): boolean;
begin
	if a.dir <> b.dir then less := a.dir
	else	less := a.name < b.name;
end;

{ the header's mapper, -1 when it is not iNES }
function	mapper_of(const name: string): longint;
var	f	: file;
	h	: array[0 .. 15] of byte;
	got	: RWCOUNT;
begin
	mapper_of := -1;
	assign(f, name);
	filemode := 0;
	{$I-} reset(f, 1); {$I+}
	filemode := 2;
	if ioresult <> 0 then exit;
	blockread(f, h, 16, got);
	close(f);
	if (got < 16) or
	   (h[0] <> $4E) or
	   (h[1] <> $45) or
	   (h[2] <> $53) or
	   (h[3] <> $1A) then exit;
	if (h[7] and $0C <> $08) and
	   ((h[12] <> 0) or (h[13] <> 0) or (h[14] <> 0) or (h[15] <> 0)) then
		mapper_of := h[6] shr 4
	else
		mapper_of := (h[6] shr 4) or (h[7] and $F0);
end;

procedure	scan_folder;
var	sr	: SEARCHREC;
	e	: ENTRY;
	i, j: longint;
	ext	: string;
begin
	count := 0;
	if length(path) > 3 then
	begin
		entries^[0].name := '..';
		entries^[0].dir := TRUE;
		entries^[0].mapper := -1;
		entries^[0].size := 0;
		count := 1;
	end;
	FindFirst(path + '*.*', $37, sr);
	while (DosError = 0) and (count < MAX_ENTRIES) do
	begin
		ext := '';
		if length(sr.name) > 4 then ext := uppercase(copy(sr.name, length(sr.name) - 3, 4));
		entries^[count].size := sr.size;
		if (sr.attr and $10 <> 0) and (sr.name <> '.') and (sr.name <> '..') then
		begin
			entries^[count].name := sr.name;
			entries^[count].dir := TRUE;
			entries^[count].mapper := -1;
			inc(count);
		end
		else if (sr.attr and $10 = 0) and (ext = '.NES') then
		begin
			entries^[count].name := sr.name;
			entries^[count].dir := FALSE;
			entries^[count].mapper := mapper_of(path + sr.name);
			inc(count);
		end;
		FindNext(sr);
	end;
{$ifndef VER70}
	FindClose(sr);
{$endif}
	{ '..' first, then folders, then games, by name }
	for i := 1 to count - 1 do
	begin
		e := entries^[i];
		j := i - 1;
		while (j >= 0) and (entries^[j].name <> '..') and less(e, entries^[j]) do
		begin
			entries^[j + 1] := entries^[j];
			dec(j);
		end;
		entries^[j + 1] := e;
	end;
	{ the cursor on the first game, if any }
	cur := 0;
	for i := count - 1 downto 0 do
		if not entries^[i].dir then cur := i;
	top := 0;
end;

{ the end of a text, so it fits n characters }
function	fit(const s: string; n: longint): string;
begin
	if length(s) <= n then
		fit := s
	else
		fit := '..' + copy(s, length(s) - n + 3, n - 2);
end;

{ a text ending at character column col }
procedure	text_right(col, y: longint; const s: string; c: longint);
begin
	vga_text(scr, col * 8 - 8 * length(s), y, s, c);
end;

{ the title band }
procedure	title(const s: string);
begin
	vga_bar(scr, 0, 0, VGA_W, 12, C_BAND);
	vga_text(scr, 4, 2, 'EMUFAMI', C_TITLE);
	vga_text(scr, 64, 2, s, C_DIM);
end;

procedure	draw_list;
var	i, k, y, c	: longint;
	s, sz, m	: string;
begin
	fillchar(scr^, sizeof(SCREEN), C_BG);
	title(APP_VER);
	text_right(31, 2, 'ESC QUITS', C_DIM);
	vga_text(scr, 4, 15, fit(path, 31), C_DIM);
	vga_text(scr, 8, 26, 'NAME', C_TITLE);
	text_right(COL_SIZE, 26, 'SIZE', C_TITLE);
	text_right(COL_MAPPER, 26, 'MAPPER', C_TITLE);
	if cur < top then top := cur;
	if cur >= top + LIST_ROWS then top := cur - LIST_ROWS + 1;
	if count = 0 then vga_text(scr, 12, LIST_Y + 8, 'NO ROMS FOUND', C_DIM);
	for i := 0 to LIST_ROWS - 1 do
	begin
		k := top + i;
		if k >= count then break;
		y := LIST_Y + i * 8;
		if k = cur then vga_bar(scr, 0, y, VGA_W, 8, C_BAR);
		c := C_TEXT;
		if entries^[k].dir then
		begin
			c := C_DIR;
			s := '\' + entries^[k].name;
			if entries^[k].name = '..' then s := '.. (UP)';
			sz := 'DIR';
			m := '';
		end
		else
		begin
			{ the size in KB, the mapper's number: dimmed when not played }
			s := entries^[k].name;
			sz := itoa((entries^[k].size + 1023) div 1024) + 'K';
			if entries^[k].mapper < 0 then m := '?'
			else	m := itoa(entries^[k].mapper);
			if (entries^[k].mapper < 0) or not map_has(entries^[k].mapper) then c := C_DIM;
		end;
		vga_text(scr, 8, y, s, c);
		text_right(COL_SIZE, y, sz, c);
		text_right(COL_MAPPER, y, m, c);
	end;
	{ a scroll bar when they do not all fit }
	if count > LIST_ROWS then
	begin
		y := LIST_Y + top * (LIST_ROWS * 8) div count;
		vga_bar(scr, VGA_W - 3, y, 2, LIST_ROWS * LIST_ROWS * 8 div count, C_DIM);
	end;
	vga_bar(scr, 0, 210, VGA_W, 30, C_BAND);
	vga_text(scr, 4, 213, 'ENTER PLAY  F1 HELP  F2 ABOUT', C_TEXT);
	if message <> '' then vga_text(scr, 4, 226, fit(message, 31), C_WARN)
	else if sound_on and muted then vga_text(scr, 4, 226, 'SOUND: OFF', C_DIM)
	else if sound_on and low_rate then vga_text(scr, 4, 226, 'SOUND: ' + sb_why + ' 11K', C_DIM)
	else if sound_on then vga_text(scr, 4, 226, 'SOUND: ' + sb_why, C_DIM)
	else	vga_text(scr, 4, 226, 'NO SOUND: ' + fit(sb_why, 21), C_DIM);
	vga_retrace;
	vga_flip(scr);
end;

procedure	draw_help;
const	LINES	: array[0 .. 23] of string[31] = (
		'ROM PICKER',
		' ARROWS         NAVIGATE',
		' A-Z            QUICK JUMP',
		' ENTER          PLAY/OPEN',
		' BACKSPACE      FOLDER UP',
		' F2             ABOUT',
		' F3             SOUND ON/OFF',
		' F4             FPS ON/OFF',
		' F6             AUDIO 11/22 KHZ',
		' ESC            QUIT',
		'',
		'IN-GAME         PAD 1    PAD 2',
		' D-PAD          ARROWS   WASD',
		' A              X        H',
		' B              Z        G',
		' SELECT         RSHIFT   T',
		' START          ENTER    Y',
		' P              PAUSE',
		' F1             RESET',
		' F5             VGA/TEXT MODE',
		' ESC            CLOSE',
		'',
		'SAVES',
		' <NAME>.SAV NEXT TO THE GAME');
var	i	: longint;
begin
	fillchar(scr^, sizeof(SCREEN), C_BG);
	title('KEYS');
	for i := 0 to high(LINES) do
		if (i = 0) or (i = 11) or (i = 22) then
			vga_text(scr, 4, 17 + i * 8, LINES[i], C_TITLE)
		else
			vga_text(scr, 4, 17 + i * 8, LINES[i], C_TEXT);
	vga_bar(scr, 0, 210, VGA_W, 30, C_BAND);
	vga_text(scr, 4, 213, 'ANY KEY: BACK', C_TEXT);
	vga_retrace;
	vga_flip(scr);
end;

procedure	draw_about;
const	LINES	: array[0 .. 9] of string[31] = (
		'A NES EMULATOR FOR DOS',
		'',
		'FOR EDUCATIONAL PURPOSE ONLY',
		'WRITTEN IN PURE PASCAL',
		'',
		'----',
		'',
		'(C) 2026 TRINH D.D. NGUYEN',
		'INFINITY GROUP',
		'');
var	i	: longint;
begin
	fillchar(scr^, sizeof(SCREEN), C_BG);
	title('ABOUT');
	vga_text(scr, 4, 20, 'EMUFAMI ' + APP_VER, C_TITLE);
	for i := 0 to high(LINES) do vga_text(scr, 4, 34 + i * 10, LINES[i], C_TEXT);
	vga_text(scr, 4, 194, 'BUILT WITH ' +
{$ifdef FPC}
	'FREE'
{$else}
{$ifdef VER70}
	'BORLAND'
{$else}
	'TMT'
{$endif}
{$endif}
	+ ' PASCAL', C_DIM);
	vga_bar(scr, 0, 210, VGA_W, 30, C_BAND);
	vga_text(scr, 4, 213, 'ANY KEY: BACK', C_TEXT);
	vga_retrace;
	vga_flip(scr);
end;

{ ---- a game ---- }

{ the pads from the keys held }
procedure	read_pads;
var	b	: longint;
begin
	b := 0;
	if key_held[KEY_X] then b := b or PAD_A;
	if key_held[KEY_Z] then b := b or PAD_B;
	if key_held[KEY_RSHIFT] then b := b or PAD_SELECT;
	if key_held[KEY_ENTER] then b := b or PAD_START;
	if key_held[KEY_UP] then b := b or PAD_UP;
	if key_held[KEY_DOWN] then b := b or PAD_DOWN;
	if key_held[KEY_LEFT] then b := b or PAD_LEFT;
	if key_held[KEY_RIGHT] then b := b or PAD_RIGHT;
	pad_buttons[0] := b;
	b := 0;
	if key_held[KEY_H] then b := b or PAD_A;
	if key_held[KEY_G] then b := b or PAD_B;
	if key_held[KEY_T] then b := b or PAD_SELECT;
	if key_held[KEY_Y] then b := b or PAD_START;
	if key_held[KEY_W] then b := b or PAD_UP;
	if key_held[KEY_S] then b := b or PAD_DOWN;
	if key_held[KEY_A] then b := b or PAD_LEFT;
	if key_held[KEY_D] then b := b or PAD_RIGHT;
	pad_buttons[1] := b;
end;

{ the frame's samples to the card, the next frame's rate nudged by how
  full its ring is: about three frames waiting }
procedure	frame_sound;
var	q, target, c	: longint;
begin
	if not sound_on or muted then exit;
	sb_put(apu_samples, apu_count);
	apu_count := 0;
	target := 3 * sb_rate div 60;
	q := sb_queued;
	c := base_cycles + (q - target) * (base_cycles div 1000) div (target div 20);
	if c > base_cycles + base_cycles div 50 then c := base_cycles + base_cycles div 50;
	if c < base_cycles - base_cycles div 50 then c := base_cycles - base_cycles div 50;
	apu_set_sample_cycles(c);
end;

{ the picture with a line of text over it, until a key }
const	T_BAND	= $0F;		{ text mode's band and text: NES black, white }
	T_TEXT	= $30;
	PAUSE_TEXT	= 'PAUSED - P TO RESUME';
	TEXT_NOTE	= 'TEXT MODE 640X480';

procedure	overlay(const s: string);
var	band, ink	: longint;
begin
	if text_mode then
	begin
		band := T_BAND;
		ink := T_TEXT;
	end
	else
	begin
		pal_show(ppu_emphasis);
		band := C_BAND;
		ink := C_TEXT;
	end;
	move(ppu_screen^, scr^, sizeof(SCREEN));
	vga_bar(scr, 0, 112, VGA_W, 16, band);
	vga_text(scr, (VGA_W - 8 * length(s)) div 2, 116, s, ink);
	vga_retrace;
	if text_mode then txt_flip(scr, ppu_emphasis) else vga_flip(scr);
end;

{ the sound on or off (F3): off, the APU makes no samples (and runs the
  faster for it), the card plays silence }
{ the card's rate (F6): 22,050 samples a second, or 11,025 (half the
  mixing, duller highs); the card started again at it }
procedure	set_sound(off: boolean); forward;

procedure	set_rate(low: boolean);
begin
	low_rate := low;
	if not sound_on then exit;
	sb_stop;
	if low then sound_on := sb_start(HALF_RATE) else sound_on := sb_start(RATE);
	set_sound(muted);
end;

procedure	set_sound(off: boolean);
begin
	muted := off;
	if not sound_on then exit;
	if muted then
	begin
		apu_audio(0);
		sb_silence;
	end
	else
	begin
		apu_audio(sb_rate);
		base_cycles := apu_sample_cycles;
	end;
end;

{ the BIOS's clock at 0040:006C: 18.2 ticks a second since midnight }
function	bios_ticks: longint;
var	t	: longint;
begin
	low_get($46C, t, 4);
	bios_ticks := t;
end;

{ a line of text in a band over the picture (the PPU draws it all again
  next frame) }
procedure	over_game(right: boolean; const s: string);
var	x, band, ink	: longint;
begin
	x := 8;
	if right then x := VGA_W - 8 - 8 * length(s);
	band := C_BAND;
	ink := C_TEXT;
	if text_mode then
	begin
		band := T_BAND;
		ink := T_TEXT;
	end;
	vga_bar(PSCREEN(ppu_screen), x - 4, 5, 8 * length(s) + 8, 14, band);
	vga_text(PSCREEN(ppu_screen), x, 8, s, ink);
end;

{ the game in text mode (TRUE: when there is memory for it) or back in
  VGA's 256x240 }
procedure	set_text(on: boolean);
begin
	if on then text_mode := txt_start
	else
	begin
		vga_start;
		ui_colours;
		pal_forget;
		text_mode := FALSE;
	end;
end;

procedure	play(const name: string);
var	k, acc, frame	: longint;
	paused		: boolean;
	note		: string;	{ a line shown over the game a while }
	note_frames	: longint;
	{ frames a second: the frames counted since fps_from (BIOS ticks),
	  the last count, -1 none yet }
	fps_from, fps_frames, fps, t, n	: longint;
	{ pacing: the BIOS tick the next frame is due on, and the fraction
	  (in 65536ths) }
	due_tick, due_frac, now	: longint;
	s		: string;
begin
	message := '';
	if not nes_open(name) then
	begin
		message := uppercase(nes_why);
		exit;
	end;
	keys_flush;
	pal_forget;
	if text_mode then set_text(TRUE);
	set_sound(muted);
	acc := 0;
	frame := 0;
	paused := FALSE;
	note_frames := 0;
	if text_mode then
	begin
		note := TEXT_NOTE;
		note_frames := 90;
	end;
	fps := -1;
	fps_frames := 0;
	fps_from := bios_ticks;
	due_tick := bios_ticks;
	due_frac := 0;
	repeat
		sb_watch;
		k := key_get;
		if k = KEY_ESC then break;
		if k = KEY_F1 then nes_reset;
		if k = KEY_F3 then
		begin
			set_sound(not muted);
			if muted then note := 'SOUND OFF' else note := 'SOUND ON';
			note_frames := 90;
		end;
		if k = KEY_F4 then show_fps := not show_fps;
		if k = KEY_F6 then
		begin
			set_rate(not low_rate);
			if not sound_on then note := 'NO SOUND'
			else if low_rate then note := 'AUDIO 11 KHZ'
			else	note := 'AUDIO 22 KHZ';
			note_frames := 90;
		end;
		if k = KEY_F5 then
		begin
			set_text(not text_mode);
			if text_mode then note := TEXT_NOTE else note := 'VGA 256X240';
			note_frames := 90;
			if paused then overlay(PAUSE_TEXT);
		end;
		if k = KEY_P then
		begin
			paused := not paused;
			if paused then
			begin
				sb_silence;
				overlay(PAUSE_TEXT);
			end;
		end;
		if paused then
		begin
			fps_frames := 0;		{ the count starts again after }
			fps_from := bios_ticks;
			due_tick := bios_ticks;
			vga_retrace;
			continue;
		end;
		if cpu.jammed then
		begin
			overlay('GAME HALTED - ESC');
			vga_retrace;
			continue;
		end;
		read_pads;
		nes_frame;
		inc(frame);
		frame_sound;
		{ the frame's time on the BIOS clock (1193182 / n 65536ths of
		  a tick); on time or ahead, refreshes waited for: the screen's
		  rate (60 a second, VGA and text) over the game's (NTSC 60, PAL
		  and Dendy 50); more than a tick behind, shown at once (a
		  slow machine not held to whole refreshes); half a second
		  behind, or past midnight, the clock taken as it is }
		if nes_region = TV_NTSC then n := 60 else n := 50;
		inc(due_frac, 1193182 div n);
		inc(due_tick, due_frac shr 16);
		due_frac := due_frac and $FFFF;
		now := bios_ticks;
		if (now < due_tick - 1000) or (now > due_tick + 9) then due_tick := now;
		if now <= due_tick + 1 then
		begin
			inc(acc, 60);
			while acc >= n do
			begin
				vga_retrace;
				dec(acc, n);
			end;
		end
		else	acc := 0;
		if not text_mode then pal_show(ppu_emphasis);
		{ the frames of a second or so (18 ticks and more), rounded; the
		  clock gone back at midnight: counted again }
		inc(fps_frames);
		t := bios_ticks - fps_from;
		if t < 0 then
		begin
			fps_frames := 0;
			fps_from := bios_ticks;
		end
		else if t >= 18 then
		begin
			fps := (fps_frames * 182065 + t * 5000) div (t * 10000);
			fps_frames := 0;
			fps_from := bios_ticks;
		end;
		if note_frames > 0 then
		begin
			over_game(FALSE, note);
			dec(note_frames);
		end;
		if show_fps and (fps >= 0) then
		begin
			s := itoa(fps) + ' FPS';
			over_game(TRUE, s);
		end;
		if text_mode then txt_flip(ppu_screen, ppu_emphasis) else vga_flip(ppu_screen);
	until FALSE;
	nes_close;
	if text_mode then
	begin
		vga_start;
		ui_colours;
	end;
	apu_count := 0;
	sb_silence;
	keys_flush;
	pal_forget;
end;

{ ---- the program ---- }

procedure	open_entry;
var	i	: longint;
begin
	if count = 0 then exit;
	if entries^[cur].dir then
	begin
		if entries^[cur].name = '..' then
		begin
			i := length(path) - 1;
			while (i > 0) and (path[i] <> '\') do dec(i);
			path := copy(path, 1, i);
		end
		else	path := path + entries^[cur].name + '\';
		scan_folder;
		message := '';
	end
	else	play(path + entries^[cur].name);
end;

{ the next entry whose name starts with c, after the cursor }
procedure	jump(c: char);
var	i, k	: longint;
begin
	for i := 1 to count do
	begin
		k := (cur + i) mod count;
		if upcase(entries^[k].name[1]) = c then
		begin
			cur := k;
			exit;
		end;
	end;
end;

const
	LETTERS	: array[$10 .. $32] of char = 'QWERTYUIOP....ASDFGHJKL.....ZXCVBNM';

procedure	picker;
var	k	: longint;
	page: longint;	{ 0 the list, 1 the keys, 2 about }
begin
	page := 0;
	repeat
		case page of
		1:	draw_help;
		2:	draw_about;
		else	draw_list;
		end;
		k := key_get;
		while k = 0 do
		begin
			sb_watch;
			vga_retrace;
			k := key_get;
		end;
		if page <> 0 then
		begin
			page := 0;
			continue;
		end;
		case k of
		KEY_ESC:	break;
		KEY_F1:		page := 1;
		KEY_F2:		page := 2;
		KEY_F3:		set_sound(not muted);
		KEY_F4:		show_fps := not show_fps;
		KEY_F6:		set_rate(not low_rate);
		KEY_UP:		if cur > 0 then dec(cur);
		KEY_DOWN:	if cur < count - 1 then inc(cur);
		KEY_PGUP:	begin
					dec(cur, LIST_ROWS);
					if cur < 0 then cur := 0;
				end;
		KEY_PGDN:	begin
					inc(cur, LIST_ROWS);
					if cur > count - 1 then cur := count - 1;
					if cur < 0 then cur := 0;
				end;
		KEY_HOME:	cur := 0;
		KEY_END:	if count > 0 then cur := count - 1;
		KEY_ENTER:	open_entry;
		$0E:		if (count > 0) and (entries^[0].name = '..') then
				begin
					cur := 0;
					open_entry;
				end;
		$10 .. $19, $1E .. $26, $2C .. $32:
				jump(LETTERS[k]);
		end;
	until FALSE;
end;

var
	arg,
	game	: string;
	i		: longint;

begin
	if not vga_present then
	begin
		writeln('EMUFAMI needs a VGA adapter.');
		halt(1);
	end;
	scr := malloc(sizeof(SCREEN));
	entries := malloc(sizeof(ENTRY_LIST));
	if (scr = nil) or (entries = nil) then
	begin
		writeln('EMUFAMI: not enough memory.');
		halt(1);
	end;
	GetDir(0, path);
	game := '';
	text_mode := FALSE;
	for i := 1 to paramcount do
	begin
		arg := uppercase(paramstr(i));
		if arg = '/TEXT' then text_mode := TRUE
		else if (length(arg) > 4) and (copy(arg, length(arg) - 3, 4) = '.NES') then
		begin
			game := arg;
			path := arg;
			while (path <> '') and not (path[length(path)] in ['\', ':']) do delete(path, length(path), 1);
			if path = '' then GetDir(0, path);
		end
		else	path := arg;
	end;
	if (path <> '') and (path[length(path)] <> '\') then path := path + '\';
	if (length(path) = 2) and (path[2] = ':') then path := path + '\';
	pal_make;
	ppu_start;
	cpu_start;
	apu_start;
	sound_on := sb_start(RATE);
	muted := FALSE;
	low_rate := FALSE;
	show_fps := FALSE;
	keys_start;
	vga_start;
	ui_colours;
	message := '';
	scan_folder;
	{ a game named on the command line: Esc ends EMUFAMI too (for
	  scripts), a game that cannot open is reported, exit code 1 }
	if game <> '' then
	begin
		if pos('\', game) = 0 then game := path + game;
		play(game);
	end
	else	picker;
	vga_end;
	keys_end;
	sb_stop;
	if (game <> '') and (message <> '') then
	begin
		writeln('EMUFAMI: ', message);
		halt(1);
	end;
end.
