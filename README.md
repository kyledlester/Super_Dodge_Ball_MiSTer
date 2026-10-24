# Super Dodge Ball for MiSTer

<!-- Screenshots: add title / gameplay images here. -->

A MiSTer FPGA core for Technos Japan's **Super Dodge Ball** (1987), the arcade original of the
dodgeball game later known on the NES, and its Japanese release **Nekketsu Koukou Dodgeball Bu**. One
core (`SuperDodgeBall`) runs every supported set; each set has its own MRA.

I created this core because I wanted to play this game on my MiSTer FPGA. I am posting it here and open
sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the
assistance of AI tooling.

**Status: beta.** The game boots, runs its attract mode and is playable with
graphics, controls and sound.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`SuperDodgeBall_YYYYMMDD.rbf`) to
   **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA file from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**.
   For the Japanese sets, copy the `_Super Dodge Ball` folder from
   [`MRA/_alternatives/`](MRA/_alternatives/) to **`/media/fat/_Arcade/_alternatives/`**.
3. Put the MAME 0.289 ROM zips in **`/media/fat/games/mame/`**. With split sets, the Japanese sets also
   need **`spdodgeb.zip`** (MAME's parent; it holds the sound program, the MCU ROM and the ADPCM
   samples).
4. Load a game from the **Arcade** menu.

ROMs are not included. You must supply your own.

## Supported games

| Game | MAME set | Year | Genre | Board | Status |
| --- | --- | --- | --- | --- | --- |
| Super Dodge Ball (US) | `spdodgeb` | 1987 | Sports (dodgeball) | Technos TA-0022 | Full game playable |

### Alternatives

These use the same core and the same board as the main set, with different ROMs.

| Game | MAME set | Year | Parent game | Status |
| --- | --- | --- | --- | --- |
| Nekketsu Koukou Dodgeball Bu (Japan) | `nkdodge` | 1987 | Super Dodge Ball | Full game playable |
| Nekketsu Koukou Dodgeball Bu (Japan, bootleg) | `nkdodgeb` | 1987 | Super Dodge Ball | Full game playable |

No other game runs on this board.

**ROM sets:** split, merged and non-merged MAME sets all work. The MRAs look in the set's own zip first
and then in the parent zip. The bootleg's MCU was never dumped; as in MAME, it uses the parent's.

## Controls

Two players, each with an 8-way joystick and two buttons:

| MiSTer button | Default pad button | Function |
| --- | --- | --- |
| Throw | A | Throw / attack |
| Pass | B | Pass (Throw + Pass together: jump) |
| Start | Start | Start (P1 / P2) |
| Coin | Select | Coin (P1 / P2) |
| Pause | L | Pause (see OSD) |

## OSD

* **Aspect ratio**: Original (4:3), Full Screen, or the custom ratios.
* **Scandoubler Fx**: None, HQ2x, CRT 25%, CRT 50%.
* **DIP switches** from each MRA (coinage, flip screen, demo sounds, allow continue, difficulty).
* **CRT Adjust** for the native 15 kHz analog output (thanks to rmonic79/MiSTer-CRT-Adjust):
  * **CRT H-Size** (-12 to +10, 1 % per step), **CRT H-Position** (6 pixels per step) and
    **CRT V-Shift** (1 line per step). Off by default; the amounts are hidden while it is Off.
* **Pause options**: pause when the OSD is open, dim the picture after 10 s of pause.
* **Debug**: the cabinet's service switch, a status overlay (CPU address, interrupt, sound and frame
  counters) and a test pattern.

## Saves

The board has no EEPROM or battery-backed RAM: settings live in the DIP switches (OSD) and high scores
are not kept between power cycles, as on the original hardware.

## About the hardware

Technos TA-0022 (PCB manufactured by Taito), one 12 MHz crystal:

* **6502** main CPU at 2 MHz with a banked 64 KB program ROM.
* **HD63701Y0** microcontroller with its own 16 KB internal ROM, which reads the joysticks and passes
  processed inputs (including the double-tap run) to the 6502. It also serves as copy protection.
* **HD68A09** sound CPU with a Yamaha **YM3812** (OPL2) and two **OKI MSM5205** ADPCM voices.
* One 512 x 256 scrolling tilemap (8x8 tiles), 64 sprites (16x16 or 16x32) and a 1024-colour PROM
  palette. The title bar is a raster split: the game changes the scroll a few lines into each frame.
* 256 x 240 visible, horizontal monitor, 15.625 kHz / 57.44 Hz.

The full technical specification is in [docs/HARDWARE.md](docs/HARDWARE.md).

## About the core

* One RBF for all three sets; see [docs/MRA_FORMAT.md](docs/MRA_FORMAT.md).
* jtcores' 6502 and HD63701Y0 cores (the MCU runs its original program), Greg Miller's cycle-accurate
  6809, jtopl for the YM3812, and an MSM5205 implementation written from MAME's code.
* Every chip clock is an exact fraction of the board's 12 MHz crystal.
* Line-based video renderer: the tilemap and sprites are drawn one line ahead of the beam, as on a
  line-buffer board.
* Checked against MAME 0.289 in simulation: attract-mode frames are pixel-identical, and the sound
  chips' register writes and ADPCM output match exactly. See [docs/VERIFICATION.md](docs/VERIFICATION.md).
* Native 15 kHz output for CRTs with CRT Adjust, and the MiSTer scaler for HDMI.
* Timing closes on every clock domain.

### Known issues

* The video sync positions are not PCB-measured; the raster follows MAME's (384 x 272 at 6 MHz). Use
  CRT Adjust to centre the picture on a CRT.
* The main CPU core is a 65C02 (jtcores' `jt65c02`, also used for its 6502-based Kunio-kun core); the
  board has an NMOS 6502. No difference has been seen.

More: [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).

## Releases

Builds are in [`Releases/`](Releases/) as `SuperDodgeBall_YYYYMMDD.rbf`. The MRAs name the core without
the date (`<rbf>SuperDodgeBall</rbf>`), and MiSTer loads the newest dated file in `_Arcade/cores/`. You
are welcome to run your own build if you'd prefer.

## Building

Quartus Prime Lite 17.0. Open `SuperDodgeBall.qpf` and compile, or run
`powershell -ExecutionPolicy Bypass -File scripts\build.ps1`. The post-flow script copies
`output_files/SuperDodgeBall.rbf` to `Releases/SuperDodgeBall_YYYYMMDD.rbf`. The MRAs are generated by
`scripts/romtool.py`. See [docs/BUILDING.md](docs/BUILDING.md).

## Documentation

* [Hardware specification](docs/HARDWARE.md)
* [Architecture](docs/ARCHITECTURE.md)
* [ROM layout and MRA format](docs/MRA_FORMAT.md)
* [Verification](docs/VERIFICATION.md)
* [Building](docs/BUILDING.md)
* [Known issues](docs/KNOWN_ISSUES.md)
* [Credits and licences](docs/REFERENCES.md)

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). The MiSTer framework in `sys/` keeps its own notices
([LICENSE.MiSTer](LICENSE.MiSTer)); reused components and their licences are listed in
[docs/REFERENCES.md](docs/REFERENCES.md).

No ROMs or other game data are included in this repository.
