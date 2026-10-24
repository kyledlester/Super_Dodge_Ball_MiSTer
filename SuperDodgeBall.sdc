# Super Dodge Ball MiSTer core -- core timing constraints (sys/sys_top.sdc covers the framework).
# Taken unchanged from the owner's Final Star Force core, which uses the same PLL shape (96 + 48 MHz).
# Clocks from rtl/sdb/sdb_pll.sv: clk_sys = 96 MHz (SDRAM controller and arbiter), clk_core = 48 MHz
# (phase aligned; everything else, every chip clock an enable of it). The 96/48 crossings are
# synchronous (same PLL) and timed by the analyzer.
derive_pll_clocks

# ---------------------------------------------------------------------------
# SDRAM pins (rtl/vendor/sdram.sv, clocked by clk_sys). Values as in the owner's hardware-proven
# NA-1 (100 MHz) and NB-1 cores. The controller launches address/command/write data on clk_sys's
# rising edge; altddio_out drives SDRAM_CLK as an inverted copy of clk_sys.
set sdb_core_clock_pin [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|*|divclk}]
create_generated_clock -name SDRAM_CLK -source $sdb_core_clock_pin \
    -divide_by 1 -invert [get_ports {SDRAM_CLK}]

set_input_delay -max -clock SDRAM_CLK 6.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay -min -clock SDRAM_CLK 3.7 [get_ports {SDRAM_DQ[*]}]

# Read capture on the second clk_sys edge after the launching SDRAM_CLK edge (CL=2 data_ready_delay).
set_multicycle_path -setup 2 -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks {*|pll|pll_inst|altera_pll_i|*|divclk}]

set sdb_sdram_outputs [get_ports {
    SDRAM_A[*] SDRAM_BA[*]
    SDRAM_nCS SDRAM_nWE SDRAM_nRAS SDRAM_nCAS
    SDRAM_DQMH SDRAM_DQML SDRAM_DQ[*]
}]
set_output_delay -max -clock SDRAM_CLK 1.6 $sdb_sdram_outputs
set_output_delay -min -clock SDRAM_CLK -0.9 $sdb_sdram_outputs

# ---------------------------------------------------------------------------
# Framework HQ2x Blend (sys/hq2x.sv inside arcade_video). Same constraint and reasoning as the owner's
# hardware-proven NA-1 core at 100 MHz: Blend only advances on the scandoubler's 4x pixel enable
# (here 4 x 6 MHz = every 2 clk_core cycles, never on consecutive cycles), so its internal
# register-to-register paths have at least two clocks.
set_multicycle_path -setup 2 -from [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]     -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
set_multicycle_path -hold 1 -from [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]     -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]

derive_clock_uncertainty
