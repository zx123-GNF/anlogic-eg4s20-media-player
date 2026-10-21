//=============================================================================
//  m1_sdram_wr.v
//  M1 test-pattern writer for page A / page B (100 MHz SDRAM domain)
//
//  One page (640 x 480 = 307200 words, 32 bit each, low 24 bit = RGB888) is
//  streamed into the WR1 port of Sdram_Control_4Port every frame.  The two
//  pages are contiguous in the controller's *word* address space:
//
//      page A : words 0x00000 .. 0x4AFFF   (byte 0x000000 .. 0x12BFFF)
//      page B : words 0x04B000 .. 0x095FFF (byte 0x12C000 .. 0x257FFF)
//
//  The WR1 address counter is never reloaded (WR1_LOAD tied low): it runs as a
//  ring of 614400 words and wraps at the end of page B.  Because one page is
//  exactly 2400 bursts of 128 words, the ring position at the start of every
//  page write is exactly the page base, whatever data is still queued in the
//  512-word write FIFO.  (The FIFO is a pure delay: word n is always written
//  to ring address base+n, provided it never underflows - the controller only
//  starts a burst when more than 127 words are queued, AE=127.)
//
//  Pattern
//  -------
//      * R = x[9:2] (0..159), G = y[8:1] (0..239), B = 0x40 : gradient that
//        shows the raster order is right (red rises to the right, green rises
//        downwards);
//      * 8 pixel wide white bar that steps 8 pixels every BAR_STEP_FRAMES
//        completed page writes (60 frames = ~1.008 s at 59.52 Hz), wrapping at
//        the right edge: proves the frame is being rewritten live;
//      * 8 pixel border, green on page A and magenta on page B: makes the
//        double-buffer page switch visible on screen.
//
//  Handshake
//  ---------
//    I_start_tog toggles once per frame in the 25 MHz domain (the page level
//    is stable one pixel clock before the toggle, so it is stable long before
//    the synchronised edge is seen);  O_done_tog toggles back after word
//    307199 has been accepted by the FIFO.
//
//    O_wr is combinational (S_busy && !I_fifo_full) so that the write enable
//    the FIFO samples is derived from the same-cycle full flag.  A registered
//    write enable could present the last word of a page on a cycle where FULL
//    has just asserted and silently drop it, which would shift the whole ring
//    by one word.
//=============================================================================
`timescale 1ns / 10ps

module m1_sdram_wr #(
    parameter HACTIVE         = 640,
    parameter VACTIVE         = 480,
    parameter BAR_STEP_FRAMES = 60
) (
    input  wire        I_clk,           // 100 MHz SDRAM controller clock
    input  wire        I_rst,           // active high, 100 MHz domain

    input  wire        I_start_tog,     // frame tick from the pixel domain
    input  wire        I_page,          // page to fill (0 = A, 1 = B)
    input  wire        I_fifo_full,     // WR1_FULL

    output wire        O_wr,            // WR1
    output wire [31:0] O_wr_data,       // WR1_DATA
    output reg         O_done_tog       // completion toggle
);

    //-------------------------------------------------------------------------
    // CDC: start toggle, page level
    //-------------------------------------------------------------------------
    reg [2:0] S_start_sync;
    reg [1:0] S_page_sync;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_start_sync <= 3'b000;
            S_page_sync  <= 2'b00;
        end else begin
            S_start_sync <= {S_start_sync[1:0], I_start_tog};
            S_page_sync  <= {S_page_sync[0],    I_page};
        end
    end

    wire S_start_pulse = S_start_sync[1] ^ S_start_sync[2];

    //-------------------------------------------------------------------------
    // pixel counters / pattern
    //-------------------------------------------------------------------------
    reg        S_busy;
    reg [9:0]  S_x;             // 0 .. HACTIVE-1
    reg [8:0]  S_y;             // 0 .. VACTIVE-1
    reg        S_page_q;        // page being written (for the border colour)
    reg [5:0]  S_bar_div;
    reg [9:0]  S_bar_x;         // 0, 8, ... HACTIVE-8

    wire [9:0] S_bar_end = S_bar_x + 10'd8;

    reg [23:0] S_pat;
    always @(*) begin
        if (S_x < 10'd8 || S_x >= HACTIVE - 8 || S_y < 9'd8 || S_y >= VACTIVE - 8)
            S_pat = S_page_q ? 24'hFF00FF : 24'h00FF00;   // B = magenta, A = green
        else if (S_x >= S_bar_x && S_x < S_bar_end)
            S_pat = 24'hFFFFFF;                            // moving bar
        else
            S_pat = {S_x[9:2], S_y[8:1], 8'h40};           // gradient
    end

    //-------------------------------------------------------------------------
    // write FSM
    //   S_x / S_y address the word currently on the FIFO write port and only
    //   advance when that word is accepted (busy and not full).
    //-------------------------------------------------------------------------
    wire S_accept = S_busy && !I_fifo_full;

    assign O_wr      = S_accept;
    assign O_wr_data = {8'h00, S_pat};

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_busy     <= 1'b0;
            S_x        <= 10'd0;
            S_y        <= 9'd0;
            S_page_q   <= 1'b0;
            S_bar_div  <= 6'd0;
            S_bar_x    <= 10'd0;
            O_done_tog <= 1'b0;
        end else begin
            if (S_start_pulse && !S_busy) begin
                S_busy   <= 1'b1;
                S_x      <= 10'd0;
                S_y      <= 9'd0;
                S_page_q <= S_page_sync[1];
            end else if (S_accept) begin
                if (S_x == HACTIVE - 1) begin
                    S_x <= 10'd0;
                    if (S_y == VACTIVE - 1) begin
                        // page complete
                        S_y        <= 9'd0;
                        S_busy     <= 1'b0;
                        O_done_tog <= ~O_done_tog;

                        if (S_bar_div == BAR_STEP_FRAMES - 1) begin
                            S_bar_div <= 6'd0;
                            S_bar_x   <= (S_bar_x >= HACTIVE - 8)
                                         ? 10'd0 : (S_bar_x + 10'd8);
                        end else begin
                            S_bar_div <= S_bar_div + 6'd1;
                        end
                    end else begin
                        S_y <= S_y + 9'd1;
                    end
                end else begin
                    S_x <= S_x + 10'd1;
                end
            end
        end
    end

endmodule
