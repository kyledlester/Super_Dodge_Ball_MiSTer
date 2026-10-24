# Verification

All checks against MAME 0.289 (`spdodgeb`), with the real ROMs. The benches and the MAME Lua capture
script (main-CPU I/O writes, sound-chip writes, frame snapshots) depend on locally captured MAME data
and ROM images and are not part of this repository; the bench names below are for reference.

| Check | Bench | Result |
| --- | --- | --- |
| ROM tables vs MAME `-listxml` (all three sets, CRCs) | `scripts/romtool.py check` | match |
| RTL loader vs the reference reordering (whole 0xBC800-byte stream: SDRAM image, block RAMs, PROMs) | `sim/tb_loader.sv` | 0 mismatches |
| Whole board from reset (6502, MCU, video; sound board left out for simulator speed), frames vs MAME snapshots | `sim/tb_sdb.sv`, `sim/compare.py` | frames 16, 50, 100, ..., 600 pixel-identical (title screen and attract-mode gameplay with the title-bar scroll split, scrolled court, sprites); 0 render overruns; 33 IRQs + 1 NMI per frame as MAME |
| Sound board (6809 + YM3812 + ADPCM glue) fed with MAME's sound-latch writes | `sim/tb_sound.sv`, `sim/sndsched.py` | YM3812 write stream identical to MAME's for 150 frames (1,884 writes), constant time offset (interrupt cadence exact) |
| ADPCM channels vs MAME's adpcm_int + msm5205 (Python port) with the demo's real register writes | `sim/tb_adpcm.sv`, `sim/adpcm_ref.py` | 67,068 VCKs (8.4 s, both channels), 0 mismatches |

Bugs found this way: an aliased register decode in jt63701y (P5DDR write ignored in expanded mode,
docs/REFERENCES.md), clock-enable counters without power-up values (simulation only), and a too-short
reset for jtopl (now stretched in sdb_core).
