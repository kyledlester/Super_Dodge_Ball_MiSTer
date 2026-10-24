// Super Dodge Ball MiSTer core -- raster timing.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 6 MHz pixel clock, 384 dots x 272 lines = 15.625 kHz / 57.44 Hz, exactly MAME's
// set_raw(12 MHz / 2, 384, 0, 256, 272, 0, 240). hcount/vcount are MAME's screen coordinates:
// visible x 0..255, y 0..239; the main CPU's scanline interrupts are generated from vcount.
// Sync placement is a MiSTer/CRT choice (not PCB-verified; CRT Adjust can move the picture):
//   H: active 0..255, front porch 256..279, HSync 280..311 (5.3 us), back porch 312..383.
//   V: active 0..239, front porch 240..249, VSync 250..252, back porch 253..271.
// line_start: one clk_sys pulse on the ce_pix that enters dot 0 of a line, with vcount valid.
module sdb_video_timing (
    input  logic       clk,
    input  logic       rst,
    input  logic       ce_pix,
    output logic [8:0] hcount,     // 0..383
    output logic [8:0] vcount,     // 0..271
    output logic       hblank,
    output logic       vblank,
    output logic       hsync,
    output logic       vsync,
    output logic       line_start
);
    always_ff @(posedge clk) begin
        line_start <= 1'b0;
        if (rst) begin
            hcount <= '0;
            vcount <= 9'd240;
        end else if (ce_pix) begin
            if (hcount == 9'd383) begin
                hcount     <= '0;
                vcount     <= (vcount == 9'd271) ? 9'd0 : vcount + 9'd1;
                line_start <= 1'b1;
            end else
                hcount <= hcount + 9'd1;
        end
    end

    always_comb begin
        hblank = hcount >= 9'd256;
        vblank = vcount >= 9'd240;
        hsync  = (hcount >= 9'd280) && (hcount <= 9'd311);
        vsync  = (vcount >= 9'd250) && (vcount <= 9'd252);
    end
endmodule
