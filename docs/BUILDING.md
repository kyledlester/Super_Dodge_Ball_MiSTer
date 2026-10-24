# Building

## Requirements

* Intel Quartus Prime Lite **17.0** (the MiSTer standard; the `sys/` framework targets it).
* Windows PowerShell for `scripts/build.ps1` (or use the Quartus GUI).
* Python 3 for the MRAs (`scripts/romtool.py`) and the CPU microcode (`scripts/ucode_gen.py`).

## Compile

* GUI: open `SuperDodgeBall.qpf` and run *Processing > Start Compilation*.
* Command line: `powershell -ExecutionPolicy Bypass -File scripts\build.ps1`
  (`-MapOnly` for a synthesis-only check). The script waits until no other Quartus job is running on
  the machine, runs the full flow and writes `build/quartus.log` and `build/build-summary.txt`.

The post-flow script `scripts/release_rbf.tcl` copies `output_files/SuperDodgeBall.rbf` to
`Releases/SuperDodgeBall_YYYYMMDD.rbf`.

Timing: every setup and hold slack must be positive (`clk_sys` 96 MHz SDRAM, `clk_core` 48 MHz).

## CPU microcode

`jt65c02` and `jt680x` (jtcores) need generated microcode. `scripts/ucode_gen.py` is a Python port of
jtframe's `jtframe ucode` (no Go toolchain needed):

```
python scripts/ucode_gen.py rtl/vendor/jt680x 6301.yaml rtl/vendor/jt680x 6801
python scripts/ucode_gen.py rtl/vendor/jt680x 65c02.yaml rtl/vendor/jt680x 65c02
copy rtl\vendor\jt680x\*.uc .
```

The generated `.vh` / `.uc` files are committed; the `.uc` ROM images also sit in the project root
because `$readmemb` paths are resolved from there.

## MRAs

```
python scripts/romtool.py mra
python scripts/romtool.py check local/listxml.xml     # zips + `mame -listxml spdodgeb nkdodge nkdodgeb`
```

## Verification

The core was developed against MAME 0.289 with ModelSim benches (whole board, sound board, ADPCM,
loader) and MAME Lua capture scripts (frames, I/O and sound-chip write streams). That tooling depends
on locally captured MAME data and ROM images and is not part of this repository; the results are
summarised in [VERIFICATION.md](VERIFICATION.md).
