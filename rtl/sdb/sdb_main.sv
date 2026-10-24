// Super Dodge Ball MiSTer core -- main board: 6502, HD63701Y0 input/protection MCU, memory map, I/O.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MAME 0.289 technos/spdodgeb.cpp (docs/HARDWARE.md):
//   0000-0FFF RAM            1000-10FF sprite RAM (write only)   2000-2FFF video RAM
//   3000 R IN0               3001 R DSW                          3002 W sound latch
//   3004 W scroll low        3005 W MCU NMI                      3006 W control
//   3800 W MCU latch         3801-3805 R MCU-written input bytes
//   4000-7FFF ROM bank (ROM 0000 / 4000, control bit 1 low selects 4000)   8000-FFFF ROM 8000-FFFF
// IN0: 0 vblank, 1 MCU busy (P5 bit 7), 2 1, 3 coin1, 4 coin2, 5 service (active low), 7-6 difficulty.
// Interrupts: IRQ held from the start of every line that is a multiple of 8 (except 256) until the
// 6502 fetches the IRQ vector (MAME HOLD_LINE); NMI pulse at the start of line 256.
// MCU (expanded mode 2, internal ROM C000-FFFF): P2 = player 1, P6 = player 2, P5 in = IN1 DIPs,
// P5 out bits 7-6 = status; external 8080 R = latch, 8081-8085 W = input bytes for the 6502.
module sdb_main (
    input  logic        clk,            // 48 MHz
    input  logic        reset,
    input  logic        cen_cpu,        // 8 MHz = 4 x 6502 E (2 MHz)
    input  logic        cen_mcu,        // 4 MHz MCU crystal (1 MHz E)
    input  logic  [8:0] vcount,
    input  logic        line_start,
    input  logic        pause,

    // ROM download (block RAM)
    input  logic        rom_we,
    input  logic [16:0] rom_addr,
    input  logic  [7:0] rom_data,

    // inputs
    input  logic  [7:0] dsw,            // DSW (3001), MAME port value
    input  logic  [7:0] dsw2,           // [7:6] difficulty (IN0), [2:1] IN1 DIPs
    input  logic  [7:0] p1,             // MCU P2 (active low)
    input  logic  [7:0] p2,             // MCU P6 (active low)
    input  logic  [2:0] coin_svc,       // {service, coin2, coin1} active low

    // video
    input  logic [10:0] vram_addr,      // video read port: word address (code at a, attribute at a+0x800)
    output logic [15:0] vram_q,         // {attribute, code}
    input  logic  [5:0] spr_addr,       // sprite entry
    output logic [31:0] spr_q,          // {x, code low, attribute, y}
    input  logic  [4:0] hist_idx,       // render-time register history (see below)
    output logic [16:0] hist_q,         // {control[7:0] , scroll[8:0]} at the start of line 8*hist_idx
    output logic [16:0] live_q,         // current {control, scroll}

    // sound board
    output logic  [7:0] snd_latch,
    output logic        snd_latch_wr,

    // debug
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_irqs,
    output logic [15:0] dbg_nmis,
    output logic [15:0] dbg_mcu_nmis
);
    // ------------------------------------------------------------------ 6502
    logic [15:0] A;
    logic  [7:0] cpu_dout, cpu_din;
    logic        cpu_wr, cpu_rd, irq, nmi;

    jt65c02 cpu (
        .rst(reset), .clk(clk), .cen(cen_cpu & ~pause),
        .irq(irq), .nmi(nmi), .opdec(1'b0),
        .wr(cpu_wr), .rd(cpu_rd), .fetch(),
        .addr(A), .din(cpu_din), .dout(cpu_dout));

    // one-clock strobes at the start of each bus cycle that accesses a side-effect address
    logic wr_l, rd_l;
    logic [15:0] A_l;
    always_ff @(posedge clk) begin
        wr_l <= cpu_wr;
        rd_l <= cpu_rd;
        A_l  <= A;
    end
    wire wr_stb = cpu_wr && (!wr_l || A != A_l);
    wire rd_stb = cpu_rd && (!rd_l || A != A_l);

    // ------------------------------------------------------------------ memories
    logic bank;                                     // 1: ROM 4000-7FFF at 4000
    wire [15:0] prog_a = A[15] ? A : {1'b0, bank, A[13:0]};
    logic [7:0] rom_q, ram_q, vram_cpu_q;

    sdb_dpram #(.AW(16)) prog_rom (
        .clk(clk), .a_addr(rom_we ? rom_addr[15:0] : prog_a), .a_we(rom_we && rom_addr[16] == 1'b0),
        .a_din(rom_data), .a_dout(rom_q), .b_addr(16'd0), .b_dout());

    wire ram_cs  = A[15:12] == 4'h0;
    wire spr_cs  = A[15:8]  == 8'h10;
    wire vram_cs = A[15:12] == 4'h2;
    sdb_sdpram #(.AW(12)) work_ram (
        .clk(clk), .w_addr(A[11:0]), .we(cpu_wr && ram_cs), .din(cpu_dout),
        .r_addr(A[11:0]), .dout(ram_q));

    // video RAM: two 2 KB halves (code 2000-27FF, attribute 2800-2FFF) so the renderer reads both at once
    logic [7:0] vlo_q, vhi_q;
    sdb_dpram #(.AW(11)) vram_lo (
        .clk(clk), .a_addr(A[10:0]), .a_we(cpu_wr && vram_cs && !A[11]), .a_din(cpu_dout), .a_dout(vlo_q),
        .b_addr(vram_addr), .b_dout(vram_q[7:0]));
    sdb_dpram #(.AW(11)) vram_hi (
        .clk(clk), .a_addr(A[10:0]), .a_we(cpu_wr && vram_cs && A[11]), .a_din(cpu_dout), .a_dout(vhi_q),
        .b_addr(vram_addr), .b_dout(vram_q[15:8]));
    assign vram_cpu_q = A[11] ? vhi_q : vlo_q;

    // sprite RAM: four byte lanes of 64 entries
    generate
    genvar i;
    for (i = 0; i < 4; i = i + 1) begin : g_spr
        sdb_sdpram #(.AW(6)) spr_ram (
            .clk(clk), .w_addr(A[7:2]), .we(cpu_wr && spr_cs && A[1:0] == 2'(i)), .din(cpu_dout),
            .r_addr(spr_addr), .dout(spr_q[8*i +: 8]));
    end
    endgenerate

    // ------------------------------------------------------------------ registers
    logic [8:0] scroll;
    logic [7:0] ctrl;
    logic [7:0] mcu_latch;
    logic [7:0] mcu_in [5];
    logic [7:0] mcu_status;
    logic       mcu_nmi_req;
    logic [4:0] mcu_nmi_cnt;

    wire io_wr = wr_stb && A[15:12] == 4'h3;
    always_ff @(posedge clk) begin
        snd_latch_wr <= 1'b0;
        if (reset) begin
            scroll <= '0;
            ctrl   <= '0;
            bank   <= 1'b0;
            mcu_nmi_cnt <= '0;
            mcu_latch <= '0;
        end else begin
            if (mcu_nmi_cnt != 0) mcu_nmi_cnt <= mcu_nmi_cnt - 5'd1;
            if (io_wr) case (A[11:0])
                12'h002: begin snd_latch <= cpu_dout; snd_latch_wr <= 1'b1; end
                12'h004: scroll[7:0] <= cpu_dout;
                12'h005: mcu_nmi_cnt <= 5'd31;               // > one MCU clock enable (12 clocks)
                12'h006: begin
                    ctrl      <= cpu_dout;
                    scroll[8] <= cpu_dout[2];
                    bank      <= ~cpu_dout[1];
                end
                12'h800: mcu_latch <= cpu_dout;
                default: ;
            endcase
        end
    end
    assign live_q = {ctrl, scroll};

    // ------------------------------------------------------------------ read mux
    wire vblank = vcount >= 9'd240;
    wire [7:0] in0 = {dsw2[7:6], coin_svc[2], coin_svc[1], coin_svc[0], 1'b1, mcu_status[7], vblank};
    always_comb begin
        cpu_din = 8'h00;                            // unmapped reads return 0 (MAME default)
        if (A[15] || A[15:14] == 2'b01) cpu_din = rom_q;
        else if (ram_cs)  cpu_din = ram_q;
        else if (vram_cs) cpu_din = vram_cpu_q;
        else if (A == 16'h3000) cpu_din = in0;
        else if (A == 16'h3001) cpu_din = dsw;
        else if (A >= 16'h3801 && A <= 16'h3805) cpu_din = mcu_in[A[2:0] - 3'd1];
    end

    // ------------------------------------------------------------------ interrupts
    // The scanline timer fires at hcount 0 of each line (MAME configure_scanline at hpos 0).
    always_ff @(posedge clk) begin
        if (reset) begin
            irq <= 1'b0;
            nmi <= 1'b0;
            dbg_irqs <= '0; dbg_nmis <= '0;
        end else begin
            if (line_start && !pause) begin
                if (vcount == 9'd256) begin
                    nmi <= 1'b1;
                    dbg_nmis <= dbg_nmis + 16'd1;
                end else if (vcount[2:0] == 3'd0) begin
                    irq <= 1'b1;
                    dbg_irqs <= dbg_irqs + 16'd1;
                end
            end
            if (line_start && vcount == 9'd257) nmi <= 1'b0;
            if (rd_stb && A == 16'hFFFE) irq <= 1'b0;   // vector fetch acknowledges the held IRQ
        end
    end

    // ------------------------------------------------------------------ render-time register history
    // MAME renders up to line N+16 when the IRQ at line N fires, before the CPU runs its handler, so
    // the scroll / palette bank / flip used for line L are the values at the start of line
    // 8*ceil((L-16)/8) (0 for L <= 16). Snapshot them at the start of every line that is a multiple
    // of 8 (0..232).
    logic [16:0] hist [32];
    always_ff @(posedge clk)
        if (line_start && vcount[2:0] == 3'd0 && vcount < 9'd256)
            hist[vcount[7:3]] <= {ctrl, scroll};
    assign hist_q = hist[hist_idx];

    // ------------------------------------------------------------------ MCU
    logic [7:0] mcu_p1o, mcu_p3o, mcu_p4o, mcu_p5o, mcu_p5ddr;
    logic [4:0] mcu_p7o;
    logic [13:0] mrom_a;
    logic [7:0] mrom_q;
    logic       mrom_cs;
    wire [15:0] mA = {mcu_p4o, mcu_p1o};
    wire        m_rd = !mcu_p7o[0];                 // external read
    wire        m_wr = !mcu_p7o[1];                 // external write

    sdb_dpram #(.AW(14)) mcu_rom (
        .clk(clk), .a_addr(rom_we ? rom_addr[13:0] : mrom_a), .a_we(rom_we && rom_addr[16:14] == 3'b110),
        .a_din(rom_data), .a_dout(mrom_q), .b_addr(14'd0), .b_dout());

    jt63701y #(.ROMW(14), .MODE(2'd2)) mcu (
        .rst(reset), .clk(clk), .cen(cen_mcu & ~pause),
        .nmi(mcu_nmi_cnt != 0),
        .p1_din(8'hFF), .p2_din(p1), .p3_din(m_rd && mA == 16'h8080 ? mcu_latch : 8'h00),
        .p4_din(8'hFF), .p5_din({2'b00, 3'b111, dsw2[2], dsw2[1], 1'b1}), .p6_din(p2),
        .p1_dout(mcu_p1o), .p2_dout(), .p3_dout(mcu_p3o), .p4_dout(mcu_p4o), .p5_dout(mcu_p5o),
        .p6_dout(), .p7_dout(mcu_p7o), .p5_ddr(mcu_p5ddr),
        .rom_addr(mrom_a), .rom_data(mrom_q), .rom_cs(mrom_cs));

    // P5 output -> status. MAME's m6801 port write value is (data & ddr) | ~ddr and mcu_status_w keeps
    // bits 7-6. MAME only calls it on P5 data/DDR writes; the first such write follows reset, so the
    // status stays 0 until the MCU has touched P5 (as machine_reset leaves it).
    logic p5_touched;
    always_ff @(posedge clk) begin
        if (reset) begin
            mcu_status <= '0;
            p5_touched <= 1'b0;
            for (int i = 0; i < 5; i++) mcu_in[i] <= '0;
            dbg_mcu_nmis <= '0;
        end else begin
            if (mcu_p5ddr != 0 || mcu_p5o != 0) p5_touched <= 1'b1;
            if (p5_touched) mcu_status <= ((mcu_p5o & mcu_p5ddr) | ~mcu_p5ddr) & 8'hC0;
            if (m_wr && mA >= 16'h8081 && mA <= 16'h8085) mcu_in[mA[2:0] - 3'd1] <= mcu_p3o;
            if (io_wr && A[11:0] == 12'h005) dbg_mcu_nmis <= dbg_mcu_nmis + 16'd1;
        end
    end

    always_ff @(posedge clk) if (cpu_rd && cen_cpu) dbg_pc <= A;
endmodule
