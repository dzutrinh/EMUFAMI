{*+
	F_SYS.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	What the units share: a byte pointer and a pointer as a number,
	memory that knows its size (malloc, free), numbers as text.
-*}
unit	f_sys;

interface

type	PBYTE	= ^byte;
	{ a pointer as a number, for the arithmetic (TMT and FPC alike) }
{$ifdef FPC}
	PTRVAL	= ptruint;
{$else}
	PTRVAL	= longint;
{$endif}

function	malloc(size: longint): pointer;	{ nil when there is not enough }
procedure	free(var p: pointer);		{ and p made nil }
function	itoa(n: longint): string;
function	uppercase(const s: string): string;

implementation

function	malloc(size: longint): pointer;
var	p	: pointer;
begin
	size := (size + 4 + 3) and not 3;
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
	malloc := PBYTE(p) + 4;
end;

procedure	free(var p: pointer);
var	size	: longint;
begin
	if p = nil then exit;
	p := PBYTE(p) - 4;
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
