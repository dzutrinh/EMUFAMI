{*+
	F_SB.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	Sound Blaster: BLASTER's A, I, D; 8-bit mono DMA at 22,222 Hz,
	the two halves round and round (DSP 2.01 up) or block by block;
	the interrupt fills the half just played from a ring the frames
	fill (sb_put).  No card, no sound (sb_why says why).
-*}
{$X+}
unit	f_sb;

interface

var	sb_rate		: longint;	{ the card's samples a second, when on }

function	sb_start(rate: longint): boolean;	{ FALSE: no sound }
procedure	sb_stop;
function	sb_why: string;			{ the card found, or why none }
procedure	sb_put(p: pointer; n: longint);	{ n 16-bit samples queued }
function	sb_queued: longint;		{ samples waiting in the ring }

implementation

uses	dos, f_sys, f_dos;

const	RING	= 8192;			{ samples, a power of 2 }
	HALF	= 256;			{ samples a DMA half }
	DMA_ADDR	: array[0 .. 3] of byte = ($00, $02, $04, $06);
	DMA_COUNT	: array[0 .. 3] of byte = ($01, $03, $05, $07);
	DMA_PAGE	: array[0 .. 3] of byte = ($87, $83, $81, $82);

var	base, irq, dma		: longint;
	major, minor		: longint;
	auto			: boolean;
	ring_buf		: array[0 .. RING - 1] of byte;
	ring_head, ring_tail	: longint;	{ the card reads at head, sb_put writes at tail }
	last			: byte;
	half_buf		: array[0 .. HALF - 1] of byte;	{ a half made, then copied below 1 MB }
	phys, sel		: longint;	{ the DMA buffer: its linear address, its handle }
	vec			: longint;
	was_masked		: boolean;
	on, ready, hooked	: boolean;
	why			: string;

function	inb(p: longint): longint;
begin
	inb := port[p];
end;

procedure	outb(p, v: longint);
begin
	port[p] := v;
end;

function	dsp_write(v: longint): boolean;
var	i	: longint;
begin
	dsp_write := FALSE;
	for i := 1 to 200000 do
		if inb(base + $C) and $80 = 0 then
		begin
			outb(base + $C, v);
			dsp_write := TRUE;
			exit;
		end;
end;

function	dsp_read: longint;
var	i	: longint;
begin
	dsp_read := -1;
	for i := 1 to 200000 do
		if inb(base + $E) and $80 <> 0 then
		begin
			dsp_read := inb(base + $A);
			exit;
		end;
end;

function	dsp_reset: boolean;
var	i	: longint;
begin
	dsp_reset := FALSE;
	outb(base + 6, 1);
	for i := 1 to 2000 do inb(base + 6);
	outb(base + 6, 0);
	for i := 1 to 50 do
		if dsp_read = $AA then
		begin
			dsp_reset := TRUE;
			exit;
		end;
end;

{ the number after letter in BLASTER, hex or decimal }
function	blaster(const env: string; letter: char; hex: boolean; var v: longint): boolean;
var	i, d	: longint;
	c	: char;
begin
	blaster := FALSE;
	i := 1;
	while i <= length(env) do
	begin
		if ((i = 1) or (env[i - 1] = ' ')) and (upcase(env[i]) = letter) then
		begin
			v := 0;
			inc(i);
			while (i <= length(env)) and (env[i] <> ' ') do
			begin
				c := upcase(env[i]);
				if (c >= '0') and (c <= '9') then d := ord(c) - 48
				else if hex and (c >= 'A') and (c <= 'F') then d := ord(c) - 55
				else	exit;
				if hex then v := v * 16 + d else v := v * 10 + d;
				inc(i);
			end;
			blaster := TRUE;
			exit;
		end;
		inc(i);
	end;
end;

function	hex3(v: longint): string;
const	DIGITS	: string[16] = '0123456789ABCDEF';
begin
	hex3 := DIGITS[(v shr 8) and 15 + 1] + DIGITS[(v shr 4) and 15 + 1] + DIGITS[v and 15 + 1];
end;

function	sb_why: string;
begin
	sb_why := why;
end;

function	sb_queued: longint;
begin
	sb_queued := (ring_tail - ring_head) and (RING - 1);
end;

procedure	sb_put(p: pointer; n: longint);
var	i, t	: longint;
	s	: ^smallint;
begin
	if not on then exit;
	s := p;
	t := ring_tail;
	for i := 1 to n do
	begin
		{ full: the rest dropped }
		if ((t + 1) and (RING - 1)) = ring_head then break;
		ring_buf[t] := ((s^ shr 8) + 128) and $FF;
		t := (t + 1) and (RING - 1);
		inc(s);
	end;
	ring_tail := t;
end;

{ HALF samples from the ring into half h of the DMA buffer }
procedure	fill(h: longint);
var	i, k	: longint;
begin
	k := ring_head;
	for i := 0 to HALF - 1 do
	begin
		if k <> ring_tail then
		begin
			last := ring_buf[k];
			k := (k + 1) and (RING - 1);
		end;
		half_buf[i] := last;
	end;
	ring_head := k;
	low_put(phys + h * HALF, half_buf, HALF);
end;

procedure	dma_program(bytes: longint; loop: boolean);
begin
	outb($0A, dma or 4);
	outb($0C, 0);
	if loop then outb($0B, $58 or dma) else outb($0B, $48 or dma);
	outb(DMA_ADDR[dma], phys and $FF);
	outb(DMA_ADDR[dma], (phys shr 8) and $FF);
	outb(DMA_COUNT[dma], (bytes - 1) and $FF);
	outb(DMA_COUNT[dma], (bytes - 1) shr 8);
	outb(DMA_PAGE[dma], phys shr 16);
	outb($0A, dma);
end;

{ the bytes of the buffer the DMA has played }
function	dma_position: longint;
var	lo, hi	: longint;
begin
	outb($0C, 0);
	lo := inb(DMA_COUNT[dma]);
	hi := inb(DMA_COUNT[dma]);
	dma_position := 2 * HALF - (((hi shl 8) or lo) + 1);
end;

{ one block (the cards before DSP 2.01) }
procedure	single;
begin
	dma_program(HALF, FALSE);
	dsp_write($14);
	dsp_write((HALF - 1) and $FF);
	dsp_write((HALF - 1) shr 8);
end;

procedure	eoi;
begin
	if irq >= 8 then outb($A0, $20);
	outb($20, $20);
end;

{$S-}	{ the interrupt runs on the extender's stack }
{$ifdef FPC}
procedure	sb_isr; interrupt;
{$else}
procedure	sb_isr(eax, ebx, ecx, edx, esi, edi: dword); interrupt;
{$endif}
begin
	isr_enter;
	inb(base + $E);			{ the card's interrupt taken }
	if ready then
		if auto then
		begin
			{ the half the DMA is not in is the one just played }
			if dma_position < HALF then fill(1) else fill(0);
		end
		else
		begin
			fill(0);
			single;
		end;
	eoi;
end;

procedure	sb_isr_end;
begin
end;
{$S+}

procedure	pic_line(var p, bit: longint);
begin
	if irq >= 8 then
	begin
		p := $A1;
		bit := 1 shl (irq - 8);
	end
	else
	begin
		p := $21;
		bit := 1 shl irq;
	end;
end;

procedure	mask(remember: boolean);
var	p, bit	: longint;
begin
	pic_line(p, bit);
	if remember then was_masked := inb(p) and bit <> 0;
	outb(p, inb(p) or bit);
end;

procedure	unmask;
var	p, bit	: longint;
begin
	inb(base + $E);
	pic_line(p, bit);
	outb(p, inb(p) and not bit);
end;

{ memory below 1 MB for the DMA, not across a 64 KB boundary: a block
  that would cross is let go, the space up to the boundary taken, and
  asked for again }
function	dos_buffer(bytes: longint): boolean;
var	pad_sel	: longint;
begin
	dos_buffer := FALSE;
	phys := low_alloc(bytes, sel);
	if phys = 0 then exit;
	if (phys and $FFFF) + bytes > $10000 then
	begin
		low_free(sel);
		low_alloc($10000 - phys and $FFFF, pad_sel);
		phys := low_alloc(bytes, sel);
		low_free(pad_sel);
		if phys = 0 then exit;
		if (phys and $FFFF) + bytes > $10000 then
		begin
			low_free(sel);
			exit;
		end;
	end;
	dos_buffer := TRUE;
end;

procedure	sb_stop;
begin
	if not on then exit;
	ready := FALSE;
	if auto then dsp_write($DA);
	dsp_reset;
	outb($0A, dma or 4);
	{ the line shut while the vector goes back, then as it was }
	mask(FALSE);
	vec_give(vec);
	if not was_masked then unmask;
	dsp_write($D3);
	low_free(sel);
	on := FALSE;
end;

procedure	sb_exit;
begin
	sb_stop;
end;

function	sb_start(rate: longint): boolean;
var	env	: string;
	tc	: longint;
begin
	sb_start := FALSE;
	if on then exit;
	env := GetEnv('BLASTER');
	if env = '' then
	begin
		why := 'NO BLASTER VARIABLE';
		exit;
	end;
	if not blaster(env, 'A', TRUE, base) or not blaster(env, 'I', FALSE, irq) or not blaster(env, 'D', FALSE, dma)
	or (irq < 2) or (irq > 15) or (dma < 0) or (dma > 3) then
	begin
		why := 'BLASTER WITHOUT A, I, D';
		exit;
	end;
	if not dsp_reset or not dsp_write($E1) then
	begin
		why := 'NO SOUND BLASTER AT ' + itoa(base);
		exit;
	end;
	major := dsp_read;
	minor := dsp_read;
	if major < 1 then
	begin
		why := 'NO SOUND BLASTER ANSWER';
		exit;
	end;
	auto := (major > 2) or ((major = 2) and (minor > 0));
	if rate > 22050 then rate := 22050;
	if rate < 8000 then rate := 8000;
	tc := 256 - 1000000 div rate;
	sb_rate := 1000000 div (256 - tc);
	if not dos_buffer(2 * HALF) then
	begin
		why := 'NO DOS MEMORY FOR SOUND';
		exit;
	end;
	fillchar(half_buf, HALF, 128);
	low_put(phys, half_buf, HALF);
	low_put(phys + HALF, half_buf, HALF);
	ring_head := 0;
	ring_tail := 0;
	last := 128;
	if irq >= 8 then vec := $70 + irq - 8 else vec := 8 + irq;
	if not hooked then on_exit({$ifdef FPC}@{$endif}sb_exit);
	hooked := TRUE;
	ready := FALSE;
	{ the line shut while the vector changes, as every driver does }
	mask(TRUE);
	lock_mem(ring_buf, sizeof(ring_buf));
	lock_mem(half_buf, sizeof(half_buf));
	lock_mem(ring_head, sizeof(ring_head));
	lock_mem(ring_tail, sizeof(ring_tail));
	lock_mem(last, sizeof(last));
	lock_mem(base, sizeof(base));
	lock_mem(irq, sizeof(irq));
	lock_mem(dma, sizeof(dma));
	lock_mem(phys, sizeof(phys));
	lock_mem(auto, sizeof(auto));
	lock_mem(ready, sizeof(ready));
	vec_take(vec, @sb_isr, @inb, @sb_isr_end);
	on := TRUE;
	dsp_write($D1);			{ the speaker on }
	dsp_write($40);
	dsp_write(tc);
	if auto then
	begin
		dma_program(2 * HALF, TRUE);
		unmask;
		ready := TRUE;
		dsp_write($48);
		dsp_write((HALF - 1) and $FF);
		dsp_write((HALF - 1) shr 8);
		dsp_write($1C);
	end
	else
	begin
		single;
		unmask;
		ready := TRUE;
	end;
	why := 'SB ' + itoa(major) + '.' + itoa(minor div 10) + itoa(minor mod 10) + ' A' + hex3(base) + ' I' + itoa(irq) + ' D' + itoa(dma);
	sb_start := TRUE;
end;

begin
	on := FALSE;
	hooked := FALSE;
	ready := FALSE;
	sb_rate := 0;
	why := 'NO SOUND';
end.
