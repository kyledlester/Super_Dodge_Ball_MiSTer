// Super Dodge Ball MiSTer core -- ROM loader (ioctl index 0, hps_io WIDE=0: one byte per write).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stream layout: docs/MRA_FORMAT.md (scripts/romtool.py is the executable form).
//   000000-00FFFF maincpu  -> block RAM (6502 program)
//   010000-017FFF audiocpu -> block RAM (6809 program)
//   018000-01BFFF mcu      -> block RAM (HD63701Y0 internal ROM)
//   01C000-05BFFF text     -> SDRAM 000000, byte {tile, y, g} from region byte {tile, g, y}
//                             (one tile row = 4 consecutive bytes)
//   05C000-09BFFF sprites  -> SDRAM 040000, byte {code, y, half, j} from region byte
//                             {half, code, j, y} (one 16-pixel sprite row = 8 consecutive bytes)
//   09C000-0BBFFF adpcm    -> SDRAM 080000 as is
//   0BC000-0BC7FF proms    -> palette block RAM (0x400 R/G PROM, 0x400 B PROM)
// SDRAM bytes: even byte address = DQ[7:0] of the 16-bit word. ioctl_wait is held from ioctl_wr until
// the write is done.
module sdb_loader (
    input  logic        clk,
    input  logic        rst,

    input  logic        ioctl_download,
    input  logic [15:0] ioctl_index,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    output logic        ioctl_wait,

    output logic        mem_req,
    output logic [25:1] mem_addr,
    output logic [15:0] mem_wdata,
    output logic  [1:0] mem_be,
    input  logic        mem_ack,

    output logic        rom_we,         // one clock per byte for the block-RAM regions
    output logic [16:0] rom_addr,       // stream address 00000-1BFFF
    output logic        prom_we,
    output logic [10:0] prom_addr,
    output logic  [7:0] rom_data,

    output logic        loaded
);
    typedef enum logic [1:0] {IDLE, W1, W2} st_t;
    st_t st;
    logic [23:0] a;
    logic  [7:0] d;

    wire sel = ioctl_download && ioctl_index == 16'd0;
    assign ioctl_wait = st != IDLE;

    always_ff @(posedge clk) begin
        rom_we  <= 1'b0;
        prom_we <= 1'b0;
        if (rst) begin
            st <= IDLE;
            mem_req <= 1'b0;
            loaded <= 1'b0;
        end else case (st)
            IDLE: if (sel && ioctl_wr) begin
                a  <= ioctl_addr[23:0];
                d  <= ioctl_dout;
                st <= W1;
                if (ioctl_addr == 27'h0BC7FF) loaded <= 1'b1;
            end
            W1: begin
                logic [23:0] r;
                logic [23:0] b;                 // SDRAM byte address
                r = '0; b = '0;
                rom_data  <= d;
                mem_wdata <= {d, d};
                st        <= IDLE;
                if (a < 24'h01C000) begin
                    rom_we   <= 1'b1;
                    rom_addr <= a[16:0];
                end else if (a < 24'h05C000) begin
                    r = a - 24'h01C000;
                    b = {6'd0, r[17:5], r[2:0], r[4:3]};
                end else if (a < 24'h09C000) begin
                    r = a - 24'h05C000;
                    b = 24'h040000 + {6'd0, r[16:6], r[3:0], r[17], r[5:4]};
                end else if (a < 24'h0BC000) begin
                    r = a - 24'h09C000;
                    b = 24'h080000 + r;
                end else if (a < 24'h0BC800) begin
                    prom_we   <= 1'b1;
                    prom_addr <= a[10:0];
                end
                if (a >= 24'h01C000 && a < 24'h0BC000) begin
                    mem_addr <= {1'b0, b[23:1]};
                    mem_be   <= b[0] ? 2'b10 : 2'b01;
                    mem_req  <= 1'b1;
                    st       <= W2;
                end
            end
            W2: if (mem_ack) begin
                mem_req <= 1'b0;
                st      <= IDLE;
            end
            default: st <= IDLE;
        endcase
    end
endmodule
