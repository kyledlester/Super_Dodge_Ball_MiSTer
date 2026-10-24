# Hardware (Technos TA-0022, MAME `technos/spdodgeb.cpp`)

Everything here is taken from MAME 0.289 and from MAME traces captured for this port
(`local/mame/trace_io.lua`). Where the core deliberately follows or departs from MAME, section 8 says
why.

## 1. Board

| Part | Function | Clock |
| --- | --- | --- |
| 12.000 MHz crystal | only oscillator | |
| 6502 (TJC-706002) | main CPU | 12 MHz / 6 = 2 MHz |
| HD63701Y0 (22JA-0, 16 KB internal ROM) | input processing / protection | 4 MHz in MAME ("unknown") |
| HD68A09P | sound CPU | 6 MHz in (1.5 MHz E) |
| YM3812 | FM | 3 MHz |
| 2 x MSM5205 | ADPCM, S48 4-bit | 384 kHz (8 kHz sample rate) |
| 2 PROMs (MB7132E/MB7122E) | 1024-colour palette | |

## 2. Main CPU map

| Address | R/W | Function |
| --- | --- | --- |
| 0000-0FFF | RW | work RAM |
| 1000-10FF | W | sprite RAM (64 x 4 bytes; reads are unmapped = 0) |
| 2000-2FFF | RW | video RAM: 2000-27FF tile codes, 2800-2FFF attributes |
| 3000 | R | IN0 |
| 3001 | R | DSW |
| 3002 | W | sound latch (sets the 6809 IRQ) |
| 3004 | W | scroll X bits 7-0 |
| 3005 | W | MCU NMI |
| 3006 | W | control: 0 flip, 1 ROM bank (0 = ROM 4000), 2 scroll X bit 8, 3 to MCU?, 5-4 tile palette bank, 7-6 sprite palette bank |
| 3800 | W | latch read by the MCU at 8080 |
| 3801-3805 | R | bytes written by the MCU at 8081-8085 |
| 4000-7FFF | R | banked ROM (ROM 0000-3FFF or 4000-7FFF) |
| 8000-FFFF | R | ROM 8000-FFFF |

IN0: bit 0 vblank (high in lines 240-271), bit 1 MCU busy (MCU port 5 bit 7), bit 2 high, bits 3/4/5
coin 1 / coin 2 / service (active low), bits 7-6 difficulty DIP.

Writes MAME ignores but the game makes: 3000 once per frame (line 0 handler) and 3001 once per IRQ
(values cycling 1, 2, 3, 0). Their purpose is unknown (not an IRQ acknowledge: the IRQ is HOLD_LINE in
MAME and the game runs correctly there); the core ignores them like MAME.

## 3. Interrupts and raster

Raster 384 x 272 at 6 MHz (15.625 kHz, 57.44 Hz); visible 256 x 240, lines 0-239.

* IRQ at the start of every line that is a multiple of 8 except 256 (33 per frame), held until the
  6502 takes it (MAME HOLD_LINE).
* NMI at the start of line 256.

The game sets the playfield scroll from the line-8 IRQ handler (trace: written at line 13) and
restores the title-bar scroll in the NMI handler. MAME draws, at each IRQ at line N, all lines up to
N+16 before the CPU runs its handler, so a value written by the line-8 handler first shows on line 25:
the title bar keeps its own scroll for lines 0-24. The core reproduces this exactly (section 8).

## 4. MCU

HD63701Y0 in expanded mode 2: address on ports 1/4, data on port 3. Ports: P2 = player 1, P6 = player 2,
P5 input = IN1 (bit 1 unknown DIP, bit 2 allow-continue DIP, bit 3 high), P5 output bits 7-6 = status
(bit 7 is the busy flag in IN0). External: 8080 read = latch from 3800, 8081-8085 write = the five
bytes the 6502 reads at 3801-3805. The 6502 pulses the MCU NMI through 3005. The MCU turns the joystick
into processed inputs (including the double-tap run detection).

## 5. Video

Tilemap: 64 x 32 tiles of 8 x 8, 4 bpp, 8 KB of 32-byte tiles (`text` region, planes {0,2,4,6}, x
offsets {1,0,65,64,129,128,193,192}). Word (col, row): code at (col & 31) + 32 row + 32 (col & 32),
attribute at +0x800. Tile = code | (attribute & 0x1f) << 8; colour = attribute >> 5 + 8 x tile palette
bank. Scroll X = scroll register + 5. Flip screen flips the tilemap on MAME's 384 x 272 bitmap:
X = 127 - x - scroll', Y = 239 - y. No priority; the tilemap is opaque.

Sprites: 64 entries {240 - y, attribute, code low, x}; attribute 7 = 16 x 32 (two codes, even on top),
6 = !flip X, 5-3 colour, 2-0 code bits 10-8. Sprite region: two halves of 128 KB, planes {hi+0, hi+4,
lo+0, lo+4}. Colour + 8 x sprite palette bank, pens 0x200-0x3ff, pen 0 transparent, later entries on
top, positions/wrap exactly as `draw_sprites`.

Palette: 1024 entries; red = PROM 0 bits 3-0, green = PROM 0 bits 7-4, blue = PROM 1 bits 3-0, each
4-bit value weighted 0x0e/0x1f/0x43/0x8f.

## 6. Sound

6809 map: 0000-0FFF RAM, 1000 latch (read clears the pending IRQ), 2800-2801 YM3812, 3800-3807 ADPCM,
8000-FFFF ROM. FIRQ = YM3812 IRQ.

ADPCM (per channel, offset & 1): offset/2 = 0 start, 1 end = (d & 0x7f) x 0x200, 2 start address =
(d & 0x7f) x 0x200, 3 stop. On every VCK the board logic fetches a byte at the address (high nibble
first) until the end address; MAME's MSM5205 decodes with 12-bit signal and a 10-bit DAC.

Mix (MAME): YM3812 x 1.0 + each MSM5205 x 0.5.

## 7. ROM sets

| Set | Differences |
| --- | --- |
| spdodgeb | parent |
| nkdodge | own main program, text, sprites, PROMs |
| nkdodgeb | same program as nkdodge; graphics in 64 KB ROMs; PROM 27s191 (2 KB, first half used); MCU not dumped (uses the parent's) |

## 8. Where the core follows or departs from MAME, and why

The brief was to get closer to the arcade board than MAME where possible. The evaluation:

| Area | MAME | Core | Notes |
| --- | --- | --- | --- |
| Clocks | 2 / 4 / 1.5 MHz, 3 MHz, 384 kHz | exact integer enables of 48 MHz (4 x 12 MHz) | identical ratios; no drift between CPUs and raster |
| Sprite rendering | drawn in batches at each partial update, from sprite RAM at that moment | drawn one line ahead of the beam from live sprite RAM, like a line-buffer board | closer to how the board works; the game updates sprites in vblank, so frames look the same |
| Scroll / palette bank / flip mid-frame | applied per 8-line batch, 16 lines after each IRQ (driver note: "pretty off") | identical timing via a per-8-line register history | the title-bar split depends on it; the real board's exact vertical counter phase is undocumented, so matching MAME (which shows the split correctly) is the safe choice |
| MCU | real 63701 program, 4 MHz guess | real program on jt63701y, 4 MHz | the input processing (double-tap run) runs the original code in both |
| MSM5205 | free-running VCK, 10-bit DAC, MAME sequencer | same, written from MAME's code | |
| Main CPU core | NMOS 6502 | jt65c02 (65C02 core, as used by jtcores' Kunio-kun port of a 6502 board) | possible tiny cycle differences on a few opcodes; to be watched in testing |
| Audio output | no analogue filtering | none in the core | the board's RC output filter values are unknown; MiSTer's audio filter menu can add one |

Nothing found in the driver or the traces justifies a deliberate, unverifiable departure from MAME's
observable behaviour, so the core reproduces it and only differs where the hardware architecture
itself is more faithful (line-based rendering, exact clock ratios).
