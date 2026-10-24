# References and reused code

| What | Source | License |
| --- | --- | --- |
| Hardware description | MAME 0.289 `src/mame/technos/spdodgeb.cpp` (Paul Hampson, Nicola Salmoria), `src/devices/sound/msm5205.cpp` | BSD-3-Clause (reference only, no code copied) |
| MiSTer framework `sys/` | MiSTer-devel/Template_MiSTer (as in the owner's Final Star Force core) | GPL-2.0+ / per file |
| 6502 (`jt65c02`), HD63701 core (`jt680x`) and microcode YAML | jotego/jtcores `modules/jt680x` (Jose Tejada) | GPL-3.0-or-later |
| HD63701Y0 MCU (`jt63701y`), `jtframe_ram` | jotego/jtcores `modules/jtframe` | GPL-3.0-or-later |
| 6809 (`mc6809i`, `jtframe_hd6309_arith`) | Greg Miller's cycle-accurate 6809 as distributed in jtframe | GPL-3.0 (see file headers) |
| YM3812 (`jtopl2`) | jotego/jtopl (copy from the owner's Deniam core) | GPL-3.0-or-later |
| SDRAM controller | Sorgelig `sdram.sv` with the owner's NA-1 byte-enable and refresh deltas | GPL-3.0-or-later |
| CRT Adjust | MiSTer-CRT-Adjust `crt_adjust.sv` (Umberto Parisi / rmonic79), unmodified; glue from the owner's cores | GPL-3.0-or-later |
| Pause | JimmyStones `pause.v` | GPL-3.0-or-later |
| Microcode generator | `scripts/ucode_gen.py`: Python port of jtframe `ucode.go` | GPL-3.0-or-later |

## Local changes to vendored code

* `rtl/vendor/jt680x/jt680x_ctrl.v`: wire declarations moved above the generated-microcode include
  (the generated file assigns them; declaring after use is an error in ModelSim).
* `rtl/vendor/jtcpu/jt63701y.v`: the expanded-mode port blocking now decodes `addr[5:0]` (it used
  `addr[4:0]`, so P5DDR 0x20 aliased to P1DDR 0x00 and the MCU's port 5 direction write was lost
  and the 6502 waited forever on the MCU busy flag); new output `p5_ddr` (port 5 data direction), so
  the core can form
  MAME's port 5 write value `(data & ddr) | ~ddr` for the MCU status bits.
* `rtl/vendor/sdram.sv`: as in the owner's other cores (byte enables, refresh parameter).
