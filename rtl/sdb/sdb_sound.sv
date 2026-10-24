// Super Dodge Ball MiSTer core -- sound board: HD68A09 + YM3812 + 2 x MSM5205.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MAME 0.289 technos/spdodgeb.cpp:
//   0000-0FFF RAM   1000 R sound latch   2800-2801 W YM3812   3800-3807 W ADPCM   8000-FFFF ROM (32 KB)
//   IRQ = sound latch pending (cleared by reading 1000), FIRQ = YM3812 IRQ.
// Clocks (enables of the 48 MHz clk): 6809 E/Q 1.5 MHz (MAME 6 MHz / 4), YM3812 3 MHz, MSM5205 VCK
// 8 kHz (384 kHz / 48).
// Mix as MAME: YM3812 x 1.0 + each MSM5205 x 0.5. MAME's MSM5205 sample is (signal & ~3) / 4096
// (10-bit DAC) against the YM's 16-bit full scale, so each ADPCM channel adds (signal & ~3) * 4.
module sdb_sound (
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic        cen_e,          // 6809 E (end of bus cycle)
    input  logic        cen_q,          // 6809 Q (a quarter cycle earlier)
    input  logic        cen_opl,        // 3 MHz
    input  logic        vck,            // 8 kHz

    input  logic  [7:0] latch,
    input  logic        latch_wr,

    input  logic        rom_we,
    input  logic [14:0] rom_addr,
    input  logic  [7:0] rom_data,

    output logic        ad_req [2],
    output logic [25:1] ad_addr [2],
    input  logic        ad_ack [2],
    input  logic [63:0] mem_data,

    output logic signed [15:0] snd,
    output logic [15:0] dbg_latch_reads,
    output logic [15:0] dbg_ym_writes,
    output logic [15:0] dbg_adpcm_starts,
    output logic [15:0] dbg_firqs
);
    // ------------------------------------------------------------------ 6809
    logic [15:0] A;
    logic  [7:0] cpu_dout, cpu_din;
    logic        RnW, AVMA, VMA;
    logic        pending, ym_irq_n;
    wire         ce = cen_e & ~pause;
    wire         cq = cen_q & ~pause;

    mc6809i #(.HD6309(0)) cpu (
        .D(cpu_din), .DOut(cpu_dout), .ADDR(A), .RnW(RnW), .clk(clk),
        .cen_E(ce), .cen_Q(cq), .BS(), .BA(),
        .nIRQ(~pending), .nFIRQ(ym_irq_n), .nNMI(1'b1),
        .AVMA(AVMA), .BUSY(), .LIC(), .nHALT(1'b1), .nRESET(~reset), .nDMABREQ(1'b1),
        .OP(), .RegData(), .RegData6309());

    always_ff @(posedge clk)
        if (reset) VMA <= 1'b1;
        else if (ce) VMA <= AVMA;

    wire ram_cs   = A[15:12] == 4'h0;
    wire latch_cs = A == 16'h1000;
    wire ym_cs    = A[15:1] == 15'h1400;            // 2800-2801
    wire ad_cs    = A[15:3] == 13'h0700;            // 3800-3807
    wire wr_stb   = ce && VMA && !RnW;              // end of a valid write cycle

    logic [7:0] rom_q, ram_q;
    sdb_dpram #(.AW(15)) prog_rom (
        .clk(clk), .a_addr(rom_we ? rom_addr : A[14:0]), .a_we(rom_we), .a_din(rom_data), .a_dout(rom_q),
        .b_addr(15'd0), .b_dout());
    sdb_sdpram #(.AW(12)) ram (
        .clk(clk), .w_addr(A[11:0]), .we(wr_stb && ram_cs), .din(cpu_dout), .r_addr(A[11:0]), .dout(ram_q));

    logic [7:0] latch_q;
    always_comb begin
        cpu_din = 8'h00;
        if (A[15])        cpu_din = rom_q;
        else if (ram_cs)  cpu_din = ram_q;
        else if (latch_cs) cpu_din = latch_q;
    end

    // sound latch (generic_latch_8: reading clears the pending flag)
    always_ff @(posedge clk) begin
        if (reset) begin
            pending <= 1'b0; latch_q <= '0; dbg_latch_reads <= '0;
        end else begin
            if (ce && VMA && RnW && latch_cs) begin
                pending <= 1'b0;
                dbg_latch_reads <= dbg_latch_reads + 16'd1;
            end
            if (latch_wr) begin
                latch_q <= latch;
                pending <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------ YM3812
    logic signed [15:0] ym_snd;
    logic ym_irq_l;
    jtopl2 ym (
        .rst(reset), .clk(clk), .cen(cen_opl & ~pause), .din(cpu_dout), .addr(A[0]),
        .cs_n(!(wr_stb && ym_cs)), .wr_n(!(wr_stb && ym_cs)), .dout(), .irq_n(ym_irq_n),
        .snd(ym_snd), .sample());
    always_ff @(posedge clk) begin
        if (reset) begin
            dbg_ym_writes <= '0; dbg_firqs <= '0; ym_irq_l <= 1'b1;
        end else begin
            ym_irq_l <= ym_irq_n;
            if (wr_stb && ym_cs) dbg_ym_writes <= dbg_ym_writes + 16'd1;
            if (ym_irq_l && !ym_irq_n) dbg_firqs <= dbg_firqs + 16'd1;
        end
    end

    // ------------------------------------------------------------------ ADPCM
    logic signed [11:0] ad_sig [2];
    logic [15:0] starts [2];
    generate
    genvar i;
    for (i = 0; i < 2; i = i + 1) begin : g_ad
        logic [15:0] raddr;
        sdb_adpcm adpcm (
            .clk(clk), .rst(reset), .vck(vck & ~pause),
            .wr(wr_stb && ad_cs && A[0] == 1'(i)), .sel(A[2:1]), .din(cpu_dout),
            .rom_req(ad_req[i]), .rom_addr(raddr), .rom_ack(ad_ack[i]),
            .rom_data(raddr[0] ? mem_data[15:8] : mem_data[7:0]),
            .signal(ad_sig[i]), .dbg_starts(starts[i]));
        // SDRAM byte 080000 + 64 KB * channel + offset
        assign ad_addr[i] = 25'h040000 + {8'd0, 1'(i), raddr[15:1]};
    end
    endgenerate
    assign dbg_adpcm_starts = starts[0] + starts[1];

    // ------------------------------------------------------------------ mix
    always_ff @(posedge clk) begin
        logic signed [17:0] sum;
        sum = $signed({{2{ym_snd[15]}}, ym_snd})
            + $signed({{4{ad_sig[0][11]}}, ad_sig[0][11:2], 4'b0000})
            + $signed({{4{ad_sig[1][11]}}, ad_sig[1][11:2], 4'b0000});
        snd <= (sum > 18'sd32767) ? 16'h7FFF : (sum < -18'sd32768) ? 16'h8000 : sum[15:0];
    end
endmodule
