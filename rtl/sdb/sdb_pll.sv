// Super Dodge Ball MiSTer core -- system PLL.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One PLL: 50 MHz board clock -> clk_sys = 96 MHz (SDRAM controller and its arbiter: the controller,
// its read-capture timing and the SDRAM pin constraints are the ones hardware-proven at 96-100 MHz in
// the owner's Final Star Force / NA-1 / NB-1 cores) and clk_core = 48 MHz = 4 x the board's 12 MHz
// crystal, phase aligned (everything else; every chip clock is an exact enable of it, sdb_core.sv).
//
// HIERARCHY IS LOAD-BEARING: sys/sys_top.sdc places the core clocks in their own clock group only if
// they match *|pll|pll_inst|altera_pll_i|*[*].*|divclk, so emu instantiates this module as "pll"
// (same shape as a MegaWizard MiSTer PLL; pattern from the owner's Final Star Force / NB-1 cores).
module sdb_pll (
    input  wire refclk,   // CLK_50M
    input  wire rst,
    output wire clk_sys,  // 96 MHz
    output wire clk_core, // 48 MHz = clk_sys / 2, phase aligned
    output wire locked
);
    sdb_pll_core pll_inst (
        .refclk(refclk),
        .rst(rst),
        .clk_sys(clk_sys),
        .clk_core(clk_core),
        .locked(locked)
    );
endmodule

module sdb_pll_core (
    input  wire refclk,
    input  wire rst,
    output wire clk_sys,
    output wire clk_core,
    output wire locked
);
    wire [1:0] clocks;

    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(2),
        .output_clock_frequency0("96.000000 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("48.000000 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .refclk(refclk),
        .rst(rst),
        .outclk(clocks),
        .locked(locked),
        .fboutclk(),
        .fbclk(1'b0)
    );

    assign clk_sys  = clocks[0];
    assign clk_core = clocks[1];
endmodule
