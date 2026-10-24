# Known issues and open points

* **Not yet tested on hardware** (first RBF). Simulation matches MAME (docs/VERIFICATION.md).
* The main CPU is jtcores' `jt65c02` (a 65C02 core, the same one jtcores uses for its 6502-based
  Kunio-kun port). The board has an NMOS 6502: a few opcodes differ in cycle count or flag behaviour
  (decimal mode N/Z, extra cycle). Nothing observed in simulation so far; watch for timing-related
  oddities.
* MCU clock: MAME's 4 MHz is marked "unknown clock"; the core uses it.
* The real board's sync positions are unknown; the 384 x 272 raster places HSync at dots 280-311
  and VSync at lines 250-252. Use CRT Adjust to centre the picture on a CRT.
* MAME's driver notes sprite lag on the real game; the core renders sprites line by line from live
  sprite RAM, so it shows what MAME shows (the game updates sprites in vblank).
* Writes to 3000 (once per frame) and 3001 (every IRQ) have no known function and are ignored, as in
  MAME.
