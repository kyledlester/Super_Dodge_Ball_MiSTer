# Architecture

```
 clk_core 48 MHz (sdb_pll) - every chip clock is an enable of it; clk_sys 96 MHz - SDRAM only
 HPS ioctl ──► sdb_loader ──► block RAM (6502 / 6809 / MCU programs, palette PROMs)
                         └──► SDRAM (text, sprites, ADPCM) via sdb_sdram_arb (96 MHz, two-clock acks)
                                   ▲    ▲        ▲      ▲
                       ADPCM ch0 ──┘    └ ch1    │      └ sprite engine
                                         tile engine
 sdb_main: jt65c02 6502 (2 MHz), jt63701y MCU (4 MHz), RAMs, I/O, IRQ (HOLD) / NMI, ROM bank,
           per-8-line register history for the renderer
   ├─ video RAM / sprite RAM read ports ─► sdb_video (line-ahead tile + sprite engines, line
   │                                       buffers, PROM palette) ─► rgb
   └─ sound latch ─► sdb_sound (mc6809i 1.5 MHz, jtopl2 YM3812 3 MHz, 2 x sdb_adpcm) ─► mono audio
 sdb_video_timing (384 x 272 @ 6 MHz) ─► IRQ every 8 lines, NMI at 256, vblank 240-271
 SuperDodgeBall.sv: hps_io, pause, CRT Adjust, arcade_video
```

## Clocks

| Enable | Rate | Derivation |
| --- | --- | --- |
| ce_pix | 6 MHz | clk_core / 8 |
| 6502 cen | 8 MHz (= 4 x 2 MHz E) | / 6 |
| MCU cen | 4 MHz (1 MHz E) | / 12 |
| 6809 E / Q | 1.5 MHz | / 32, Q half a cycle before E |
| YM3812 | 3 MHz | / 16 |
| MSM5205 VCK | 8 kHz | / 6000 |

`pause` freezes the three CPUs, the YM3812, the VCK and the interrupts; the raster keeps running.

## Memory

| Data | Resource |
| --- | --- |
| 6502 program 64 KB, 6809 program 32 KB, MCU ROM 16 KB, PROMs 2 KB | block RAM |
| 6502 RAM 4 KB, video RAM 4 KB (two dual-port halves), sprite RAM 256 B (4 byte lanes), 6809 RAM 4 KB | block RAM |
| text 256 KB, sprites 256 KB, ADPCM 128 KB | SDRAM, 4-word bursts |

## Video

At the start of display line d, the tile engine and the sprite engine render line L = d+1 into bank
L & 1 of their line buffers; the output side reads bank d & 1. The tile engine fetches each tile's
video RAM word and one 32-bit row from SDRAM, then writes 8 pixels; the sprite engine walks the 64
entries in order and draws the covering row of each (one 8-byte burst) with pen 0 transparent. The
sprite line buffer is cleared as it is displayed. Per-line registers come from the history in
sdb_main (docs/HARDWARE.md 3 and 8).

## Debug overlay

OSD Debug submenu; drawn at the top left of the raster.

| Line | Left 16 bits | Right 16 bits |
| --- | --- | --- |
| 1 | - | 6502 program address |
| 2 | IRQs | NMIs |
| 3 | MCU NMIs | sound-latch reads (6809) |
| 4 | YM3812 writes | YM3812 IRQs |
| 5 | ADPCM starts | render overruns |
| 6 | - | `loaded` flag |

## Verification

See `docs/VERIFICATION.md`.
