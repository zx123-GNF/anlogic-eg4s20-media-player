//=============================================================================
//  m2_page_wr.v
//  Frame-buffer page writer for M2:  307200 pixel words -> WR1 of
//  Sdram_Control_4Port, one BMP image per page, top-down or bottom-up.
//
//  WHY NOT THE M1 RING WRITE ANY MORE
//  ----------------------------------
//  M1 streamed a test pattern in raster order into a free running 614400 word
//  ring (WR1_LOAD tied low) and relied on "one page = 2400 bursts of 128
//  words, so the ring is always at a page base when a page starts".
//
//  A BMP is stored BOTTOM-UP (bfHeight > 0): the first row in the file is the
//  LAST row of the picture.  The SDRAM write port is strictly sequential, so
//  streaming the file straight into the page produces an upside down picture,
//  and no amount of display-side reordering can fix that (the two display read
//  ports are sequential as well).
//
//  M2 therefore writes each image row with its own WR1_LOAD:
//
//      row r (0..479) occupies words  page_base + r*640 .. + r*640+639
//
//  640 = 5 x 128 is an exact multiple of the 128 word burst, and every row
//  base is 128 word aligned, so one row is exactly five bursts and the write
//  FIFO ends up EXACTLY empty after each row (the controller only starts a
//  burst when the FIFO holds >= 128 words, AE=127 in Sdram_WR_FIFO.v).
//  After the last pixel of a row has been queued the FSM waits DRAIN clocks
//  (see below) and then re-loads the address counter for the next row, so the
//  127 residual words problem of the M1 report can never occur.
//
//  Writing the rows in DECREASING address order makes the bottom-up file order
//  line up with ascending picture rows, so the pixel stream needs no buffering
//  at all: row 479 is written first (file row 0), row 0 last (file row 479).
//
//  DRAIN bound: at most 640 words (5 bursts) can be queued when the last pixel
//  of a row is accepted; the arbiter priority is RD1 > RD2 > WR1, so one write
//  burst can be pushed back by at most two read bursts:
//      5 x (138 + 2*138) = 2070 clocks  ->  DRAIN = 2048 is NOT enough,
//  so 4096 clocks (41 us, 480 rows -> 19.7 ms per page, ~6 % of a 0.35 s load)
//  is used.  RD1/RD2 only ask for a burst every ~5.1 us, so the real number is
//  far below that.
//
//  I_flush pads the rest of the page with black (short file / FAT error /
//  aborted load) and lets the FSM terminate the page deterministically, which
//  keeps the "every write starts with an explicit LOAD" invariant.
//=============================================================================
`timescale 1ns / 10ps

module m2_page_wr #(
    parameter HACTIVE = 640,
    parameter VACTIVE = 480,
    parameter DRAIN   = 4096
) (
    input  wire        I_clk,           // 100 MHz SDRAM controller clock
    input  wire        I_rst,           // active high

    input  wire        I_start,         // one cycle pulse
    input  wire        I_page,          // 0 = page A, 1 = page B
    input  wire        I_bottom_up,     // 1 = first pixel row goes to row 479

    input  wire [23:0] I_pix_data,
    input  wire        I_pix_valid,
    output wire        O_pix_ready,     // writer can take a pixel this cycle
    input  wire        I_flush,         // 1 = ignore pixels, pad with black

    input  wire        I_fifo_full,     // WR1_FULL

    output wire        O_wr,
    output wire [31:0] O_wr_data,
    output wire        O_load,          // WR1_LOAD
    output wire [20:0] O_addr,          // WR1_ADDR
    output wire        O_busy,
    output reg         O_done           // one cycle pulse, page complete
);

    localparam PAGE_A_BASE = 21'h000000;
    localparam PAGE_B_BASE = 21'h04B000;

    localparam W_IDLE  = 3'd0;
    localparam W_LD0   = 3'd1;
    localparam W_LD1   = 3'd2;
    localparam W_ROW   = 3'd3;
    localparam W_DRAIN = 3'd4;
    localparam W_END   = 3'd5;

    reg [2:0]  S_st;
    reg        S_page;
    reg        S_bup;
    reg [8:0]  S_row;
    reg [9:0]  S_x;
    reg [12:0] S_dcnt;
    reg        S_last;
    reg        S_busy;
    reg        S_load;
    reg [20:0] S_addr;

    // row * 640 = row*512 + row*128
    wire [20:0] S_row_off  = {S_row, 9'b0} + {S_row, 7'b0};
    wire [20:0] S_row_base = (S_page ? PAGE_B_BASE : PAGE_A_BASE) + S_row_off;

    // bottom-up : rows are written 479,478,...,0 -> row 0 is written last
    // top-down  : rows are written 0,1,...,479   -> row 479 is written last
    wire S_row_is_last = S_bup ? (S_row == 9'd0) : (S_row == (VACTIVE - 1));
    wire S_accept = (S_st == W_ROW) && (I_flush || I_pix_valid) && !I_fifo_full;

    assign O_wr      = S_accept;
    assign O_wr_data = I_flush ? 32'h00000000 : {8'h00, I_pix_data[23:0]};
    assign O_load    = S_load;
    assign O_addr    = S_addr;
    assign O_busy    = S_busy;
    assign O_pix_ready = (S_st == W_ROW) && !I_fifo_full && !I_flush;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st    <= W_IDLE;
            S_page  <= 1'b0;
            S_bup   <= 1'b0;
            S_row   <= 9'd0;
            S_x     <= 10'd0;
            S_dcnt  <= 13'd0;
            S_last  <= 1'b0;
            S_busy  <= 1'b0;
            S_load  <= 1'b0;
            S_addr  <= 21'd0;
            O_done  <= 1'b0;
        end else begin
            O_done <= 1'b0;
            S_load <= 1'b0;

            case (S_st)
                W_IDLE: begin
                    S_busy <= 1'b0;
                    if (I_start && !S_busy) begin
                        S_page <= I_page;
                        S_bup  <= I_bottom_up;
                        S_row  <= I_bottom_up ? (VACTIVE - 1) : 9'd0;
                        S_x    <= 10'd0;
                        S_busy <= 1'b1;
                        S_st   <= W_LD0;
                    end
                end

                // S_addr is registered one clock before WR1_LOAD so both are
                // stable when the controller samples them.
                W_LD0: begin
                    S_addr <= S_row_base;
                    S_st   <= W_LD1;
                end

                W_LD1: begin
                    S_load <= 1'b1;
                    S_st   <= W_ROW;
                end

                W_ROW: begin
                    if (S_accept) begin
                        if (S_x == HACTIVE - 1) begin
                            S_x    <= 10'd0;
                            S_last <= S_row_is_last;
                            S_dcnt <= DRAIN;
                            S_st   <= W_DRAIN;
                            if (!S_row_is_last)
                                S_row <= S_bup ? (S_row - 9'd1) : (S_row + 9'd1);
                        end else begin
                            S_x <= S_x + 10'd1;
                        end
                    end
                end

                W_DRAIN: begin
                    S_dcnt <= S_dcnt - 13'd1;
                    if (S_dcnt == 13'd1) begin
                        if (S_last) S_st <= W_END;
                        else        S_st <= W_LD0;
                    end
                end

                W_END: begin
                    O_done <= 1'b1;
                    S_busy <= 1'b0;
                    S_st   <= W_IDLE;
                end

                default: S_st <= W_IDLE;
            endcase
        end
    end

endmodule
