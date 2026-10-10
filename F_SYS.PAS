{*+
	F_SYS.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	What the units share, alike for TMT, FPC and BP7 (16-bit
	protected mode: a block at most 64 KB, pointers selector and
	offset): a byte pointer, bytes in a row to index (BYTES), a
	pointer moved n bytes (padd), memory that knows its size
	(malloc, free), numbers as text; U16, a 16-bit number in the
	type each compiler works on fastest.
-*}
{$S-}		{ no stack check at every call }
unit	f_sys;

interface

type
	PBYTE	= ^byte;
	BYTES	= array[0 .. 65519] of byte;	{ a block's bytes, indexed }
	PBYTES	= ^BYTES;
{$ifdef VER70}
	smallint	= integer;
	RWCOUNT		= word;		{ blockread's count }
	U16			= word;		{ BP7's code is 16-bit: a word is one register }
{$else}
	RWCOUNT		= longint;
	U16			= longint;	{ 32-bit code: a longint is }
{$endif}

const
	BLOCK_MAX	= 65520;	{ the largest block every compiler gives }

{ p moved n bytes (BP7: in its segment, the offset going round 64 KB) }
function	padd(p: pointer; n: longint): PBYTE;
function	malloc(size: longint): pointer;	{ nil when there is not enough }
procedure	free(var p: pointer);		{ and p made nil }
function	itoa(n: longint): string;
function	uppercase(const s: string): string;

implementation

function	padd(p: pointer; n: longint): PBYTE;
begin
{$ifdef VER70}
	padd := ptr(seg(PBYTE(p)^), word(ofs(PBYTE(p)^) + n));
{$else}
	padd := PBYTE(p) + n;
{$endif}
end;

function	malloc(size: longint): pointer;
var	p	: pointer;
begin
	size := (size + 4 + 3) and not 3;
	if size > BLOCK_MAX then
	begin
		malloc := nil;
		exit;
	end;
{$ifndef FPC}
	if maxavail < size then
	begin
		malloc := nil;
		exit;
	end;
{$endif}
	getmem(p, size);		{ FPC: nil when the heap cannot grow (below) }
	if p = nil then
	begin
		malloc := nil;
		exit;
	end;
	move(size, p^, 4);
	malloc := padd(p, 4);
end;

procedure	free(var p: pointer);
var	size	: longint;
begin
	if p = nil then exit;
	p := padd(p, -4);
	move(p^, size, 4);
	freemem(p, size);
	p := nil;
end;

function	itoa(n: longint): string;
var	s	: string;
begin
	str(n, s);
	itoa := s;
end;

function	uppercase(const s: string): string;
var	t	: string;
	i	: longint;
begin
	t := s;
	for i := 1 to length(t) do t[i] := upcase(t[i]);
	uppercase := t;
end;

begin
{$ifdef FPC}
	ReturnNilIfGrowHeapFails := TRUE;
{$endif}
end.
