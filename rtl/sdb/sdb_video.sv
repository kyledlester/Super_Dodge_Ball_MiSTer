// Super Dodge Ball MiSTer core -- video: tilemap + sprite line renderers, palette.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MAME 0.289 technos/spdodgeb.cpp (docs/HARDWARE.md 5). One line ahead of the raster: at the start of
// display line d the engines draw line L = d+1 into line buffer bank L&1 while the output side reads
// bank d&1. Per-line registers (scroll, control) come from sdb_main's render-time history.
//
// Tilemap: 64 x 32 tiles of 8x8, 4bpp; video RAM word {attr, code} at (col&31) + row*32 + (col&32)*32;
// tile = code | attr[4:0] << 8, colour = attr[7:5] + 8 * tile palette bank (control[5:4]).
//   normal:  X = x + s,          Y = L            (s = scroll + 5, 9-bit wrap)
//   flipped: X = 127 - x - s,    Y = 239 - L      (MAME tilemap flip on a 384 x 272 bitmap)
// Sprites: 64 entries {x, code low, attr, y}; attr 7 = 16x32, 6 = !flipx, 5-3 colour, 2-0 code high;
// colour + 8 * sprite palette bank (control[7:6]); drawn in entry order (later on top), pen 0
// transparent; positions and wrap exactly as MAME draw_sprites.
// Pens: tile = {bank, colour, pixel} (0x000-0x1FF), sprite = 0x200 | {bank, colour, pixel}.
module sdb_video (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce_pix,
    input  logic  [8:0] hcount,
    input  logic  [8:0] vcount,
    input  logic        line_start,
    input  logic        hblank_in,
    input  logic        vblank_in,
    input  logic        hsync_in,
    input  logic        vsync_in,

    output logic  [4:0] hist_idx,
    input  logic [16:0] hist_q,         // {control, scroll}
    input  logic [16:0] live_q,

    output logic [10:0] vram_addr,
    input  logic [15:0] vram_q,
    output logic  [5:0] spr_addr,
    input  logic [31:0] spr_q,

    input  logic        prom_we,
    input  logic [10:0] prom_addr,
    input  logic  [7:0] prom_data,

    // SDRAM clients (sdb_sdram_arb): word addresses, 64-bit burst data valid with ack
    output logic        tm_req,
    output logic [25:1] tm_addr,
    input  logic        tm_ack,
    output logic        sp_req,
    output logic [25:1] sp_addr,
    input  logic        sp_ack,
    input  logic [63:0] mem_data,

    output logic [23:0] rgb,
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync,
    output logic [15:0] dbg_overruns
);
    // ------------------------------------------------------------------ line start / parameters
    logic       start_d, start;             // start: one clock after line_start (history written)
    logic [7:0] L;
    logic       render;
    always_ff @(posedge clk) begin
        start_d <= line_start;
        start   <= start_d;
    end
    wire [8:0] Ln = (vcount == 9'd271) ? 9'd0 : vcount + 9'd1;
    always_comb begin
        // idx = 0 for L <= 16, else ceil((L - 16) / 8) = (L - 9) >> 3
        hist_idx = (Ln <= 9'd16) ? 5'd0 : 5'((Ln - 9'd9) >> 3);
    end
    logic [8:0] s;
    logic       f;
    logic [1:0] tpal, spal;
    always_ff @(posedge clk) if (start_d) begin
        logic [16:0] p;
        p = (Ln == 9'd0) ? live_q : hist_q;
        L      <= Ln[7:0];
        render <= Ln < 9'd240;
        s      <= p[8:0] + 9'd5;
        f      <= p[9];
        tpal   <= p[14:13];
        spal   <= p[16:15];
    end

    // ------------------------------------------------------------------ line buffers
    // Port A: engine writes {bank = L&1, x}. Port B: output side reads {bank = d&1, x}; the sprite buffer
    // entry is cleared on the clock after it is read.
    logic [8:0] tlb_wa, slb_wa, lb_ra;
    logic [8:0] tlb_wd, slb_wd, tlb_q, slb_q;
    logic       tlb_we, slb_we, slb_clr;
    sdb_sdpram #(.AW(9), .DW(9)) tile_lb (
        .clk(clk), .w_addr(tlb_wa), .we(tlb_we), .din(tlb_wd), .r_addr(lb_ra), .dout(tlb_q));
    sdb_lbuf sprite_lb (
        .clk(clk), .a_addr(slb_wa), .a_we(slb_we), .a_din(slb_wd),
        .b_addr(lb_ra), .b_clr(slb_clr), .b_q(slb_q));

    // ------------------------------------------------------------------ tile engine
    typedef enum logic [2:0] {T_IDLE, T_ADDR, T_VWAIT, T_VRAM, T_MEM, T_PIX} tst_t;
    tst_t tst;
    logic [8:0]  tx;                        // screen x 0..255 (bit 8 = done)
    logic [31:0] trow;
    logic [2:0]  tcol;
    logic        tbusy;
    wire  [8:0]  X  = f ? (9'd127 - tx - s) : (tx + s);
    wire  [7:0]  Y  = f ? (8'd239 - L) : L;

    function automatic [3:0] tpix(input [31:0] row, input [2:0] px);
        logic [7:0] b;
        b = row[8 * px[2:1] +: 8];
        tpix = px[0] ? {b[7], b[5], b[3], b[1]} : {b[6], b[4], b[2], b[0]};
    endfunction

    always_ff @(posedge clk) begin
        tlb_we <= 1'b0;
        if (rst) begin
            tst <= T_IDLE; tm_req <= 1'b0; tbusy <= 1'b0;
        end else begin
            if (start) begin
                tx    <= '0;
                tbusy <= render;
                tst   <= render ? T_ADDR : T_IDLE;
            end else case (tst)
                T_IDLE: ;
                T_ADDR: begin
                    vram_addr <= {X[8], Y[7:3], X[7:3]};
                    tst <= T_VWAIT;
                end
                T_VWAIT: tst <= T_VRAM;             // block RAM read latency
                T_VRAM: begin
                    tcol    <= vram_q[15:13];
                    tm_addr <= {7'd0, vram_q[12:8], vram_q[7:0], Y[2:0], 1'b0};   // byte {tile, y, 0}
                    tm_req  <= 1'b1;
                    tst     <= T_MEM;
                end
                T_MEM: if (tm_ack) begin
                    tm_req <= 1'b0;
                    trow   <= mem_data[31:0];
                    tst    <= T_PIX;
                end
                T_PIX: begin
                    tlb_we <= 1'b1;
                    tlb_wa <= {L[0], tx[7:0]};
                    tlb_wd <= {tpal, tcol, tpix(trow, X[2:0])};
                    tx     <= tx + 9'd1;
                    if (tx == 9'd255) begin
                        tst <= T_IDLE; tbusy <= 1'b0;
                    end else if (X[2:0] == (f ? 3'd0 : 3'd7))
                        tst <= T_ADDR;              // the next dot is in the next tile
                end
                default: tst <= T_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ sprite engine
    typedef enum logic [2:0] {S_IDLE, S_ADDR, S_WAIT, S_EVAL, S_SUB, S_MEM, S_PIX} sst_t;
    sst_t sst;
    logic [6:0]  si;                        // entry (bit 6 = done)
    logic        sbusy;
    logic signed [9:0] sx, y0, y1;
    logic [10:0] c0, c1;
    logic [2:0]  scol;
    logic        sfx, sfy, dbl, sub;
    logic [3:0]  sc;
    logic [63:0] sdata;
    wire  signed [9:0] Ls = $signed({2'b00, L});

    function automatic [3:0] spix(input [63:0] d, input [3:0] col);
        logic [7:0] lo, hi;
        lo = d[8 * col[3:2] +: 8];
        hi = d[32 + 8 * col[3:2] +: 8];
        spix = {hi[{1'b1, col[1:0]}], hi[{1'b0, col[1:0]}], lo[{1'b1, col[1:0]}], lo[{1'b0, col[1:0]}]};
    endfunction

    always_ff @(posedge clk) begin
        slb_we <= 1'b0;
        if (rst) begin
            sst <= S_IDLE; sp_req <= 1'b0; sbusy <= 1'b0;
        end else begin
            if (start) begin
                si    <= '0;
                sbusy <= render;
                sst   <= render ? S_ADDR : S_IDLE;
            end else case (sst)
                S_IDLE: ;
                S_ADDR: begin
                    if (si[6]) begin
                        sst <= S_IDLE; sbusy <= 1'b0;
                    end else begin
                        spr_addr <= si[5:0];
                        sst <= S_WAIT;
                    end
                end
                S_WAIT: sst <= S_EVAL;
                S_EVAL: begin
                    logic signed [9:0] x, y, dy;
                    logic [7:0] attr;
                    logic [10:0] which;
                    attr  = spr_q[15:8];
                    which = {attr[2:0], spr_q[23:16]};
                    x  = $signed({2'b00, spr_q[31:24]});
                    y  = 10'sd240 - $signed({2'b00, spr_q[7:0]});
                    dy = -10'sd16;
                    sfx <= !attr[6];
                    sfy <= 1'b0;
                    if (f) begin
                        x  = 10'sd240 - x;
                        y  = 10'sd240 - y;
                        dy = 10'sd16;
                        sfx <= attr[6];
                        sfy <= 1'b1;
                    end
                    if (x < -10'sd8) x = x + 10'sd256;
                    else if (x > 10'sd248) x = x - 10'sd256;
                    if (!attr[7]) begin
                        if (y < -10'sd8) y = y + 10'sd256;
                        else if (y > 10'sd248) y = y - 10'sd256;
                        y0 <= y; c0 <= which;
                        dbl <= 1'b0;
                    end else begin
                        if (f) begin if (y > 10'sd240) y = y - 10'sd256; end
                        else   begin if (y < 10'sd0)   y = y + 10'sd256; end
                        y0 <= y + dy; c0 <= {which[10:1], 1'b0};
                        y1 <= y;      c1 <= {which[10:1], 1'b1};
                        dbl <= 1'b1;
                    end
                    sx   <= x;
                    scol <= attr[5:3];
                    sub  <= 1'b0;
                    sst  <= S_SUB;
                end
                S_SUB: begin
                    logic signed [9:0] yy, r;
                    yy = sub ? y1 : y0;
                    r  = Ls - yy;
                    if (r >= 10'sd0 && r <= 10'sd15) begin
                        sp_addr <= 25'h020000 + {7'd0, sub ? c1 : c0, sfy ? 4'(15 - r) : 4'(r), 2'b00};
                        sp_req  <= 1'b1;
                        sst     <= S_MEM;
                    end else if (dbl && !sub)
                        sub <= 1'b1;
                    else begin
                        si  <= si + 7'd1;
                        sst <= S_ADDR;
                    end
                end
                S_MEM: if (sp_ack) begin
                    sp_req <= 1'b0;
                    sdata  <= mem_data;
                    sc     <= '0;
                    sst    <= S_PIX;
                end
                S_PIX: begin
                    logic signed [9:0] px;
                    logic [3:0] p;
                    px = sx + $signed({6'd0, sc});
                    p  = spix(sdata, sfx ? 4'(15 - sc) : sc);
                    if (p != 4'd0 && px >= 10'sd0 && px <= 10'sd255) begin
                        slb_we <= 1'b1;
                        slb_wa <= {L[0], px[7:0]};
                        slb_wd <= {spal, scol, p};
                    end
                    sc <= sc + 4'd1;
                    if (sc == 4'd15) begin
                        // the two halves of a 16x32 sprite never cover the same line
                        si  <= si + 7'd1;
                        sst <= S_ADDR;
                    end
                end
                default: sst <= S_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) dbg_overruns <= '0;
        else if (start && (tbusy || sbusy)) dbg_overruns <= dbg_overruns + 16'd1;
    end

    // ------------------------------------------------------------------ palette (PROMs)
    logic [7:0] pal_rg_q, pal_b_q;
    logic [9:0] pen;
    sdb_sdpram #(.AW(10)) pal_rg (
        .clk(clk), .w_addr(prom_addr[9:0]), .we(prom_we && !prom_addr[10]), .din(prom_data),
        .r_addr(pen), .dout(pal_rg_q));
    sdb_sdpram #(.AW(10)) pal_b (
        .clk(clk), .w_addr(prom_addr[9:0]), .we(prom_we && prom_addr[10]), .din(prom_data),
        .r_addr(pen), .dout(pal_b_q));

    function automatic [7:0] weight(input [3:0] n);
        weight = (n[0] ? 8'h0e : 8'h00) + (n[1] ? 8'h1f : 8'h00) + (n[2] ? 8'h43 : 8'h00) + (n[3] ? 8'h8f : 8'h00);
    endfunction

    // ------------------------------------------------------------------ output
    // Edges after the ce_pix edge that registers lb_ra: E1 line-buffer data, E2 pen (and sprite entry
    // clear request), E3 palette data, E4 rgb_s. The next ce_pix (E8) outputs rgb_s with the
    // blanking/sync of the same dot.
    logic [3:0] ph;
    logic       active, act_d;
    logic       hb_d, vb_d, hs_d, vs_d;
    logic [23:0] rgb_s;
    wire  [8:0] d = vcount;
    always_ff @(posedge clk) begin
        ph <= {ph[2:0], ce_pix};
        slb_clr <= 1'b0;
        if (ce_pix) begin
            lb_ra  <= {d[0], hcount[7:0]};
            active <= !hblank_in && !vblank_in;
            {rgb, hblank, vblank, hsync, vsync} <= {rgb_s, hb_d, vb_d, hs_d, vs_d};
            {hb_d, vb_d, hs_d, vs_d} <= {hblank_in, vblank_in, hsync_in, vsync_in};
        end
        if (ph[1]) begin
            pen     <= (slb_q[3:0] != 4'd0) ? {1'b1, slb_q} : {1'b0, tlb_q};
            act_d   <= active;
            slb_clr <= active;
        end
        if (ph[3])
            rgb_s <= act_d ? {weight(pal_rg_q[3:0]), weight(pal_rg_q[7:4]), weight(pal_b_q[3:0])} : 24'h000000;
    end
endmodule

// Sprite line buffer: port A write, port B read with clear-after-read (b_clr writes 0 to b_addr).
module sdb_lbuf (
    input  logic       clk,
    input  logic [8:0] a_addr,
    input  logic       a_we,
    input  logic [8:0] a_din,
    input  logic [8:0] b_addr,
    input  logic       b_clr,
    output logic [8:0] b_q
);
    logic [8:0] mem [0:511];
    initial for (int i = 0; i < 512; i++) mem[i] = '0;
    always @(posedge clk) if (a_we) mem[a_addr] <= a_din;
    always @(posedge clk) begin
        if (b_clr) mem[b_addr] <= 9'd0;
        b_q <= mem[b_addr];
    end
endmodule
