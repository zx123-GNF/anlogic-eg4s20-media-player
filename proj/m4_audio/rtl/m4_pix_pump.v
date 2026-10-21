//=============================================================================
//  m4_pix_pump.v
//  Walk one 512 byte sector of the SD sector buffer and turn the raw BMP
//  payload into 24 bit RGB pixels for the SDRAM page writer.
//
//  * the byte phase (0/1/2) is NOT reset per sector, because a 640x480 24 bit
//    BMP row is 1920 bytes and a sector is 512 bytes: 512 mod 3 = 2, so a
//    pixel routinely straddles a sector boundary.  The phase and the two
//    pending bytes are therefore module state that survives I_done.
//  * BMP stores pixels as B,G,R  ->  byte0 = B, byte1 = G, byte2 = R, and the
//    32 bit word handed to the SDRAM writer is {8'h00, R, G, B} (low 24 bit
//    = RGB888, matching the M1 frame buffer format).
//  * back pressure: a completed pixel is held on O_pix_valid until
//    I_pix_ready.  The byte walker stalls (address and RAM data stay put,
//    which is legal because the RAM address register simply keeps its value).
//
//  Timing: 2 clocks per byte -> 6 clocks per pixel, i.e. ~16 M pixel/s, far
//  above the ~0.9 M pixel/s that the 25 MHz SPI can deliver; the pump is never
//  the bottleneck, it only has to be *correct*.
//=============================================================================
`timescale 1ns / 10ps

module m4_pix_pump (
    input  wire        I_clk,
    input  wire        I_rst,

    input  wire        I_start,         // one cycle pulse
    input  wire [8:0]  I_off,           // first byte offset inside the sector
    input  wire [9:0]  I_cnt,           // number of bytes, 1..512
    output reg         O_busy,
    output reg         O_done,          // one cycle pulse

    output reg  [8:0]  O_addr,          // sector buffer read address
    input  wire [7:0]  I_din,           // sector buffer read data

    output wire        O_pix_valid,
    output wire [23:0] O_pix_data,
    input  wire        I_pix_ready
);

    localparam S_IDLE = 2'd0;
    localparam S_PRE  = 2'd1;
    localparam S_RUN  = 2'd2;
    localparam S_DONE = 2'd3;

    reg [1:0]  S_st;
    reg [9:0]  S_idx;
    reg [9:0]  S_cnt;

    reg [1:0]  S_ph;            // pixel byte phase, survives sectors
    reg [7:0]  S_b0, S_b1;      // B and G of the pixel in progress
    reg        S_ppend;         // a finished pixel is waiting for ready
    reg [23:0] S_pdata;

    assign O_pix_valid = S_ppend;
    assign O_pix_data  = S_pdata;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st    <= S_IDLE;
            S_idx   <= 10'd0;
            S_cnt   <= 10'd1;
            S_ph    <= 2'd0;
            S_b0    <= 8'h00;
            S_b1    <= 8'h00;
            S_ppend <= 1'b0;
            S_pdata <= 24'h000000;
            O_busy  <= 1'b0;
            O_done  <= 1'b0;
            O_addr  <= 9'd0;
        end else begin
            O_done <= 1'b0;

            // pixel handshake: consumed as soon as the writer takes it
            if (S_ppend && I_pix_ready)
                S_ppend <= 1'b0;

            case (S_st)
                S_IDLE: begin
                    O_busy <= 1'b0;
                    if (I_start) begin
                        O_addr <= I_off;
                        S_cnt  <= (I_cnt == 10'd0) ? 10'd1 : I_cnt;
                        S_idx  <= 10'd0;
                        O_busy <= 1'b1;
                        S_st   <= S_PRE;
                    end
                end

                S_PRE: begin
                    S_st <= S_RUN;
                end

                S_RUN: begin
                    // stall while the previous pixel has not been taken
                    if (!(S_ppend && !I_pix_ready)) begin
                        O_addr <= O_addr + 9'd1;
                        S_idx  <= S_idx + 10'd1;

                        case (S_ph)
                            2'd0: begin
                                S_b0 <= I_din;
                                S_ph <= 2'd1;
                            end
                            2'd1: begin
                                S_b1 <= I_din;
                                S_ph <= 2'd2;
                            end
                            default: begin
                                // third byte is R; BMP payload is B,G,R
                                S_pdata <= {8'h00, I_din, S_b1, S_b0};
                                S_ppend <= 1'b1;
                                S_ph    <= 2'd0;
                            end
                        endcase

                        // last byte of this chunk -> done (phase is kept)
                        if ((S_idx + 10'd1) >= S_cnt)
                            S_st <= S_DONE;
                    end
                end

                S_DONE: begin
                    O_done <= 1'b1;
                    O_busy <= 1'b0;
                    S_st   <= S_IDLE;
                end

                default: S_st <= S_IDLE;
            endcase
        end
    end

endmodule
