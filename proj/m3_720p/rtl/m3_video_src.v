//=============================================================================
//  m3_video_src.v
//  M2 video source + frame-cache page controller (25 MHz pixel domain),
//  derived from m1_video_src.v.  The 640x480 AXIS stream still comes from the
//  two read ports of Sdram_Control_4Port:
//
//      RD1  page A   base 0x000000, 307200 words, wraps at 0x0004B000
//      RD2  page B   base 0x04B000, 307200 words, wraps at 0x00096000
//
//  Both ports are consumed at exactly one 32 bit word per active pixel, so
//  each port's internal address counter stays locked to the raster (word N of
//  a frame is always page_base + N).  The displayed page is a register mux, so
//  switching pages never disturbs the 512 deep read FIFOs.
//
//  What changed with respect to M1
//  ------------------------------
//  * M1 wrote a test pattern every frame, so the page could be swapped at any
//    frame tick.  In M2 a page is loaded from the SD card and takes ~0.4 s,
//    so the page swap is requested by the loader ("page X complete", toggle +
//    page level), latched here and executed at the next frame start, i.e.
//    during vertical blanking: no tearing.
//  * the page being written is always the one that is NOT displayed
//    (the loader samples O_disp_page before it starts), and the loader does
//    not start the next image before it has seen this module swap
//    (I_disp_page == I_ready_page), so a page under construction can never be
//    the page on screen.
//  * the automatic swap of M1 is gone; KEY0 = next image, KEY1 = previous
//    image, both debounced here (~10.5 ms) and forwarded as toggles.
//  * one frame of read-out is still thrown away before the FIFO data is shown
//    (see the M1 report 5.3): the read FIFOs are primed at reset with stale
//    SDRAM content, and consuming exactly one page length puts both read
//    pointers back at their page base.
//=============================================================================
`timescale 1ns / 10ps

module m3_video_src #(
    parameter HTOTAL  = 800,
    parameter HSA     = 96,
    parameter HBP     = 48,
    parameter HFP     = 16,
    parameter HACTIVE = 640,

    parameter VTOTAL  = 525,
    parameter VSA     = 2,
    parameter VBP     = 33,
    parameter VFP     = 10,
    parameter VACTIVE = 480
) (
    input  wire        I_clk,           // 25 MHz pixel clock
    input  wire        I_rst,           // active high

    input  wire        I_key0_n,        // KEY0, low active : next image
    input  wire        I_key1_n,        // KEY1, low active : previous image
    input  wire        I_sdram_ready,   // level from the 100 MHz domain

    input  wire [31:0] I_rd1_data,      // SDRAM read port 1 (page A)
    input  wire [31:0] I_rd2_data,      // SDRAM read port 2 (page B)
    output wire        O_rd1_re,
    output wire        O_rd2_re,

    input  wire        I_ready_tog,     // loader: a page has been completed
    input  wire        I_ready_page,    // which page
    output wire        O_disp_page,     // page currently on screen

    output wire        O_key_next_tog,  // forwarded to the 100 MHz domain
    output wire        O_key_prev_tog,

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

    localparam HBLANK = HTOTAL - HACTIVE;   // 160
    localparam VBLANK = VTOTAL - VACTIVE;   //  45

    //-------------------------------------------------------------------------
    // raster counters (same reset as the HDMI core, so the AXIS beats stay
    // phase locked to the core's data enable)
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

    wire S_active = (S_line_cnt >= VBLANK) && (S_col_cnt >= HBLANK);
    wire S_vstart = (S_line_cnt == 10'd0) && (S_col_cnt == 10'd0);
    wire S_sof    = (S_line_cnt == VBLANK) && (S_col_cnt == HBLANK);
    wire S_eol    = S_active && (S_col_cnt == HTOTAL - 1);

    //-------------------------------------------------------------------------
    // KEY0 / KEY1 debounce (25 MHz sampling, 2^18 clocks = 10.5 ms)
    //-------------------------------------------------------------------------
    reg [3:0]  S_key_ss;                    // [3:2] key1,key0 synced
    reg [1:0]  S_key_stb, S_key_stb_d;      // 1 = released
    reg [17:0] S_key_cnt [0:1];

    integer k;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_key_ss    <= 4'b1111;
            S_key_stb   <= 2'b11;
            S_key_stb_d <= 2'b11;
            for (k = 0; k < 2; k = k + 1)
                S_key_cnt[k] <= 18'd0;
        end else begin
            S_key_ss <= {S_key_ss[1:0], I_key1_n, I_key0_n};

            for (k = 0; k < 2; k = k + 1) begin
                if (S_key_ss[2+k] != S_key_stb[k]) begin
                    if (S_key_cnt[k] == 18'h3FFFF) begin
                        S_key_cnt[k] <= 18'd0;
                        S_key_stb[k] <= S_key_ss[2+k];
                    end else begin
                        S_key_cnt[k] <= S_key_cnt[k] + 18'd1;
                    end
                end else begin
                    S_key_cnt[k] <= 18'd0;
                end
            end

            S_key_stb_d <= S_key_stb;
        end
    end

    wire [1:0] S_key_press = S_key_stb_d & ~S_key_stb;   // 1 = just pressed

    reg S_kn_tog, S_kp_tog;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_kn_tog <= 1'b0;
            S_kp_tog <= 1'b0;
        end else begin
            if (S_key_press[0]) S_kn_tog <= ~S_kn_tog;
            if (S_key_press[1]) S_kp_tog <= ~S_kp_tog;
        end
    end

    assign O_key_next_tog = S_kn_tog;
    assign O_key_prev_tog = S_kp_tog;

    //-------------------------------------------------------------------------
    // clock domain crossing : ready toggle + page level, sdram ready level
    //-------------------------------------------------------------------------
    reg [2:0] S_ready_sync;
    reg [1:0] S_ready_pg_sync;
    reg [1:0] S_sdr_sync;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_ready_sync    <= 3'b000;
            S_ready_pg_sync <= 2'b00;
            S_sdr_sync      <= 2'b00;
        end else begin
            S_ready_sync    <= {S_ready_sync[1:0], I_ready_tog};
            S_ready_pg_sync <= {S_ready_pg_sync[0], I_ready_page};
            S_sdr_sync      <= {S_sdr_sync[0], I_sdram_ready};
        end
    end

    wire S_ready_pulse = S_ready_sync[1] ^ S_ready_sync[2];
    wire S_ready_pg    = S_ready_pg_sync[1];
    wire S_sdram_ok    = S_sdr_sync[1];

    //-------------------------------------------------------------------------
    // page control
    //-------------------------------------------------------------------------
    reg [1:0] S_page_ok;
    reg       S_disp_page;
    reg       S_rd_en;
    reg       S_disp_en;
    reg       S_swap_pend;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_page_ok   <= 2'b00;
            S_disp_page <= 1'b0;
            S_rd_en     <= 1'b0;
            S_disp_en   <= 1'b0;
            S_swap_pend <= 1'b0;
        end else begin
            if (S_ready_pulse) begin
                S_page_ok[S_ready_pg] <= 1'b1;
                S_swap_pend           <= 1'b1;
            end else if (S_vstart) begin
                S_swap_pend <= 1'b0;
            end

            if (S_vstart && S_sdram_ok) begin
                if (S_swap_pend && S_page_ok[~S_disp_page]) begin
                    S_disp_page <= ~S_disp_page;    // swap in vertical blanking
                    S_rd_en     <= 1'b1;
                end else if (S_page_ok[S_disp_page]) begin
                    S_rd_en     <= 1'b1;
                end
                S_disp_en <= S_rd_en;
            end
        end
    end

    assign O_disp_page = S_disp_page;

    //-------------------------------------------------------------------------
    // AXIS stream : one beat per active pixel, black until a page is complete
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
