{*+
	F_KEYS.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The keyboard by its own interrupt (IRQ 1): every key held or
	not (key_held), the presses queued (key_get).  E0 prefixes, the
	fake shifts round grey keys and Pause's bytes let go; the BIOS
	sees no keys; taken out however the program ends.
-*}
{$X+}
{$ifdef VER70}{$F+}{$endif}
{$S-}		{ no stack check: the interrupt runs on the extender's stack }
unit	f_keys;

interface

const
	KEY_ESC		= $01;
	KEY_1		= $02;
	KEY_TAB		= $0F;
	KEY_Q		= $10;
	KEY_W		= $11;
	KEY_T		= $14;
	KEY_Y		= $15;
	KEY_P		= $19;
	KEY_ENTER	= $1C;
	KEY_A		= $1E;
	KEY_S		= $1F;
	KEY_D		= $20;
	KEY_G		= $22;
	KEY_H		= $23;
	KEY_LSHIFT	= $2A;
	KEY_Z		= $2C;
	KEY_X		= $2D;
	KEY_RSHIFT	= $36;
	KEY_SPACE	= $39;
	KEY_F1		= $3B;
	KEY_F2		= $3C;
	KEY_F3		= $3D;
	KEY_F4		= $3E;
	KEY_F5		= $3F;
	KEY_F6		= $40;
	KEY_HOME	= $47;
	KEY_UP		= $48;
	KEY_PGUP	= $49;
	KEY_LEFT	= $4B;
	KEY_RIGHT	= $4D;
	KEY_END		= $4F;
	KEY_DOWN	= $50;
	KEY_PGDN	= $51;

var	key_held	: array[0 .. 127] of boolean;

procedure	keys_start;
procedure	keys_end;
function	key_get: longint;		{ the next key pressed, 0 none }
procedure	keys_flush;			{ the presses waiting dropped }

implementation

uses
	f_dos;

const
	QSIZE	= 64;

var	queue		: array[0 .. QSIZE - 1] of byte;
	head, tail	: longint;
	prefix		: boolean;	{ an E0 came }
	skip		: longint;	{ Pause's bytes still to come }
	on			: boolean;
	hooked		: boolean;

procedure	key_feed(scan: longint);
var	code, next	: longint;
begin
	if skip > 0 then
	begin
		dec(skip);
		exit;
	end;
	case scan of
	$E0:	begin
			prefix := TRUE;
			exit;
		end;
	$E1:	begin
			skip := 5;
			exit;
		end;
	end;
	code := scan and $7F;
	if prefix and ((code = KEY_LSHIFT) or (code = KEY_RSHIFT)) then
	begin
		prefix := FALSE;		{ a fake shift round a grey key }
		exit;
	end;
	prefix := FALSE;
	key_held[code] := scan < $80;
	if scan < $80 then
	begin
		next := (tail + 1) and (QSIZE - 1);
		if next <> head then
		begin
			queue[tail] := code;
			tail := next;
		end;
	end;
end;

{$ifdef __TMT__}
procedure	keys_isr(eax, ebx, ecx, edx, esi, edi: dword); interrupt;
{$else}
procedure	keys_isr; interrupt;
{$endif}
begin
	isr_enter;
	key_feed(port[$60]);
	port[$20] := $20;
end;

procedure	keys_isr_end;
begin
end;

function	key_get: longint;
begin
	key_get := 0;
	if head = tail then exit;
	key_get := queue[head];
	head := (head + 1) and (QSIZE - 1);
end;

procedure	keys_flush;
begin
	head := tail;
end;

procedure	keys_end;
begin
	if not on then exit;
	vec_give($09);
	on := FALSE;
end;

procedure	keys_exit;
begin
	keys_end;
end;

procedure	keys_start;
begin
	if on then exit;
	fillchar(key_held, sizeof(key_held), 0);
	head := 0;
	tail := 0;
	prefix := FALSE;
	skip := 0;
	if not hooked then on_exit({$ifdef FPC}@{$endif}keys_exit);
	hooked := TRUE;
	lock_mem(queue, sizeof(queue));
	lock_mem(key_held, sizeof(key_held));
	lock_mem(head, sizeof(head));
	lock_mem(tail, sizeof(tail));
	lock_mem(prefix, sizeof(prefix));
	lock_mem(skip, sizeof(skip));
	vec_take($09, @keys_isr, @key_feed, @keys_isr_end);
	on := TRUE;
end;

begin
	on := FALSE;
	hooked := FALSE;
	head := 0;
	tail := 0;
	prefix := FALSE;
	skip := 0;
	fillchar(key_held, sizeof(key_held), 0);
end.
