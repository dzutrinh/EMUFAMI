{*+
	F_NES.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The console: a .NES on its board (F_MAP's map_new), power, the reset button, a frame; the battery's RAM in
	NAME.SAV beside the ROM, read at open, written at close.
-*}
{$S-}		{ no stack check at every call }
unit	f_nes;

interface

uses
	f_cart;

var	nes_cart	: CART;
	nes_region	: longint;	{ the game's: TV_NTSC, TV_PAL or TV_DENDY }

function	nes_open(const name: string): boolean;
function	nes_why: string;
procedure	nes_close;
procedure	nes_power;
procedure	nes_reset;		{ the reset button }
procedure	nes_frame;
procedure	nes_save;		{ the battery's RAM to the .SAV, if any }

implementation

uses
	f_sys, f_map, f_bus, f_cpu, f_ppu, f_apu, f_pad;

var	why	: string;
	sav	: string;	{ the ROM's name less its extension }

function	nes_why: string;
begin
	nes_why := why;
end;

function	battery: boolean;
begin
	battery := (board <> nil) and nes_cart.battery and (board^.ram <> nil);
end;

procedure	nes_save;
var	f	: file;
begin
	if not battery then exit;
	assign(f, sav + '.SAV');
	{$I-}
	rewrite(f, 1);
	if ioresult = 0 then
	begin
		blockwrite(f, board^.ram^, board^.ram_len);
		close(f);
	end;
	{$I+}
	if ioresult <> 0 then;		{ a full disk: the program goes on }
end;

procedure	load_battery;
var	f	: file;
	n	: longint;
begin
	if not battery then exit;
	assign(f, sav + '.SAV');
	filemode := 0;
	{$I-} reset(f, 1); {$I+}
	filemode := 2;
	if ioresult <> 0 then exit;
	n := filesize(f);
	if n > board^.ram_len then n := board^.ram_len;
	blockread(f, board^.ram^, n);
	close(f);
end;

function	nes_open(const name: string): boolean;
begin
	nes_open := FALSE;
	nes_close;
	if not cart_load(name, nes_cart) then
	begin
		why := cart_why;
		exit;
	end;
	board := map_new(@nes_cart);
	if board = nil then
	begin
		why := 'MAPPER ' + itoa(nes_cart.mapper) + ' IS NOT SUPPORTED';
		cart_free(nes_cart);
		exit;
	end;
	{ the .SAV beside the ROM: its name less the extension }
	sav := name;
	while (sav <> '') and not (sav[length(sav)] in ['.', '\', ':']) do
		delete(sav, length(sav), 1);
	if (sav <> '') and (sav[length(sav)] = '.') then delete(sav, length(sav), 1)
	else	sav := name;
	nes_region := nes_cart.tv;
	if nes_region = TV_MULTI then nes_region := TV_NTSC;
	ppu_region := nes_region;
	apu_pal := nes_region = TV_PAL;
	apu_dendy := nes_region = TV_DENDY;
	load_battery;
	nes_power;
	why := '';
	nes_open := TRUE;
end;

procedure	nes_close;
begin
	nes_save;
	if board <> nil then dispose(board, Done);
	board := nil;
	cart_free(nes_cart);
end;

procedure	nes_power;
begin
	bus_power;
	board^.Reset;
	{ a trainer's 512 bytes at $7000 }
	if (nes_cart.trainer <> nil) and (board^.ram <> nil) then move(nes_cart.trainer^, padd(board^.ram, $1000)^, 512);
	cpu_power;
end;

procedure	nes_reset;
begin
	apu_reset(cycles);
	ppu_reset(cycles);
	cpu_reset;
end;

procedure	nes_frame;
begin
	cpu_run(ppu_frame_end);
	bus_sync;
	apu_run(cycles);		{ the APU's samples up to the end }
	bus_rebase;
end;

begin
	board := nil;
	sav := '';
	why := '';
	nes_region := TV_NTSC;
	fillchar(nes_cart, sizeof(nes_cart), 0);
end.
