//=============================================================================
//  m1_video_src.v
//  M1 milestone video source + frame-cache page controller (25 MHz pixel domain)
//
//  Replaces the M0 colour-bar generator.  The 640x480 AXIS stream now comes
//  from the two read ports of Sdram_Control_4Port:
//
//      RD1  page A   base 0x000000, 307200 words, wraps at 0x0004B000
//      RD2  page B   base 0x12C000, 307200 words, wraps at 0x00177000
//
//  Both read ports are consumed at exactly one 32-bit word per active pixel
//  (640 words/line x 480 lines = 307200 words/frame), so each port's internal
//  address counter stays locked to the raster: word N of a frame is always
//  page_base + N.  The displayed page is chosen by a register mux (no address
//  change at switch time, so the 512-deep read FIFOs are never phase shifted).
//
//  Page control (frame-synchronised double buffer)
//  ------------------------------------------------
//    * the writer always fills the page that is NOT displayed; at every frame
//      tick it is handed the target page and a start toggle;
//    * a page becomes "ok" when the writer reports completion.  Only ok pages
//      are ever selected for display;
//    * the display page changes at the frame tick, i.e. during vertical
//      blanking, so there is never a mid-frame tear;
//    * the automatic swap period is SWAP_FRAMES frames (60 -> ~1.008 s at
//      59.52 Hz); KEY0 forces an early swap.
//
//  Clock domain crossings
//  ----------------------
//    O_wr_start_tog / O_wr_page  -> 100 MHz write domain  (level signals)
//    I_wr_done_tog               <- 100 MHz write domain  (toggle + edge)
//    I_sdram_ready               <- 100 MHz reset release (level)
//  Page number of a completion is not transported: the pixel domain knows the
//  target it handed out this frame, and a write always finishes long before
//  the next frame tick.
//=============================================================================
`timescale 1ns / 10ps

module m1_video_src #(
    parameter HTOTAL  = 800,
    parameter HSA     = 96,
    parameter HBP     = 48,
    parameter HFP     = 16,
    parameter HACTIVE = 640,

    parameter VTOTAL  = 525,
    parameter VSA     = 2,
    parameter VBP     = 33,
    parameter VFP     = 10,
    parameter VACTIVE = 480,

    parameter SWAP_FRAMES = 60      // automatic page swap period, in frames
) (
    input  wire        I_clk,           // 25 MHz pixel clock
    input  wire        I_rst,           // active high, pixel domain

    input  wire        I_key0_n,        // KEY0, low active : manual page swap
    input  wire        I_sdram_ready,   // level from the 100 MHz domain

    input  wire [31:0] I_rd1_data,      // SDRAM read port 1 (page A)
    input  wire [31:0] I_rd2_data,      // SDRAM read port 2 (page B)
    output wire        O_rd1_re,
    output wire        O_rd2_re,

    output wire        O_wr_start_tog,  // frame tick -> write domain
    output wire        O_wr_page,       // page to fill this frame
    input  wire        I_wr_done_tog,   // toggled by the writer on completion

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

    localparam HBLANK = HTOTAL - HACTIVE;   // 160
    localparam VBLANK = VTOTAL - VACTIVE;   //  45

    //-------------------------------------------------------------------------
    // raster counters (identical to the M0 generator, same reset as the HDMI
    // core so the AXIS beats stay phase locked to the core's DE)
    //-------------------------------------------------------------------------
    reg [9:0] S_col_cnt;
    reg [9:0] S_line_cnt;

    always @(posedge I_clk) begin
        if (I_rst)
            S_col_cnt <= 10'd0;
        else if (S_col_cnt == HTOTAL - 1)
            S_col_cnt <= 10'd0;
        else
            S_col_cnt <= S_col_cnt + 10'd1;
    end

    always @(posedge I_clk) begin
        if (I_rst)
            S_line_cnt <= 10'd0;
        else if (S_col_cnt == HTOTAL - 1) begin
            if (S_line_cnt == VTOTAL - 1)
                S_line_cnt <= 10'd0;
            else
                S_line_cnt <= S_line_cnt + 10'd1;
        end
    end

    wire S_active  = (S_line_cnt >= VBLANK) && (S_col_cnt >= HBLANK);
    wire S_vstart  = (S_line_cnt == 10'd0) && (S_col_cnt == 10'd0);
    wire S_sof     = (S_line_cnt == VBLANK) && (S_col_cnt == HBLANK);
    wire S_eol     = S_active && (S_col_cnt == HTOTAL - 1);

    //-------------------------------------------------------------------------
    // KEY0 debounce (25 MHz sampling, ~10.5 ms) -> one cycle press pulse
    //-------------------------------------------------------------------------
    reg [1:0]  S_key_sync;
    reg [17:0] S_key_cnt;
    reg        S_key_stable;        // 1 = released
    reg        S_key_stable_d;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_key_sync     <= 2'b11;
            S_key_cnt      <= 18'd0;
            S_key_stable   <= 1'b1;
            S_key_stable_d <= 1'b1;
        end else begin
            S_key_sync <= {S_key_sync[0], I_key0_n};
            if (S_key_sync[1] != S_key_stable) begin
                if (S_key_cnt == 18'h3FFFF) begin
                    S_key_cnt    <= 18'd0;
                    S_key_stable <= S_key_sync[1];
                end else begin
                    S_key_cnt <= S_key_cnt + 18'd1;
                end
            end else begin
                S_key_cnt <= 18'd0;
            end
            S_key_stable_d <= S_key_stable;
        end
    end

    wire S_key_press = S_key_stable_d && !S_key_stable;

    //-------------------------------------------------------------------------
    // clock domain crossing helpers
    //-------------------------------------------------------------------------
    reg [2:0] S_done_sync;
    reg [1:0] S_ready_sync;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_done_sync  <= 3'b000;
            S_ready_sync <= 2'b00;
        end else begin
            S_done_sync  <= {S_done_sync[1:0],  I_wr_done_tog};
            S_ready_sync <= {S_ready_sync[0],   I_sdram_ready};
        end
    end

    wire S_done_pulse = S_done_sync[1] ^ S_done_sync[2];
    wire S_sdram_ok   = S_ready_sync[1];

    //-------------------------------------------------------------------------
    // double buffer page control
    //-------------------------------------------------------------------------
    reg        S_ctrl_en;           // armed after the SDRAM domain is out of reset
    reg [1:0]  S_page_ok;           // bit n : page n has been written completely
    reg        S_disp_page;         // page currently sent to HDMI
    reg        S_wr_page;           // page the writer must fill
    reg        S_rd_en;             // read FIFOs may be consumed (frame aligned)
    reg        S_disp_en;           // FIFO data is shown (one frame after rd_en)
    reg        S_swap_pend;         // KEY0 request, sticky until the next frame
    reg [5:0]  S_swap_div;          // frame divider for the automatic swap
    reg        S_start_req;         // internal start toggle
    reg        S_start_d;           // start toggle delayed by 1 pixel clock

    wire S_auto_swap = S_vstart && (S_swap_div == SWAP_FRAMES - 1);
    wire S_vstart_ok = S_vstart && S_sdram_ok;
    wire [5:0] S_swap_next = (S_swap_div == SWAP_FRAMES - 1) ? 6'd0
                                                             : S_swap_div + 6'd1;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_ctrl_en    <= 1'b0;
            S_page_ok    <= 2'b00;
            S_disp_page  <= 1'b0;       // page A first
            S_wr_page    <= 1'b0;
            S_rd_en      <= 1'b0;
            S_disp_en    <= 1'b0;
            S_swap_pend  <= 1'b0;
            S_swap_div   <= 6'd0;
            S_start_req  <= 1'b0;
            S_start_d    <= 1'b0;
        end else begin
            S_start_d <= S_start_req;

            // sticky manual swap request, cleared at every frame tick
            if (S_key_press)
                S_swap_pend <= 1'b1;
            else if (S_vstart)
                S_swap_pend <= 1'b0;

            // a page write completed -> that page may be displayed
            if (S_done_pulse)
                S_page_ok[S_wr_page] <= 1'b1;

            if (S_vstart_ok) begin
                if (!S_ctrl_en) begin
                    S_ctrl_en <= 1'b1;  // first frame tick after SDRAM is alive
                end

                if (S_ctrl_en) begin
                    if (!S_page_ok[S_disp_page]) begin
                        // nothing valid to show yet: fill the page we want on
                        // screen, never select an unwritten page
                        S_wr_page <= S_disp_page;
                        S_rd_en   <= 1'b0;
                    end else begin
                        S_rd_en   <= 1'b1;
                        if ((S_swap_pend || S_auto_swap) && S_page_ok[~S_disp_page]) begin
                            // swap during vertical blanking
                            S_disp_page <= ~S_disp_page;
                            S_wr_page   <= S_disp_page;      // old value = page just left
                        end else begin
                            S_wr_page   <= ~S_disp_page;
                        end
                    end

                    S_swap_div  <= S_swap_next;
                    S_start_req <= ~S_start_req;             // one write / frame

                    // One frame of read-out is thrown away before the FIFO
                    // data is shown: the read FIFOs are primed at reset, i.e.
                    // their first <=512 words were fetched from the SDRAM
                    // before page A was ever written.  Consuming exactly one
                    // whole frame (307200 words = the page length) drains that
                    // stale backlog and leaves the read address counter back
                    // at word 0, so the first visible frame is clean.
                    S_disp_en <= S_rd_en;
                end
            end
        end
    end

    // the writer samples this level 2..3 cycles after the toggle edge
    assign O_wr_start_tog = S_start_d;
    assign O_wr_page      = S_wr_page;

    //-------------------------------------------------------------------------
    // AXIS stream
    //   The valid/user/last pattern is exactly the M0 one (free running, one
    //   beat per active pixel) so the HDMI core's internal FIFO stays in its
    //   steady state from the very first frame.  Until the display is enabled
    //   the data is forced to black, the beats are still sent.
    //
    //   Two enables:
    //     S_rd_en    the read FIFOs are consumed (starts at the frame tick of
    //                the first frame whose display page is complete)
    //     S_disp_en  the FIFO data is actually shown, one whole frame later.
    //                That first frame is spent draining the <=512 words that
    //                the read FIFOs fetched at reset, before page A existed;
    //                consuming exactly one page length (307200 words) leaves
    //                the read pointer back at word 0, so the first visible
    //                frame is aligned and clean.
    //
    //   The FIFO read enable is one assertion per active pixel.  EG_LOGIC_FIFO
    //   is a first-word-fall-through queue: the word present on DO is the word
    //   for the current pixel and RE advances the pointer, so DO has to be
    //   sampled in the same cycle the enable is high.
    //-------------------------------------------------------------------------
    wire [23:0] S_pix = S_disp_page ? I_rd2_data[23:0] : I_rd1_data[23:0];

    always @(posedge I_clk) begin
        if (I_rst) begin
            O_video_valid <= 1'b0;
            O_video_user  <= 1'b0;
            O_video_last  <= 1'b0;
            O_video_data  <= 24'd0;
        end else begin
            O_video_valid <= S_active;
            O_video_user  <= S_sof;
            O_video_last  <= S_eol;
            O_video_data  <= S_disp_en ? S_pix : 24'h000000;
        end
    end

    assign O_rd1_re = S_active && S_rd_en;
    assign O_rd2_re = S_active && S_rd_en;

endmodule
