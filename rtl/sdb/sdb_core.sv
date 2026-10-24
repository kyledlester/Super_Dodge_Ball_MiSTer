// Super Dodge Ball MiSTer core -- board top (Technos TA-0022: spdodgeb, nkdodge, nkdodgeb).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// docs/ARCHITECTURE.md, docs/HARDWARE.md. Everything runs on clk (48 MHz = 4 x 12 MHz) with clock
// enables, except the SDRAM arbiter (clk_sdram, 96 MHz, two-clock acks):
//   ce_pix 6 MHz (/8), 6502 8 MHz cen (/6), MCU 4 MHz (/12), 6809 E/Q 1.5 MHz (/32), YM3812 3 MHz
//   (/16), MSM5205 VCK 8 kHz (384 kHz / 48 = /6000)
//   sdb_video_timing -> 384 x 272 raster      sdb_loader -> ROM stream to block RAM / SDRAM
//   sdb_main  -> 6502 + MCU board              sdb_video  -> tilemap, sprites, palette
//   sdb_sound -> 6809, YM3812, 2 x MSM5205     sdb_sdram_arb -> loader > ADPCM 0/1 > tiles > sprites
module sdb_core (
    input  logic        clk,            // 48 MHz
    input  logic        clk_sdram,      // 96 MHz: SDRAM arbiter (and the sdram controller in emu)
    input  logic        init,
    input  logic        reset_in,
    input  logic        pause,

    input  logic        ioctl_download,
    input  logic [15:0] ioctl_index,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    output logic        ioctl_wait,

    output logic [26:1] sd_addr,
    output logic [15:0] sd_din,
    output logic  [1:0] sd_be,
    output logic        sd_req,
    output logic        sd_rnw,
    input  logic [63:0] sd_dout,
    input  logic        sd_ready,

    input  logic [31:0] joy0,
    input  logic [31:0] joy1,
    input  logic        service,
    input  logic        test_pattern,
    input  logic        dbg_overlay,

    output logic        ce_pix,
    output logic [23:0] rgb,
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync,
    output logic        vb_next,
    output logic signed [15:0] snd
);
    // ------------------------------------------------------------------ clock enables
    logic [2:0]  c8 = '0;
    logic [2:0]  c6 = '0;
    logic [3:0]  c12 = '0;
    logic [4:0]  c32 = '0;
    logic [12:0] cvck = '0;
    logic        cen_cpu = 1'b0, cen_mcu = 1'b0, cen_e = 1'b0, cen_q = 1'b0, cen_opl = 1'b0, vck = 1'b0;
    always_ff @(posedge clk) begin
        c8   <= c8 + 3'd1;
        c6   <= (c6 == 3'd5) ? 3'd0 : c6 + 3'd1;
        c12  <= (c12 == 4'd11) ? 4'd0 : c12 + 4'd1;
        c32  <= c32 + 5'd1;
        cvck <= (cvck == 13'd5999) ? 13'd0 : cvck + 13'd1;
        ce_pix  <= c8 == 3'd7;
        cen_cpu <= c6 == 3'd5;
        cen_mcu <= c12 == 4'd11;
        cen_e   <= c32 == 5'd31;
        cen_q   <= c32 == 5'd15;
        cen_opl <= c32[3:0] == 4'd15;
        vck     <= cvck == 13'd5999;
    end

    // reset stretched to >= 1024 clocks after the request ends (jtopl needs 6+ clock enables of reset,
    // and a short OSD reset pulse must still clear every block)
    logic [10:0] rst_cnt = '0;
    logic        reset = 1'b1;
    always_ff @(posedge clk) begin
        if (reset_in) rst_cnt <= '0;
        else if (!rst_cnt[10]) rst_cnt <= rst_cnt + 11'd1;
        reset <= reset_in || !rst_cnt[10];
    end

    logic [8:0] hcount, vcount;
    logic hb, vb, hs, vs, line_start;
    sdb_video_timing timing (
        .clk(clk), .rst(init), .ce_pix(ce_pix),
        .hcount(hcount), .vcount(vcount), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
        .line_start(line_start));

    // ------------------------------------------------------------------ DIP switches (index 254)
    // byte 0 = DSW (3001); byte 1: bits 7-6 difficulty (IN0), bit 2 allow continue, bit 1 unknown (IN1)
    logic [7:0] dsw = 8'hFF, dsw2 = 8'hC6;
    always_ff @(posedge clk)
        if (ioctl_download && ioctl_wr && ioctl_index == 16'd254) begin
            if (ioctl_addr == 27'd0) dsw  <= ioctl_dout;
            if (ioctl_addr == 27'd1) dsw2 <= ioctl_dout;
        end

    // ------------------------------------------------------------------ inputs
    // MiSTer joystick: 0 right, 1 left, 2 down, 3 up, 4 button 1, 5 button 2, 6 start, 7 coin, 8 pause.
    // MCU ports (active low): 0 right, 1 left, 2 up, 3 down, 4 button 1, 5 button 2, 6 start 1 / -,
    // 7 start 2 / -.
    wire [7:0] p1 = ~{joy1[6], joy0[6], joy0[5], joy0[4], joy0[2], joy0[3], joy0[1], joy0[0]};
    wire [7:0] p2 = ~{2'b00,            joy1[5], joy1[4], joy1[2], joy1[3], joy1[1], joy1[0]};
    wire [2:0] coin_svc = ~{service, joy1[7], joy0[7]};

    // ------------------------------------------------------------------ loader
    logic        ld_req, ld_ack;
    logic [25:1] ld_addr;
    logic [15:0] ld_wdata;
    logic  [1:0] ld_be;
    logic        rom_we, prom_we, loaded;
    logic [16:0] rom_addr;
    logic [10:0] prom_addr;
    logic  [7:0] rom_data;
    sdb_loader loader (
        .clk(clk), .rst(init),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
        .mem_req(ld_req), .mem_addr(ld_addr), .mem_wdata(ld_wdata), .mem_be(ld_be), .mem_ack(ld_ack),
        .rom_we(rom_we), .rom_addr(rom_addr), .prom_we(prom_we), .prom_addr(prom_addr), .rom_data(rom_data),
        .loaded(loaded));

    // ------------------------------------------------------------------ main board
    logic [10:0] vram_addr;
    logic [15:0] vram_q;
    logic  [5:0] spr_addr;
    logic [31:0] spr_q;
    logic  [4:0] hist_idx;
    logic [16:0] hist_q, live_q;
    logic  [7:0] latch;
    logic        latch_wr;
    logic [15:0] dbg_pc, dbg_irqs, dbg_nmis, dbg_mcu_nmis;
    sdb_main main (
        .clk(clk), .reset(reset), .cen_cpu(cen_cpu), .cen_mcu(cen_mcu), .vcount(vcount),
        .line_start(line_start), .pause(pause),
        .rom_we(rom_we && (rom_addr[16] == 1'b0 || rom_addr[16:14] == 3'b110)), .rom_addr(rom_addr),
        .rom_data(rom_data),
        .dsw(dsw), .dsw2(dsw2), .p1(p1), .p2(p2), .coin_svc(coin_svc),
        .vram_addr(vram_addr), .vram_q(vram_q), .spr_addr(spr_addr), .spr_q(spr_q),
        .hist_idx(hist_idx), .hist_q(hist_q), .live_q(live_q),
        .snd_latch(latch), .snd_latch_wr(latch_wr),
        .dbg_pc(dbg_pc), .dbg_irqs(dbg_irqs), .dbg_nmis(dbg_nmis), .dbg_mcu_nmis(dbg_mcu_nmis));

    // ------------------------------------------------------------------ video
    logic        tm_req, tm_ack, sp_req, sp_ack;
    logic [25:1] tm_addr, sp_addr;
    logic [63:0] mem_rdata;
    logic [23:0] vid_rgb;
    logic        vhb, vvb, vhs, vvs;
    logic [15:0] dbg_overruns;
    sdb_video video (
        .clk(clk), .rst(reset), .ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .line_start(line_start),
        .hblank_in(hb), .vblank_in(vb), .hsync_in(hs), .vsync_in(vs),
        .hist_idx(hist_idx), .hist_q(hist_q), .live_q(live_q),
        .vram_addr(vram_addr), .vram_q(vram_q), .spr_addr(spr_addr), .spr_q(spr_q),
        .prom_we(prom_we), .prom_addr(prom_addr), .prom_data(rom_data),
        .tm_req(tm_req), .tm_addr(tm_addr), .tm_ack(tm_ack),
        .sp_req(sp_req), .sp_addr(sp_addr), .sp_ack(sp_ack), .mem_data(mem_rdata),
        .rgb(vid_rgb), .hblank(vhb), .vblank(vvb), .hsync(vhs), .vsync(vvs), .dbg_overruns(dbg_overruns));

    // ------------------------------------------------------------------ sound
    logic        ad_req [2], ad_ack [2];
    logic [25:1] ad_addr [2];
    logic [15:0] dbg_lat_rd, dbg_ym, dbg_ad, dbg_firq;
`ifdef SDB_SIM_NO_SOUND
    assign snd = '0; assign ad_req[0] = 1'b0; assign ad_req[1] = 1'b0;
    assign ad_addr[0] = '0; assign ad_addr[1] = '0;
    assign {dbg_lat_rd, dbg_ym, dbg_ad, dbg_firq} = '0;
`else
    sdb_sound sound (
        .clk(clk), .reset(reset), .pause(pause), .cen_e(cen_e), .cen_q(cen_q), .cen_opl(cen_opl), .vck(vck),
        .latch(latch), .latch_wr(latch_wr),
        .rom_we(rom_we && rom_addr[16:15] == 2'b10), .rom_addr(rom_addr[14:0]), .rom_data(rom_data),
        .ad_req(ad_req), .ad_addr(ad_addr), .ad_ack(ad_ack), .mem_data(mem_rdata),
        .snd(snd), .dbg_latch_reads(dbg_lat_rd), .dbg_ym_writes(dbg_ym), .dbg_adpcm_starts(dbg_ad),
        .dbg_firqs(dbg_firq));
`endif

    // ------------------------------------------------------------------ SDRAM
    logic [4:0]  arb_ack;
    logic [25:1] arb_addr [5];
    assign arb_addr[0] = ld_addr;
    assign arb_addr[1] = ad_addr[0];
    assign arb_addr[2] = ad_addr[1];
    assign arb_addr[3] = tm_addr;
    assign arb_addr[4] = sp_addr;
    sdb_sdram_arb #(.N(5)) arb (
        .clk(clk_sdram), .rst(init),
        .req({sp_req, tm_req, ad_req[1], ad_req[0], ld_req}), .addr(arb_addr), .we(5'b00001),
        .wdata(ld_wdata), .wbe(ld_be), .ack(arb_ack), .rdata(mem_rdata),
        .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be), .sd_req(sd_req), .sd_rnw(sd_rnw),
        .sd_dout(sd_dout), .sd_ready(sd_ready));
    assign ld_ack    = arb_ack[0];
    assign ad_ack[0] = arb_ack[1];
    assign ad_ack[1] = arb_ack[2];
    assign tm_ack    = arb_ack[3];
    assign sp_ack    = arb_ack[4];

    // ------------------------------------------------------------------ output (test pattern / debug overlay)
    logic [23:0] ovl_rgb;
    sdb_overlay overlay (
        .clk(clk), .ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .enable(dbg_overlay),
        .values({ {16'h0000, dbg_pc}, {dbg_irqs, dbg_nmis}, {dbg_mcu_nmis, dbg_lat_rd},
                  {dbg_ym, dbg_firq}, {dbg_ad, dbg_overruns}, {31'd0, loaded} }),
        .rgb_in(vid_rgb), .rgb_out(ovl_rgb));

    always_ff @(posedge clk) if (ce_pix) begin
        if (test_pattern) begin
            // 8 colour bars across the active width with a white border, raster timing unchanged
            if (hcount == 9'd1 || hcount == 9'd256 || vcount == 9'd0 || vcount == 9'd239)
                rgb <= 24'hFFFFFF;
            else begin
                logic [2:0] bar;
                bar = 3'((hcount - 9'd1) >> 5);
                rgb <= {{8{bar[2]}}, {8{bar[1]}}, {8{bar[0]}}};
            end
        end else
            rgb <= ovl_rgb;
        {hblank, vblank, hsync, vsync} <= {vhb, vvb, vhs, vvs};
        // the output stream lags the raster counters by two dots, so vcount is still the output line
        // when its active area ends (where sdb_crt_adjust samples this)
        vb_next <= !(vcount == 9'd271 || vcount + 9'd1 < 9'd240);
    end
endmodule
