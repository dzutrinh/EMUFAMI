{*+
	F_DOS.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	What TMT Pascal (DOS/4GW, flat) and Free Pascal (go32v2 on a
	DPMI host) do differently: memory below 1 MB, a block of it, an
	interrupt's vector, the program's end.  isr_enter: under FPC
	four instructions load the data segment an interrupt may come
	without - the only assembly in EMUFAMI.
-*}
{$X+}
unit	f_dos;

interface

type	EXIT_PROC	= procedure;

{ conventional memory, by linear address }
procedure	low_put(linear: longint; var src; n: longint);
procedure	low_get(linear: longint; var dst; n: longint);
{ a block of n bytes below 1 MB: its linear address (0: none), handle
  for low_free }
function	low_alloc(n: longint; var handle: longint): longint;
procedure	low_free(handle: longint);
{ a protected-mode interrupt vector: handler in, the old kept; the code
  from code_from to code_to (what the handler runs) kept in memory }
procedure	vec_take(vec: longint; handler, code_from, code_to: pointer);
{ data an interrupt handler uses kept in memory (FPC: locked against the
  DPMI host's paging; TMT's DOS/4GW does not page) }
procedure	lock_mem(var data; n: longint);
procedure	vec_give(vec: longint);
procedure	isr_enter;
procedure	on_exit(p: EXIT_PROC);		{ run when the program ends }

implementation

uses	f_sys{$ifdef FPC}, go32{$else}, dos, dpmi{$endif};

const	VEC_MAX	= 4;

var	{ the vectors taken: their numbers and old handlers }
	vec_n	: longint;
	vec_no	: array[0 .. VEC_MAX - 1] of longint;
{$ifdef FPC}
	vec_old	: array[0 .. VEC_MAX - 1] of tseginfo;
	{ the program's data segment, kept by FPC's startup code }
	ds_alias	: word; external name '___v2prt0_ds_alias';
{$else}
	vec_old	: array[0 .. VEC_MAX - 1] of FarPointer;
	old_exit	: procedure;
{$endif}
	exits	: array[0 .. 7] of EXIT_PROC;
	exit_n	: longint;

procedure	low_put(linear: longint; var src; n: longint);
begin
{$ifdef FPC}
	dosmemput(linear shr 4, linear and 15, src, n);
{$else}
	move(src, pointer(linear)^, n);
{$endif}
end;

procedure	low_get(linear: longint; var dst; n: longint);
begin
{$ifdef FPC}
	dosmemget(linear shr 4, linear and 15, dst, n);
{$else}
	move(pointer(linear)^, dst, n);
{$endif}
end;

function	low_alloc(n: longint; var handle: longint): longint;
var	r	: longint;
begin
{$ifdef FPC}
	r := global_dos_alloc(n);
{$else}
	r := AllocDOSmemoryBlock(n);
{$endif}
	handle := r and $FFFF;		{ the selector }
	if r = 0 then low_alloc := 0
	else	low_alloc := (r shr 16) * 16;	{ the real-mode segment's address }
end;

procedure	low_free(handle: longint);
begin
{$ifdef FPC}
	global_dos_free(handle);
{$else}
	FreeDOSMemoryBlock(handle);
{$endif}
end;

procedure	lock_mem(var data; n: longint);
begin
{$ifdef FPC}
	lock_data(data, n);
{$endif}
end;

procedure	vec_take(vec: longint; handler, code_from, code_to: pointer);
{$ifdef FPC}
var	h	: tseginfo;
{$endif}
begin
	if vec_n >= VEC_MAX then exit;
	vec_no[vec_n] := vec;
{$ifdef FPC}
	lock_code(code_from, PTRVAL(code_to) - PTRVAL(code_from));
	get_pm_interrupt(vec, vec_old[vec_n]);
	h.offset := handler;
	h.segment := get_cs;
	set_pm_interrupt(vec, h);
{$else}
	GetIntVec(vec, vec_old[vec_n]);
	SetIntVec(vec, handler);
{$endif}
	inc(vec_n);
end;

procedure	vec_give(vec: longint);
var	i, k	: longint;
begin
	for i := vec_n - 1 downto 0 do
		if vec_no[i] = vec then
		begin
{$ifdef FPC}
			set_pm_interrupt(vec, vec_old[i]);
{$else}
			SetIntVec(vec, vec_old[i]);
{$endif}
			for k := i to vec_n - 2 do
			begin
				vec_no[k] := vec_no[k + 1];
				vec_old[k] := vec_old[k + 1];
			end;
			dec(vec_n);
			exit;
		end;
end;

{$ifdef FPC}
{$asmmode att}
procedure	isr_enter; assembler; nostackframe;
asm
	movw	%cs:ds_alias, %ax
	movw	%ax, %ds
	movw	%ax, %es
	ret
end;
{$else}
procedure	isr_enter;
begin
end;
{$endif}

{ the exit procedures, the last given first }
procedure	run_exits;
var	i	: longint;
begin
{$ifndef FPC}
	ExitProcedure := old_exit;
{$endif}
	for i := exit_n - 1 downto 0 do exits[i];
	exit_n := 0;
end;

procedure	on_exit(p: EXIT_PROC);
begin
	if exit_n > high(exits) then exit;
	if exit_n = 0 then
{$ifdef FPC}
		AddExitProc(@run_exits);
{$else}
	begin
		old_exit := ExitProcedure;
		ExitProcedure := run_exits;
	end;
{$endif}
	exits[exit_n] := p;
	inc(exit_n);
end;

begin
	vec_n := 0;
	exit_n := 0;
end.
