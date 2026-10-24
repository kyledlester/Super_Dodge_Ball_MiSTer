// Super Dodge Ball MiSTer core -- one ADPCM channel: the board's sample sequencer + MSM5205.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Written to match MAME 0.289 exactly (spdodgeb.cpp adpcm_w / adpcm_int and msm5205.cpp
// update_adpcm), including the free-running VCK: the sequencer runs on every VCK even while the MSM
// is held in reset, as MAME's legacy VCK callback does.
//   write sel 0: start (reset off)   1: end = (d & 0x7f) * 0x200   2: pos = (d & 0x7f) * 0x200
//         sel 3: stop (reset on)
//   each VCK: if pos >= end: reset on
//             else if a low nibble is pending: MSM data = it
//             else: byte = rom[pos++], MSM data = high nibble, low nibble pending
//             then MSM: reset ? (signal = 0, step = 0) : ADPCM step (12-bit signal, 49 steps)
// The ROM byte at pos is prefetched from SDRAM whenever pos changes (VCK period = 6000 clocks).
module sdb_adpcm (
    input  logic        clk,
    input  logic        rst,
    input  logic        vck,            // one clock per VCK (384 kHz / 48 = 8 kHz)

    input  logic        wr,
    input  logic  [1:0] sel,
    input  logic  [7:0] din,

    output logic        rom_req,
    output logic [15:0] rom_addr,       // byte offset in this channel's 64 KB
    input  logic        rom_ack,
    input  logic  [7:0] rom_data,

    output logic signed [11:0] signal,
    output logic [15:0] dbg_starts
);
    localparam logic [10:0] STEPVAL [49] = '{
        11'd16, 11'd17, 11'd19, 11'd21, 11'd23, 11'd25, 11'd28, 11'd31, 11'd34, 11'd37, 11'd41,
        11'd45, 11'd50, 11'd55, 11'd60, 11'd66, 11'd73, 11'd80, 11'd88, 11'd97, 11'd107, 11'd118,
        11'd130, 11'd143, 11'd157, 11'd173, 11'd190, 11'd209, 11'd230, 11'd253, 11'd279, 11'd307,
        11'd337, 11'd371, 11'd408, 11'd449, 11'd494, 11'd544, 11'd598, 11'd658, 11'd724, 11'd796,
        11'd876, 11'd963, 11'd1060, 11'd1166, 11'd1282, 11'd1411, 11'd1552 };

    logic [16:0] pos;
    logic [15:0] pend;
    logic        reset_r;
    logic        nib_pend;
    logic  [3:0] nib_lo, data;
    logic  [5:0] step;
    logic  [7:0] byte_q;
    logic        refetch;

    always_ff @(posedge clk) begin
        if (rst) begin
            pos <= '0; pend <= '0; reset_r <= 1'b0; nib_pend <= 1'b0; data <= '0;
            step <= '0; signal <= '0; refetch <= 1'b1; rom_req <= 1'b0;
            dbg_starts <= '0;
        end else begin
            // ---- prefetch of rom[pos]
            if (refetch && !rom_req) begin
                rom_addr <= pos[15:0];
                rom_req  <= 1'b1;
                refetch  <= 1'b0;
            end
            if (rom_req && rom_ack) begin
                rom_req <= 1'b0;
                byte_q  <= rom_data;
                if (rom_addr != pos[15:0]) refetch <= 1'b1;   // pos moved during the fetch
            end

            // ---- CPU writes
            if (wr) case (sel)
                2'd0: begin reset_r <= 1'b0; dbg_starts <= dbg_starts + 16'd1; end
                2'd1: pend <= {din[6:0], 9'd0};
                2'd2: begin pos <= {1'b0, din[6:0], 9'd0}; refetch <= 1'b1; end
                2'd3: reset_r <= 1'b1;
            endcase

            // ---- VCK: sequencer then MSM5205 decode
            if (vck) begin
                logic        r;
                logic  [3:0] dv;
                logic signed [13:0] diff, ns;
                logic [10:0] sv;
                logic signed [6:0] st;
                r  = reset_r;
                dv = data;
                if (pos >= {1'b0, pend} || pos[16]) begin
                    r = 1'b1;
                end else if (nib_pend) begin
                    dv = nib_lo;
                    nib_pend <= 1'b0;
                end else begin
                    // the prefetch is always complete by now (it takes ~20 clocks, a VCK period 6000)
                    dv = byte_q[7:4];
                    nib_lo   <= byte_q[3:0];
                    nib_pend <= 1'b1;
                    pos      <= pos + 17'd1;
                    refetch  <= 1'b1;
                end
                reset_r <= r;
                data    <= dv;
                if (r) begin
                    signal <= '0;
                    step   <= '0;
                end else begin
                    sv   = STEPVAL[step];
                    diff = $signed({3'b000, (dv[2] ? sv : 11'd0)
                                          + (dv[1] ? {1'b0, sv[10:1]} : 11'd0)
                                          + (dv[0] ? {2'b0, sv[10:2]} : 11'd0)
                                          + {3'b0, sv[10:3]}});
                    if (dv[3]) diff = -diff;
                    ns = $signed({{2{signal[11]}}, signal}) + diff;
                    if (ns > 14'sd2047) ns = 14'sd2047;
                    else if (ns < -14'sd2048) ns = -14'sd2048;
                    signal <= ns[11:0];
                    case (dv[2:0])
                        3'd4: st = $signed({1'b0, step}) + 7'sd2;
                        3'd5: st = $signed({1'b0, step}) + 7'sd4;
                        3'd6: st = $signed({1'b0, step}) + 7'sd6;
                        3'd7: st = $signed({1'b0, step}) + 7'sd8;
                        default: st = $signed({1'b0, step}) - 7'sd1;
                    endcase
                    if (st > 7'sd48) st = 7'sd48;
                    else if (st < 7'sd0) st = 7'sd0;
                    step <= st[5:0];
                end
            end
        end
    end
endmodule
