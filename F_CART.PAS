{*+
	F_CART.PAS - EMUFAMI
	(c) 2026 Trinh D.D. Nguyen, Infinity Group

	A .NES file: the iNES or NES 2.0 header, trainer, PRG and CHR,
	read into blocks of 32 KB (no compiler's block holds a whole big
	ROM in 16-bit protected mode); cart_prg and cart_chr find a byte
	by its offset.  Refused with the reason in cart_why.  The TV
	system from the header; headers taken as they are.
-*}
{$S-}		{ no stack check at every call }
unit	f_cart;

interface

uses
	f_sys;

const
	MIRROR_H	= 0;		{ horizontal: $2000 = $2400 }
	MIRROR_V	= 1;		{ vertical: $2000 = $2800 }
	MIRROR_FOUR	= 2;		{ four screens, RAM on the cartridge }

	TV_NTSC		= 0;		{ the TV system the header says }
	TV_PAL		= 1;
	TV_MULTI	= 2;		{ either: NTSC is used }
	TV_DENDY	= 3;

	CHUNK		= 32768;	{ a ROM block }
	CHUNKS		= 64;		{ 2 MB of PRG, 2 MB of CHR at most }

type
	PCART	= ^CART;
	CART	= record
		mapper		: longint;
		submapper	: longint;
		nes2		: boolean;
		mirror		: longint;	{ MIRROR_* as the header says }
		tv			: longint;	{ TV_* }
		battery		: boolean;
		prg_size	: longint;	{ bytes }
		chr_size	: longint;	{ bytes; 0: the board has CHR RAM }
		prg_ram		: longint;	{ bytes of PRG RAM, kept by no battery }
		prg_nvram	: longint;	{ and by the battery }
		chr_ram		: longint;
		chr_nvram	: longint;
		trainer		: PBYTE;	{ 512 bytes for $7000, or nil }
		prg			: array[0 .. CHUNKS - 1] of PBYTE;
		chr			: array[0 .. CHUNKS - 1] of PBYTE;
	end;

function	cart_load(const name: string; var c: CART): boolean;
procedure	cart_free(var c: CART);
function	cart_prg(var c: CART; offset: longint): PBYTE;	{ the PRG's byte at offset }
function	cart_chr(var c: CART; offset: longint): PBYTE;	{ the CHR ROM's }
function	cart_why: string;			{ why the last one was refused }

implementation

type
	HEADER	= array[0 .. 15] of byte;

var
	why	: string;

function	cart_why: string;
begin
	cart_why := why;
end;

function	cart_prg(var c: CART; offset: longint): PBYTE;
begin
	cart_prg := padd(c.prg[offset div CHUNK], offset mod CHUNK);
end;

function	cart_chr(var c: CART; offset: longint): PBYTE;
begin
	cart_chr := padd(c.chr[offset div CHUNK], offset mod CHUNK);
end;

{ a NES 2.0 size: units times lsb, or with the high nibble $F,
  2^E * (2M + 1) bytes from lsb's EEEEEEMM; -1 when too big }
function	rom_size(lsb, msb, units: longint): longint;
var	e	: longint;
begin
	if msb <> $F then rom_size := (msb shl 8 + lsb) * units
	else
	begin
		e := lsb shr 2;
		if e > 24 then rom_size := -1
		else	rom_size := (longint(1) shl e) * ((lsb and 3) * 2 + 1);
	end;
end;

function	ram_size(shift: longint): longint;
begin
	if shift = 0 then ram_size := 0 else ram_size := longint(64) shl shift;
end;

{ the header's facts into c; FALSE (why set) when it is refused }
function	parse_header(var h: HEADER; size: longint; var c: CART): boolean;
var	need, i	: longint;
	junk	: boolean;
begin
	parse_header := FALSE;
	if (size < 16) or (h[0] <> $4E) or (h[1] <> $45) or (h[2] <> $53) or (h[3] <> $1A) then
	begin
		why := 'not an iNES file';
		exit;
	end;
	c.nes2 := h[7] and $0C = $08;
	junk := FALSE;
	if not c.nes2 then
		for i := 12 to 15 do
			if h[i] <> 0 then junk := TRUE;
	c.mapper := h[6] shr 4;
	if not junk then c.mapper := c.mapper or (h[7] and $F0);
	if h[6] and 8 <> 0 then c.mirror := MIRROR_FOUR
	else	c.mirror := h[6] and 1;
	c.battery := h[6] and 2 <> 0;
	if c.nes2 then
	begin
		c.mapper    := c.mapper or longint(h[8] and $0F) shl 8;
		c.submapper := h[8] shr 4;
		c.prg_size  := rom_size(h[4], h[9] and $0F, 16384);
		c.chr_size  := rom_size(h[5], h[9] shr 4, 8192);
		c.prg_ram   := ram_size(h[10] and $0F);
		c.prg_nvram := ram_size(h[10] shr 4);
		c.chr_ram   := ram_size(h[11] and $0F);
		c.chr_nvram := ram_size(h[11] shr 4);
	end
	else
	begin
		c.prg_size := longint(h[4]) * 16384;
		c.chr_size := longint(h[5]) * 8192;
		{ iNES leaves the RAM unsaid: 8 KB at $6000, kept by the
		  battery when there is one; 8 KB of CHR RAM without CHR ROM }
		if c.battery then c.prg_nvram := 8192 else c.prg_ram := 8192;
		if c.chr_size = 0 then c.chr_ram := 8192;
	end;
	if not junk and (h[7] and 3 <> 0) then
	begin
		case h[7] and 3 of
		1:	why := 'a Vs. System cartridge';
		2:	why := 'a PlayChoice-10 cartridge';
		else
			why := 'a cartridge for another console';
		end;
		exit;
	end;
	if c.nes2 then c.tv := h[12] and 3
	else if not junk and (h[9] and 1 <> 0) then c.tv := TV_PAL
	else	c.tv := TV_NTSC;
	if (c.prg_size < 0) or (c.chr_size < 0) or (c.prg_size > longint(CHUNKS) * CHUNK)
	or (c.chr_size > longint(CHUNKS) * CHUNK) then
	begin
		why := 'a ROM size beyond any cartridge';
		exit;
	end;
	if c.prg_size = 0 then
	begin
		why := 'no PRG ROM';
		exit;
	end;
	if (c.prg_size < 8192) or ((c.chr_size > 0) and (c.chr_size < 1024)) then
	begin
		why := 'a ROM smaller than a bank';
		exit;
	end;
	need := 16 + c.prg_size + c.chr_size;
	if h[6] and 4 <> 0 then inc(need, 512);
	if size < need then
	begin
		why := 'the file is cut short: ' + itoa(size) + ' bytes of ' + itoa(need);
		exit;
	end;
	parse_header := TRUE;
end;

{ n bytes of the file into blocks of CHUNK; FALSE when short of memory }
function	read_chunks(var f: file; n: longint; var chunks: array of PBYTE): boolean;
var	k,
	part: longint;
	got	: RWCOUNT;
begin
	read_chunks := FALSE;
	k := 0;
	while n > 0 do
	begin
		part := n;
		if part > CHUNK then part := CHUNK;
		chunks[k] := malloc(part);
		if chunks[k] = nil then
		begin
			why := 'not enough memory';
			exit;
		end;
		blockread(f, chunks[k]^, part, got);
		if got <> part then
		begin
			why := 'cannot read the file';
			exit;
		end;
		dec(n, part);
		inc(k);
	end;
	read_chunks := TRUE;
end;

function	cart_load(const name: string; var c: CART): boolean;
var	f	: file;
	h	: HEADER;
	got	: RWCOUNT;
	ok	: boolean;
begin
	cart_load := FALSE;
	fillchar(c, sizeof(CART), 0);
	assign(f, name);
	filemode := 0;			{ read only: a ROM is never written }
	{$I-} reset(f, 1); {$I+}
	filemode := 2;
	if ioresult <> 0 then
	begin
		why := 'cannot open ' + name;
		exit;
	end;
	blockread(f, h, 16, got);
	ok := (got = 16) and parse_header(h, filesize(f), c);
	if not ok and (got <> 16) then why := 'not an iNES file: too short';
	if ok and (h[6] and 4 <> 0) then
	begin
		c.trainer := malloc(512);
		ok := c.trainer <> nil;
		if ok then blockread(f, c.trainer^, 512, got);
	end;
	if ok then ok := read_chunks(f, c.prg_size, c.prg);
	if ok then ok := read_chunks(f, c.chr_size, c.chr);
	close(f);
	if not ok then
	begin
		cart_free(c);
		exit;
	end;
	why := '';
	cart_load := TRUE;
end;

procedure	cart_free(var c: CART);
var	k	: longint;
begin
	for k := 0 to CHUNKS - 1 do
	begin
		free(pointer(c.prg[k]));
		free(pointer(c.chr[k]));
	end;
	free(pointer(c.trainer));
	fillchar(c, sizeof(CART), 0);
end;

begin
	why := '';
end.
