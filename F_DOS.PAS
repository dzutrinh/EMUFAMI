{*+
	F_DOS.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	What TMT Pascal (DOS/4GW, flat), Free Pascal (go32v2 on a DPMI
	host) and Borland Pascal 7 (16-bit protected mode, RTM) do
	differently: memory below 1 MB, a block of it, a real-mode BIOS
	call, an interrupt's vector, the program's end.  isr_enter:
	under FPC four instructions load the data segment an interrupt
	may come without - the only assembly in EMUFAMI.
-*}
{$X+}
{$ifdef VER70}{$F+}{$endif}
{$S-}		{ no stack check: block_put runs in an interrupt }
unit	f_dos;

interface

type
	EXIT_PROC	= procedure;

{ conventional memory, by linear address (not from an interrupt) }
procedure	low_put(linear: longint; var src; n: longint);
procedure	low_get(linear: longint; var dst; n: longint);
{ a block of n bytes below 1 MB: its linear address (0: none), handle
  for block_put and low_free }
function	low_alloc(n: longint; var handle: longint): longint;
procedure	low_free(handle: longint);
{ n bytes into such a block at offset ofs (safe in an interrupt) }
procedure	block_put(handle, linear, ofs: longint; var src; n: longint);
{ a BIOS interrupt run in real mode: AX and BX in; AX, BX and the
  ES:BP it may return out }
procedure	real_int(intno: longint; var ax, bx, es, bp: longint);
{ a protected-mode interrupt vector: handler in, the old kept; the code
  from code_from to code_to (what the handler runs) kept in memory }
procedure	vec_take(vec: longint; handler, code_from, code_to: pointer);
procedure	vec_give(vec: longint);
{ data an interrupt handler uses kept in memory (FPC: locked against the
  DPMI host's paging) }
procedure	lock_mem(var data; n: longint);
procedure	isr_enter;
procedure	on_exit(p: EXIT_PROC);		{ run when the program ends }

implementation

{$ifdef FPC}
uses	f_sys, go32;
{$else}
{$ifdef VER70}
uses	f_sys, dos, winapi;
{$else}
uses	f_sys, dos, dpmi;
{$endif}
{$endif}

const
	VEC_MAX	= 4;

var	{ the vectors taken: their numbers and old handlers }
	vec_n	: longint;
	vec_no	: array[0 .. VEC_MAX - 1] of longint;
{$ifdef FPC}
	vec_old	: array[0 .. VEC_MAX - 1] of tseginfo;
	{ the program's data segment, kept by FPC's startup code }
	ds_alias	: word; external name '___v2prt0_ds_alias';
{$else}
{$ifdef VER70}
	vec_old	: array[0 .. VEC_MAX - 1] of pointer;
	old_exit	: pointer;
	low_sel	: word;		{ a selector moved to the address wanted }
{$else}
	vec_old	: array[0 .. VEC_MAX - 1] of FarPointer;
	old_exit: procedure;
{$endif}
{$endif}
	exits	: array[0 .. 7] of EXIT_PROC;
	exit_n	: longint;

{$ifdef VER70}
{ BP7: a selector whose base is linear, n bytes long }
function	low_ptr(linear, n: longint): pointer;
begin
	if low_sel = 0 then low_sel := AllocSelector(DSeg);
	SetSelectorBase(low_sel, linear);
	SetSelectorLimit(low_sel, n - 1);
	low_ptr := ptr(low_sel, 0);
end;
{$endif}

procedure	low_put(linear: longint; var src; n: longint);
begin
{$ifdef FPC}
	dosmemput(linear shr 4, linear and 15, src, n);
{$else}
{$ifdef VER70}
	move(src, low_ptr(linear, n)^, n);
{$else}
	move(src, pointer(linear)^, n);
{$endif}
{$endif}
end;

procedure	low_get(linear: longint; var dst; n: longint);
begin
{$ifdef FPC}
	dosmemget(linear shr 4, linear and 15, dst, n);
{$else}
{$ifdef VER70}
	move(low_ptr(linear, n)^, dst, n);
{$else}
	move(pointer(linear)^, dst, n);
{$endif}
{$endif}
end;

procedure	block_put(handle, linear, ofs: longint; var src; n: longint);
begin
{$ifdef FPC}
	dosmemput((linear + ofs) shr 4, (linear + ofs) and 15, src, n);
{$else}
{$ifdef VER70}
	move(src, ptr(handle, ofs)^, n);
{$else}
	move(src, pointer(linear + ofs)^, n);
{$endif}
{$endif}
end;

function	low_alloc(n: longint; var handle: longint): longint;
var	r	: longint;
begin
{$ifdef FPC}
	r := global_dos_alloc(n);
{$else}
{$ifdef VER70}
	r := GlobalDosAlloc(n);
{$else}
	r := AllocDOSmemoryBlock(n);
{$endif}
{$endif}
	handle := r and $FFFF;		{ the selector }
	if r = 0 then low_alloc := 0
	else
		low_alloc := (r shr 16) * 16;	{ the real-mode segment's address }
end;

procedure	low_free(handle: longint);
begin
{$ifdef FPC}
	global_dos_free(handle);
{$else}
{$ifdef VER70}
	GlobalDosFree(handle);
{$else}
	FreeDOSMemoryBlock(handle);
{$endif}
{$endif}
end;

{$ifdef VER70}
{ the DPMI host's "simulate a real-mode interrupt" (0300h) takes these }
type
	RM_REGS	= record
		edi, esi, ebp, reserved, ebx, edx, ecx, eax	: longint;
		flags, es, ds, fs, gs, ip, cs, sp, ss		: word;
	end;
{$endif}

procedure	real_int(intno: longint; var ax, bx, es, bp: longint);
{$ifdef FPC}
var	r	: trealregs;
{$else}
var	r	: registers;
{$endif}
{$ifdef VER70}
	rm	: RM_REGS;
{$endif}
begin
	fillchar(r, sizeof(r), 0);
{$ifdef VER70}
	fillchar(rm, sizeof(rm), 0);
	rm.eax := ax;
	rm.ebx := bx;
	r.ax := $0300;
	r.bx := intno;
	r.cx := 0;
	r.es := seg(rm);
	r.di := ofs(rm);
	intr($31, r);
	ax := rm.eax and $FFFF;
	bx := rm.ebx and $FFFF;
	es := rm.es;
	bp := rm.ebp and $FFFF;
{$else}
	r.ax := ax;
	r.bx := bx;
{$ifdef FPC}
	realintr(intno, r);
{$else}
	intr(intno, r);
{$endif}
	ax := r.ax;
	bx := r.bx;
	es := r.es;
	bp := r.bp;
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
	lock_code(code_from, PBYTE(code_to) - PBYTE(code_from));
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
{$ifdef VER70}
	ExitProc := old_exit;
{$else}
{$ifndef FPC}
	ExitProcedure := old_exit;
{$endif}
{$endif}
	for i := exit_n - 1 downto 0 do exits[i];
	exit_n := 0;
end;

procedure	on_exit(p: EXIT_PROC);
begin
	if exit_n > high(exits) then exit;
	if exit_n = 0 then
	begin
{$ifdef FPC}
		AddExitProc(@run_exits);
{$else}
{$ifdef VER70}
		old_exit := ExitProc;
		ExitProc := @run_exits;
{$else}
		old_exit := ExitProcedure;
		ExitProcedure := run_exits;
{$endif}
{$endif}
	end;
	exits[exit_n] := p;
	inc(exit_n);
end;

begin
	vec_n := 0;
	exit_n := 0;
{$ifdef VER70}
	low_sel := 0;
{$endif}
end.
