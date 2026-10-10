{*+
	F_APU.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	The 2A03's APU: two pulses, the triangle, noise, the DMC (its
	fetches stall the CPU), the frame counter (4 and 5 steps, IRQ)
	and length counters.  Sound: each channel's level summed over a
	sample's CPU cycles (a box filter) from its changes of level, the
	NES's nonlinear mixer by table, a 30 Hz high pass, 16-bit samples
	into apu_samples.
-*}
{$X+}
{$ifdef VER70}{$N+}{$E+}{$endif}
{$S-}		{ no stack check at every call }
unit	f_apu;

interface

uses	f_sys;

const
	APU_MAX_SAMPLES	= 4096;
	APU_NEVER	= $7FFFFFFF;

type
	APU_READ_PROC	= function(addr: longint): longint;

var	apu_samples	: array[0 .. APU_MAX_SAMPLES - 1] of smallint;
	apu_count	: longint;		{ samples waiting in apu_samples }
	apu_stall	: longint;		{ CPU cycles the DMC's fetches took, for the CPU to add }
	apu_dmc_read: APU_READ_PROC;{ how the DMC reads CPU memory }
	apu_pal		: boolean;		{ set before apu_power: PAL's clock and tables }
	apu_dendy	: boolean;		{ or Dendy's clock with NTSC's tables }

procedure	apu_start;			{ the mixer's tables made (else by apu_audio) }
procedure	apu_power;
procedure	apu_reset(at: longint);				{ the reset button: $4015 cleared, $4017 again }
procedure	apu_run(at: longint);
function	apu_next: longint;
function	apu_irq_at: longint;				{ the cycle the IRQ line went high, or APU_NEVER }
function	apu_read(addr, at: longint): longint;	{ $4015; -1 for the others }
procedure	apu_write(addr, v, at: longint);	{ $4000-$4013, $4015, $4017 }
procedure	apu_rebase(k: longint);
{ sound at rate samples a second, 0 for none }
procedure	apu_audio(rate: longint);
{ a sample's length in CPU cycles, 16.16, nudged by the player for pacing }
function	apu_sample_cycles: longint;
procedure	apu_set_sample_cycles(c: longint);

implementation

const
	HZ_NTSC	= 1789773;
	HZ_PAL	= 1662607;
	LENGTHS		: array[0 .. 31] of byte = (
		10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
		12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30);
	STEP4_NTSC	: array[0 .. 5] of longint = (7457, 14913, 22371, 29828, 29829, 29830);
	STEP5_NTSC	: array[0 .. 5] of longint = (7457, 14913, 22371, 29829, 37281, 37282);
	STEP4_PAL	: array[0 .. 5] of longint = (8313, 16627, 24939, 33252, 33253, 33254);
	STEP5_PAL	: array[0 .. 5] of longint = (8313, 16627, 24939, 33253, 41565, 41566);
	DUTY	: array[0 .. 3, 0 .. 7] of byte = (
		(0, 1, 0, 0, 0, 0, 0, 0),
		(0, 1, 1, 0, 0, 0, 0, 0),
		(0, 1, 1, 1, 1, 0, 0, 0),
		(1, 0, 0, 1, 1, 1, 1, 1));
	TRI_SEQ		: array[0 .. 31] of byte = (
		15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
		0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);
	NOISE_NTSC	: array[0 .. 15] of longint = (
		4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068);
	DMC_NTSC	: array[0 .. 15] of longint = (
		428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54);
	NOISE_PAL	: array[0 .. 15] of longint = (
		4, 8, 14, 30, 60, 88, 118, 148, 188, 236, 354, 472, 708, 944, 1890, 3778);
	DMC_PAL		: array[0 .. 15] of longint = (
		398, 354, 316, 298, 276, 236, 210, 198, 176, 148, 132, 118, 98, 78, 66, 50);

{ the region's, made by apu_power }
var
	CPU_HZ		: longint;
	STEP4, STEP5: array[0 .. 5] of longint;
	NOISE_PERIOD: array[0 .. 15] of longint;
	DMC_PERIOD	: array[0 .. 15] of longint;

type
	ENVELOPE	= record
		start,
		loop,
 		constant: boolean;
		volume,
		divider,
		decay	: longint;
	end;

	PULSE	= record
		duty,
		step,
		period		: longint;
		len			: longint;
		halt		: boolean;	{ the envelope's loop too }
		env			: ENVELOPE;
		sw_on,
		sw_neg,
		sw_reload	: boolean;
		sw_period,
		sw_shift,
		sw_div		: longint;
		ones		: longint;	{ pulse 1 negates with one's complement }
		next,
		at,
		acc			: longint;	{ the timer; acc unused since 0.9 }
	end;

	TRIANGLE	= record
		period,
		step,
		len			: longint;
		control,
		lin_reload	: boolean;
		lin_value,
		lin			: longint;
		next,
		at,
		acc			: longint;
	end;

	NOISE	= record
		period,
		lfsr,
		len		: longint;
		mode,
		halt	: boolean;
		env		: ENVELOPE;
		next,
		at,
		acc		: longint;
	end;

	DELTA	= record
		irq_on, loop	: boolean;
		rate			: longint;
		level			: longint;
		start_addr,
		start_len		: longint;
		addr, left		: longint;	{ bytes left to fetch }
		buffer			: longint;
		full			: boolean;	{ the buffer holds a byte }
		shift, bits		: longint;
		silent			: boolean;
		irq				: boolean;
		irq_time		: longint;
		next, at, acc	: longint;
	end;

var
	p1, p2		: PULSE;
	tri			: TRIANGLE;
	noi			: NOISE;
	dmc			: DELTA;
	enabled		: longint;	{ $4015's low four bits }
	frame_irq	: boolean;
	frame_irq_time	: longint;
	seq_start	: longint;
	step		: longint;
	five		: boolean;
	inhibit		: boolean;
	reset_at	: longint;
	reset_five	: boolean;
	last_4017	: longint;
	{ length writes made as the counters are clocked (the cycle before
	  the clock is seen): a halt change waits for the clock, a reload of
	  a running counter is lost, one of a stopped counter is not clocked }
	halt_after	: array[0 .. 3] of longint;	{ -1, or the halt to set after }
	no_clock	: array[0 .. 3] of boolean;
	audio		: boolean;
	smp_cycles	: longint;	{ 16.16 }
	smp_start	: longint;
	smp_end		: longint;
	smp_frac	: longint;
	hp_in, hp_out	: longint;
	PULSE_T		: array[0 .. 31] of longint;	{ 0..65535 }
	ZEROS		: array[0 .. 255] of byte;	{ the clear bits of a byte }
	TND_T		: array[0 .. 203] of longint;

{ ---- the units that shape the channels ---- }

procedure	envelope_clock(var e: ENVELOPE);
begin
	if e.start then
	begin
		e.start := FALSE;
		e.decay := 15;
		e.divider := e.volume;
	end
	else if e.divider = 0 then
	begin
		e.divider := e.volume;
		if e.decay > 0 then dec(e.decay)
		else if e.loop then e.decay := 15;
	end
	else
		dec(e.divider);
end;

function	envelope_out(const e: ENVELOPE): longint;
begin
	if e.constant then envelope_out := e.volume else envelope_out := e.decay;
end;

function	sweep_target(const p: PULSE): longint;
var	c	: longint;
begin
	c := p.period shr p.sw_shift;
	if p.sw_neg then
		sweep_target := p.period - c - p.ones
	else
		sweep_target := p.period + c;
end;

function	pulse_muted(const p: PULSE): boolean;
begin
	pulse_muted := (p.period < 8) or (sweep_target(p) > $7FF);
end;

procedure	sweep_clock(var p: PULSE);
var	t	: longint;
begin
	if (p.sw_div = 0) and p.sw_on and (p.sw_shift > 0) and not pulse_muted(p) then
	begin
		t := sweep_target(p);
		if t >= 0 then p.period := t;
	end;
	if (p.sw_div = 0) or p.sw_reload then
	begin
		p.sw_div := p.sw_period;
		p.sw_reload := FALSE;
	end
	else
		dec(p.sw_div);
end;

procedure	quarter;
begin
	envelope_clock(p1.env);
	envelope_clock(p2.env);
	envelope_clock(noi.env);
	if tri.lin_reload then tri.lin := tri.lin_value
	else if tri.lin > 0 then dec(tri.lin);
	if not tri.control then tri.lin_reload := FALSE;
end;

procedure	half;
var	i	: longint;
begin
	if (p1.len > 0) and not p1.halt and not no_clock[0] then dec(p1.len);
	if (p2.len > 0) and not p2.halt and not no_clock[1] then dec(p2.len);
	if (tri.len > 0) and not tri.control and not no_clock[2] then dec(tri.len);
	if (noi.len > 0) and not noi.halt and not no_clock[3] then dec(noi.len);
	sweep_clock(p1);
	sweep_clock(p2);
	for i := 0 to 3 do
	begin
		no_clock[i] := FALSE;
		if halt_after[i] >= 0 then
		begin
			case i of
			0:	p1.halt := halt_after[i] <> 0;
			1:	p2.halt := halt_after[i] <> 0;
			2:	tri.control := halt_after[i] <> 0;
			3:	noi.halt := halt_after[i] <> 0;
			end;
			halt_after[i] := -1;
		end;
	end;
end;

{ ---- the channels ---- }

{ the noise's steps up to t: the level (vol while bit 0 of the shift
  register is clear) summed, the register shifted with the feedback of
  bit 0 and bit tap; short periods take thousands of steps a frame.
  Eight whole steps at once where they fit: their outputs are the low
  byte's bits (ZEROS counts the clear ones), the eight feedback bits
  the low byte of lfsr xor (lfsr shr tap), as tap + 7 < 15 }
procedure	noise_steps(t, vol, tap: longint);
var	lfsr, nx, at, e, fb	: longint;
begin
	lfsr := noi.lfsr;
	nx := noi.next;
	at := noi.at;
	while nx <= t do
	begin
		e := nx + noi.period * 7;
		if (at + noi.period = nx) and (e <= t) then
		begin
			{ eight steps: the clear bits of the low byte at the level }
			inc(noi.acc, ZEROS[lfsr and $FF] * noi.period * vol);
			fb := ((lfsr shr tap) xor lfsr) and $FF;
			lfsr := (lfsr shr 8) or fb shl 7;
			at := e;
			nx := e + noi.period;
		end
		else
		begin
			{ one step }
			if lfsr and 1 = 0 then inc(noi.acc, (nx - at) * vol);
			at := nx;
			fb := ((lfsr shr tap) xor lfsr) and 1;
			lfsr := (lfsr shr 1) or fb shl 14;
			inc(nx, noi.period);
		end;
	end;
	noi.lfsr := lfsr;
	noi.next := nx;
	noi.at := at;
end;

{ the DMC's memory reader: a byte into the empty buffer }
procedure	dmc_fetch(t: longint);
begin
	with dmc do
	begin
		if full or (left = 0) then exit;
		buffer := apu_dmc_read(addr);
		full := TRUE;
		inc(apu_stall, 4);
		if addr = $FFFF then addr := $8000 else inc(addr);
		dec(left);
		if left = 0 then
			if loop then
			begin
				addr := start_addr;
				left := start_len;
			end
			else if irq_on and not irq then
			begin
				irq := TRUE;
				irq_time := t;
			end;
	end;
end;

procedure	dmc_run(t: longint);
var	n	: longint;
begin
	with dmc do
	begin
		if silent and not full and (left = 0) then
		begin
			{ nothing to play or fetch: the clocks skipped at once }
			inc(acc, level * (t - at));
			at := t;
			if next <= t then
			begin
				n := (t - next) div DMC_PERIOD[rate] + 1;
				inc(next, n * DMC_PERIOD[rate]);
				bits := bits - n mod 8;
				if bits <= 0 then inc(bits, 8);
			end;
			exit;
		end;
		while next <= t do
		begin
			inc(acc, level * (next - at));
			at := next;
			if not silent then
			begin
				if shift and 1 <> 0 then
				begin
					if level <= 125 then inc(level, 2);
				end
				else if level >= 2 then dec(level, 2);
				shift := shift shr 1;
			end;
			dec(bits);
			if bits = 0 then
			begin
				bits := 8;
				if full then
				begin
					silent := FALSE;
					shift := buffer;
					full := FALSE;
					dmc_fetch(next);
				end
				else	silent := TRUE;
			end;
			inc(next, DMC_PERIOD[rate]);
		end;
		inc(acc, level * (t - at));
		at := t;
	end;
end;

{ ---- the mixer ---- }

{ a batch: the samples that end by t, between two frame counter events
  or writes.  Each channel puts a change of its level, at the cycle it
  comes, into the sample it falls in (put_p, put_t): X the change times
  the cycles left in that sample, D the change.  A sample's sum of
  level by cycles is then L * its cycles + X, L the level it began
  with (the sum of the D before): the box filter as summing every step
  made it, the work now by changes, not by samples and channels.  Two
  groups, as the NES's mixer: the pulses (P) and the triangle x 3, the
  noise x 2 and the DMC (T).  The noise, mostly faster than the
  samples, keeps its sums per sample (AN).  What mutes a channel or sets
  its volume holds over a batch: found once (prepare). }
const	MIX_MAX	= 512;

type	LV8	= array[0 .. 7] of longint;
	PLV8	= ^LV8;
	LEVELS	= array[0 .. 31] of longint;	{ a channel's level by step }
	PLEVELS	= ^LEVELS;
	SUMS	= array[0 .. MIX_MAX] of longint;
	PSUMS	= ^SUMS;

var	ends			: array[0 .. MIX_MAX] of longint;	{ the samples' ends; the last open }
	XP, DP, XT, DT	: array[0 .. MIX_MAX] of longint;
	AN				: array[0 .. MIX_MAX] of longint;	{ the noise's sums }
	lp, lt			: longint;	{ the groups' levels at the open sample's start }
	p1_out, p2_out	: longint;	{ the level each channel put in }
	tri_out, dmc_out: longint;	{ x 3, x 1 }
	dk				: longint;	{ the sample of the channel's last change }
	{ steps_to's channel: its timer, step (and mask), level by step }
	ch_next, ch_step,
	ch_mask, ch_len,
	ch_out			: longint;
	ch_lv			: PLEVELS;
	ch_x, ch_d		: PSUMS;
	PL1, PL2		: LV8;		{ a pulse's levels: duty x volume }
	TRI3			: LEVELS;	{ the triangle's x 3 }
	p1_go, p2_go,
	tri_go, noi_go	: longint;	{ 0 or 1 }
	prep_dirty		: boolean;
	p1_vol, p2_vol,
	noi_vol			: longint;
	p1_len, p2_len,
	tri_len			: longint;	{ timer steps in cycles }
	noi_tap			: longint;

{ again only after a write or a frame counter event (prep_dirty) }
procedure	prepare;
var	i	: longint;
begin
	if not prep_dirty then exit;
	prep_dirty := FALSE;
	p1_go := ord((p1.len > 0) and not pulse_muted(p1));
	p1_vol := envelope_out(p1.env);
	p1_len := (p1.period + 1) * 2;
	p2_go := ord((p2.len > 0) and not pulse_muted(p2));
	p2_vol := envelope_out(p2.env);
	p2_len := (p2.period + 1) * 2;
	tri_go := ord((tri.len > 0) and (tri.lin > 0) and (tri.period >= 2));
	tri_len := tri.period + 1;
	noi_go := ord(noi.len > 0);
	noi_vol := envelope_out(noi.env);
	if noi.mode then noi_tap := 6 else noi_tap := 1;
	for i := 0 to 7 do
	begin
		PL1[i] := DUTY[p1.duty][i] * p1_vol;
		PL2[i] := DUTY[p2.duty][i] * p2_vol;
	end;
end;

procedure	put_p(d, x: longint);
begin
	while ends[dk] <= x do inc(dk);
	inc(XP[dk], d * (ends[dk] - x));
	inc(DP[dk], d);
end;

procedure	put_t(d, x: longint);
begin
	while ends[dk] <= x do inc(dk);
	inc(XT[dk], d * (ends[dk] - x));
	inc(DT[dk], d);
end;

{ the channel's steps to t (ch_*): a change of level put in its group }
procedure	steps_to(t: longint);
var	st, nx, k, d	: longint;
begin
	st := ch_step;
	nx := ch_next;
	k := dk;
	while nx <= t do
	begin
		st := (st + 1) and ch_mask;
		d := ch_lv^[st] - ch_out;
		if d <> 0 then
		begin
			inc(ch_out, d);
			while ends[k] <= nx do inc(k);
			inc(ch_d^[k], d);
			inc(ch_x^[k], (ends[k] - nx) * d);
		end;
		inc(nx, ch_len);
	end;
	ch_step := st;
	ch_next := nx;
	dk := k;
end;

{ a pulse to t: silent, its timer set from t; else its steps }
procedure	pulse_mix(var p: PULSE; var out: longint; go, vol, len, t: longint; lv: PLV8);
var	lvl	: longint;
begin
	dk := 0;
	lvl := DUTY[p.duty][p.step] * vol * go;
	if lvl <> out then
	begin
		put_p(lvl - out, p.at);
		out := lvl;
	end;
	if go = 0 then p.next := t + len
	else
	begin
		ch_next := p.next;
		ch_step := p.step;
		ch_mask := 7;
		ch_len := len;
		ch_out := out;
		ch_lv := PLEVELS(lv);
		ch_x := @XP;
		ch_d := @DP;
		steps_to(t);
		p.next := ch_next;
		p.step := ch_step;
		out := ch_out;
	end;
	p.at := t;
end;

{ the triangle to t: held, its level stays and its timer is set from t }
procedure	tri_mix(t: longint);
var	lvl	: longint;
begin
	dk := 0;
	lvl := TRI_SEQ[tri.step] * 3;
	if lvl <> tri_out then
	begin
		put_t(lvl - tri_out, tri.at);
		tri_out := lvl;
	end;
	if tri_go = 0 then tri.next := t + tri_len
	else
	begin
		ch_next := tri.next;
		ch_step := tri.step;
		ch_mask := 31;
		ch_len := tri_len;
		ch_out := tri_out;
		ch_lv := @TRI3;
		ch_x := @XT;
		ch_d := @DT;
		steps_to(t);
		tri.next := ch_next;
		tri.step := ch_step;
		tri_out := ch_out;
	end;
	tri.at := t;
end;

{ the noise to t, its sums into the n + 1 samples; silent, its timer set
  from t; at volume 0 only its steps }
procedure	noise_mix(n, t: longint);
var	k, e	: longint;
begin
	if noi_go = 0 then
	begin
		noi.at := t;
		noi.next := t + noi.period;
		exit;
	end;
	if noi_vol = 0 then
	begin
		noise_steps(t, 0, noi_tap);
		noi.at := t;
		exit;
	end;
	for k := 0 to n do
	begin
		e := ends[k];
		if e > t then e := t;
		noise_steps(e, noi_vol, noi_tap);
		if noi.lfsr and 1 = 0 then inc(noi.acc, noi_vol * (e - noi.at));
		noi.at := e;
		inc(AN[k], noi.acc);
		noi.acc := 0;
	end;
end;

{ the DMC's steps to t: its level's changes put in (T), a fetch as the
  shifter empties }
procedure	dmc_steps(t: longint);
var	nx, k, lvl, d	: longint;
begin
	nx := dmc.next;
	k := dk;
	while nx <= t do
	begin
		if not dmc.silent then
		begin
			{ the level two up or down, kept in 0-127 }
			lvl := dmc.level;
			if dmc.shift and 1 <> 0 then
			begin
				if lvl <= 125 then inc(lvl, 2);
			end
			else if lvl >= 2 then dec(lvl, 2);
			if lvl <> dmc.level then
			begin
				dmc.level := lvl;
				d := lvl - dmc_out;
				if d <> 0 then
				begin
					inc(dmc_out, d);
					while ends[k] <= nx do inc(k);
					inc(DT[k], d);
					inc(XT[k], (ends[k] - nx) * d);
				end;
			end;
			dmc.shift := dmc.shift shr 1;
		end;
		dec(dmc.bits);
		if dmc.bits = 0 then
		begin
			dmc.bits := 8;
			if dmc.full then
			begin
				dmc.silent := FALSE;
				dmc.shift := dmc.buffer;
				dmc.full := FALSE;
				dk := k;
				dmc_fetch(nx);
				k := dk;
			end
			else	dmc.silent := TRUE;
		end;
		inc(nx, DMC_PERIOD[dmc.rate]);
	end;
	dmc.next := nx;
	dk := k;
end;

{ the DMC to t: idle, its clocks skipped at once; else its steps }
procedure	dmc_mix(t: longint);
var	n	: longint;
begin
	dk := 0;
	with dmc do
	begin
		if level <> dmc_out then
		begin
			put_t(level - dmc_out, at);
			dmc_out := level;
		end;
		if silent and not full and (left = 0) then
		begin
			at := t;
			if next <= t then
			begin
				n := (t - next) div DMC_PERIOD[rate] + 1;
				inc(next, n * DMC_PERIOD[rate]);
				bits := bits - n mod 8;
				if bits <= 0 then inc(bits, 8);
			end;
			exit;
		end;
		dmc_steps(t);
		at := t;
	end;
end;

{ the n samples made: the two groups' sums by cycles averaged (8 bits
  of fraction; a sample with no change in it its level), the NES's two
  tables interpolated (0 .. 65535), the DC high pass, into apu_samples }
{ n * 256 div c, n and c below 65536 (a sample's sum, its cycles): the
  quotient's 256ths and the remainder's, two 16-bit divisions where BP7
  would divide a longint by a call }
function	avg256(n, c: U16): U16;
begin
	avg256 := (n div c) shl 8 + ((n mod c) shl 8) div c;
end;

procedure	mix(n: longint);
var	i, c, s,
	x, d, y, from	: longint;
	pa, ta, k		: U16;
begin
	from := smp_start;
	for i := 0 to n - 1 do
	begin
		{ the sample's cycles }
		c := ends[i] - from;
		from := ends[i];
		if c <= 0 then c := 1;
		{ the pulses' average, 8 bits of fraction }
		if XP[i] = 0 then pa := lp * 256
		else	pa := avg256(lp * c + XP[i], c);
		inc(lp, DP[i]);
		{ the rest's (the noise's sums twice: its weight) }
		x := AN[i] * 2 + XT[i];
		if x = 0 then ta := lt * 256
		else	ta := avg256(lt * c + x, c);
		inc(lt, DT[i]);
		{ the tables, interpolated }
		k := pa shr 8;
		if k >= 31 then s := PULSE_T[31]
		else
		begin
			s := PULSE_T[k];
			d := (PULSE_T[k + 1] - s) * (pa and 255);
			inc(s, d div 256);
		end;
		k := ta shr 8;
		if k >= 203 then inc(s, TND_T[203])
		else
		begin
			inc(s, TND_T[k]);
			d := (TND_T[k + 1] - TND_T[k]) * (ta and 255);
			inc(s, d div 256);
		end;
		{ the DC high pass: y = x - x' + y' * 32480 / 32768 }
		y := s - hp_in + (hp_out * 32480) div 32768;
		hp_in := s;
		hp_out := y;
		if y > 32767 then y := 32767;
		if y < -32768 then y := -32768;
		if apu_count < APU_MAX_SAMPLES then
		begin
			apu_samples[apu_count] := y;
			inc(apu_count);
		end;
	end;
end;

{ the batch to t (or less: MIX_MAX samples at most); the cycle reached }
function	mix_to(t: longint): longint;
var	n, fr, k	: longint;
begin
	k := smp_end + (MIX_MAX - 2) * (smp_cycles shr 16);
	if t > k then t := k;
	ends[0] := smp_end;
	fr := smp_frac;
	n := 0;
	while ends[n] <= t do
	begin
		inc(fr, smp_cycles);
		ends[n + 1] := ends[n] + fr shr 16;
		fr := fr and $FFFF;
		inc(n);
	end;
	prepare;
	pulse_mix(p1, p1_out, p1_go, p1_vol, p1_len, t, @PL1);
	pulse_mix(p2, p2_out, p2_go, p2_vol, p2_len, t, @PL2);
	tri_mix(t);
	noise_mix(n, t);
	dmc_mix(t);
	if n > 0 then
	begin
		mix(n);
		smp_start := ends[n - 1];
		smp_end := ends[n];
		smp_frac := fr;
		{ the open sample's to the front, the made ones' cleared }
		XP[0] := XP[n];
		DP[0] := DP[n];
		XT[0] := XT[n];
		DT[0] := DT[n];
		AN[0] := AN[n];
		for k := 1 to n do
		begin
			XP[k] := 0;
			DP[k] := 0;
			XT[k] := 0;
			DT[k] := 0;
			AN[k] := 0;
		end;
	end;
	mix_to := t;
end;

{ ---- the frame counter ---- }

function	step_at: longint;
begin
	if five then
		step_at := seq_start + STEP5[step]
	else
		step_at := seq_start + STEP4[step];
end;

function	frame_next: longint;
begin
	if reset_at < step_at then frame_next := reset_at else frame_next := step_at;
end;

procedure	frame_event(t: longint);
begin
	prep_dirty := TRUE;
	if t = reset_at then
	begin
		reset_at := APU_NEVER;
		seq_start := t;
		step := 0;
		five := reset_five;
		if five then
		begin
			quarter;
			half;
		end;
		exit;
	end;
	case step of
	0, 2:	quarter;
	1, 4:	begin
				quarter;
				half;
			end;
	end;
	if not five and (step >= 3) and not inhibit and not frame_irq then
	begin
		frame_irq := TRUE;
		frame_irq_time := t;
	end;
	if step = 5 then
	begin
		if five then inc(seq_start, STEP5[5]) else inc(seq_start, STEP4[5]);
		step := 0;
	end
	else
		inc(step);
end;

procedure	apu_run(at: longint);
var	t, f	: longint;
begin
	repeat
		f := frame_next;
		t := at;
		if f < t then t := f;
		if audio then t := mix_to(t) else dmc_run(t);
		if t = f then frame_event(t)
		else if t = at then exit;
	until FALSE;
end;

{ the next frame counter event or DMC fetch: a fetch (its read, the
  stall, its IRQ) comes only as the shifter empties, bits steps on;
  the level's steps need no stop, summed whenever the APU catches up }
function	apu_next: longint;
var	n, f	: longint;
begin
	n := frame_next;
	if dmc.left > 0 then
	begin
		f := dmc.next + (dmc.bits - 1) * DMC_PERIOD[dmc.rate];
		if f < n then n := f;
	end;
	apu_next := n;
end;

function	apu_irq_at: longint;
var	c	: longint;
begin
	c := APU_NEVER;
	if frame_irq then c := frame_irq_time;
	if dmc.irq and (dmc.irq_time < c) then c := dmc.irq_time;
	apu_irq_at := c;
end;

{ ---- registers ---- }

function	status: longint;
var	r	: longint;
begin
	r := 0;
	if p1.len > 0 then r := r or 1;
	if p2.len > 0 then r := r or 2;
	if tri.len > 0 then r := r or 4;
	if noi.len > 0 then r := r or 8;
	if dmc.left > 0 then r := r or $10;
	if frame_irq then r := r or $40;
	if dmc.irq then r := r or $80;
	status := r;
end;

function	apu_read(addr, at: longint): longint;
begin
	apu_read := -1;
	if addr <> $4015 then exit;
	apu_run(at);
	apu_read := status;
	frame_irq := FALSE;
end;

{ the lengths are clocked on the cycle after at }
function	clocking(at: longint): boolean;
begin
	if reset_at = at + 1 then clocking := reset_five
	else	clocking := (frame_next = at + 1) and (step in [1, 4]);
end;

{ a halt bit written at at, for channel ch }
procedure	set_halt(ch: longint; on: boolean; var halt: boolean; at: longint);
begin
	if clocking(at) then halt_after[ch] := ord(on)
	else	halt := on;
end;

{ a length loaded at at, for channel ch }
procedure	load_length(ch, v: longint; var len: longint; at: longint);
begin
	if enabled and (1 shl ch) = 0 then exit;
	if clocking(at) then
	begin
		if len > 0 then exit;
		no_clock[ch] := TRUE;
	end;
	len := LENGTHS[v shr 3];
end;

procedure	pulse_write(var p: PULSE; reg, v, ch, at: longint);
begin
	case reg of
	0:	begin
			p.duty := v shr 6;
			set_halt(ch, v and $20 <> 0, p.halt, at);
			p.env.loop := v and $20 <> 0;
			p.env.constant := v and $10 <> 0;
			p.env.volume := v and 15;
		end;
	1:	begin
			p.sw_on := v and $80 <> 0;
			p.sw_period := (v shr 4) and 7;
			p.sw_neg := v and 8 <> 0;
			p.sw_shift := v and 7;
			p.sw_reload := TRUE;
		end;
	2:	p.period := (p.period and $700) or v;
	3:	begin
			p.period := (p.period and $FF) or (v and 7) shl 8;
			load_length(ch, v, p.len, at);
			p.step := 0;
			p.env.start := TRUE;
		end;
	end;
end;

procedure	apu_write(addr, v, at: longint);
begin
	apu_run(at);
	prep_dirty := TRUE;
	case addr of
	$4000 .. $4003:	pulse_write(p1, addr and 3, v, 0, at);
	$4004 .. $4007:	pulse_write(p2, addr and 3, v, 1, at);
	$4008:	begin
			set_halt(2, v and $80 <> 0, tri.control, at);
			tri.lin_value := v and $7F;
		end;
	$400A:	tri.period := (tri.period and $700) or v;
	$400B:	begin
			tri.period := (tri.period and $FF) or (v and 7) shl 8;
			load_length(2, v, tri.len, at);
			tri.lin_reload := TRUE;
		end;
	$400C:	begin
			set_halt(3, v and $20 <> 0, noi.halt, at);
			noi.env.loop := v and $20 <> 0;
			noi.env.constant := v and $10 <> 0;
			noi.env.volume := v and 15;
		end;
	$400E:	begin
			noi.mode := v and $80 <> 0;
			noi.period := NOISE_PERIOD[v and 15];
		end;
	$400F:	begin
			load_length(3, v, noi.len, at);
			noi.env.start := TRUE;
		end;
	$4010:	begin
			dmc.irq_on := v and $80 <> 0;
			if not dmc.irq_on then dmc.irq := FALSE;
			dmc.loop := v and $40 <> 0;
			dmc.rate := v and 15;
		end;
	$4011:	dmc.level := v and $7F;
	$4012:	dmc.start_addr := $C000 + v * 64;
	$4013:	dmc.start_len := v * 16 + 1;
	$4015:	begin
			enabled := v and $0F;
			if v and 1 = 0 then p1.len := 0;
			if v and 2 = 0 then p2.len := 0;
			if v and 4 = 0 then tri.len := 0;
			if v and 8 = 0 then noi.len := 0;
			dmc.irq := FALSE;
			if v and $10 = 0 then dmc.left := 0
			else if dmc.left = 0 then
			begin
				dmc.addr := dmc.start_addr;
				dmc.left := dmc.start_len;
				dmc_fetch(at);
			end;
		end;
	$4017:	begin
			last_4017 := v;
			inhibit := v and $40 <> 0;
			if inhibit then frame_irq := FALSE;
			reset_five := v and $80 <> 0;
			if odd(at) then reset_at := at + 4 else reset_at := at + 3;
		end;
	end;
end;

{ ---- power, reset, time ---- }

{ as if $4017 had been written 9 cycles before the reset vector is
  followed (7 cycles from power or reset): the round starts 3 later }
procedure	restart_frame(t: longint);
begin
	seq_start := t;
	step := 0;
	five := last_4017 and $80 <> 0;
	inhibit := last_4017 and $40 <> 0;
	reset_at := APU_NEVER;
	reset_five := five;
	frame_irq := FALSE;
end;

procedure	resync(t: longint);
begin
	p1.next := t + 2;
	p1.at := t;
	p2.next := t + 2;
	p2.at := t;
	tri.next := t + 1;
	tri.at := t;
	noi.next := t + noi.period;
	noi.at := t;
	noi.acc := 0;
	smp_start := t;
	smp_end := t + smp_cycles shr 16;
	smp_frac := smp_cycles and $FFFF;
	prep_dirty := TRUE;
	lp := 0;
	lt := 0;
	p1_out := 0;
	p2_out := 0;
	tri_out := 0;
	dmc_out := 0;
	fillchar(XP, sizeof(XP), 0);
	fillchar(DP, sizeof(DP), 0);
	fillchar(XT, sizeof(XT), 0);
	fillchar(DT, sizeof(DT), 0);
	fillchar(AN, sizeof(AN), 0);
end;

procedure	apu_power;
var	i	: longint;
begin
	if apu_pal then
	begin
		CPU_HZ := HZ_PAL;
		move(STEP4_PAL, STEP4, sizeof(STEP4));
		move(STEP5_PAL, STEP5, sizeof(STEP5));
		move(NOISE_PAL, NOISE_PERIOD, sizeof(NOISE_PERIOD));
		move(DMC_PAL, DMC_PERIOD, sizeof(DMC_PERIOD));
	end
	else
	begin
		CPU_HZ := HZ_NTSC;
		if apu_dendy then CPU_HZ := 1773448;
		move(STEP4_NTSC, STEP4, sizeof(STEP4));
		move(STEP5_NTSC, STEP5, sizeof(STEP5));
		move(NOISE_NTSC, NOISE_PERIOD, sizeof(NOISE_PERIOD));
		move(DMC_NTSC, DMC_PERIOD, sizeof(DMC_PERIOD));
	end;
	fillchar(p1, sizeof(p1), 0);
	fillchar(p2, sizeof(p2), 0);
	fillchar(tri, sizeof(tri), 0);
	fillchar(noi, sizeof(noi), 0);
	fillchar(dmc, sizeof(dmc), 0);
	p1.ones := 1;
	noi.lfsr := 1;
	noi.period := NOISE_PERIOD[0];
	dmc.bits := 8;
	dmc.silent := TRUE;
	dmc.start_addr := $C000;
	dmc.start_len := 1;
	dmc.next := DMC_PERIOD[0];
	enabled := 0;
	fillchar(no_clock, sizeof(no_clock), 0);
	for i := 0 to 3 do halt_after[i] := -1;
	frame_irq_time := 0;
	last_4017 := 0;
	restart_frame(7 - 9 + 3);
	apu_count := 0;
	apu_stall := 0;
	hp_in := 0;
	hp_out := 0;
	resync(0);
end;

procedure	apu_reset(at: longint);
begin
	apu_write($4015, 0, at);
	restart_frame(at + 7 - 9 + 3);
end;

procedure	apu_rebase(k: longint);
begin
	dec(seq_start, k);
	if reset_at <> APU_NEVER then dec(reset_at, k);
	dec(frame_irq_time, k);
	dec(p1.next, k);
	dec(p1.at, k);
	dec(p2.next, k);
	dec(p2.at, k);
	dec(tri.next, k);
	dec(tri.at, k);
	dec(noi.next, k);
	dec(noi.at, k);
	dec(dmc.next, k);
	dec(dmc.at, k);
	dec(dmc.irq_time, k);
	{ a line long high stays in the past (no wrap after hours) }
	if frame_irq_time < -$40000000 then frame_irq_time := -$40000000;
	if dmc.irq_time < -$40000000 then dmc.irq_time := -$40000000;
	dec(smp_start, k);
	dec(smp_end, k);
end;

procedure	apu_audio(rate: longint);
begin
	audio := rate > 0;
	if not audio then exit;
	apu_start;
	smp_cycles := round(CPU_HZ / rate * 65536);
	resync(dmc.at);
end;

function	apu_sample_cycles: longint;
begin
	apu_sample_cycles := smp_cycles;
end;

procedure	apu_set_sample_cycles(c: longint);
begin
	if c > 0 then smp_cycles := c;
end;

{ the NES's mixer (NESdev wiki, "APU Mixer"), 0..1 as 0..65535 }
procedure	make_tables;
var	i, k	: longint;
begin
	for i := 0 to 255 do
	begin
		ZEROS[i] := 0;
		for k := 0 to 7 do
			if (i shr k) and 1 = 0 then inc(ZEROS[i]);
	end;
	PULSE_T[0] := 0;
	for i := 1 to 31 do PULSE_T[i] := round(95.52 / (8128.0 / i + 100) * 65535);
	for i := 0 to 31 do TRI3[i] := TRI_SEQ[i] * 3;
	TND_T[0] := 0;
	for i := 1 to 203 do TND_T[i] := round(163.67 / (24329.0 / i + 100) * 65535);
end;

var	tables_made	: boolean;

{ the tables only sound needs (mix_to): made before the first sound }
procedure	apu_start;
begin
	if tables_made then exit;
	make_tables;
	tables_made := TRUE;
end;

{$ifdef VER70}{$F+}{$endif}	{ called through apu_dmc_read: far under BP7 }
function	no_read(addr: longint): longint;
begin
	no_read := 0;
end;
{$ifdef VER70}{$F-}{$endif}

begin
	apu_dmc_read := {$ifdef FPC}@{$endif}no_read;
	apu_pal := FALSE;
	apu_dendy := FALSE;
	audio := FALSE;
	smp_cycles := 0;
	tables_made := FALSE;
	apu_power;
end.
