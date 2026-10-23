//=============================================================================
//  m5_video_src720.v
//  1280x720 raster + 640x480 frame-buffer window + axis source (73.333 MHz).
//
//  The AC208 monitor on the bench only accepts 1280x720 (it rejects 640x480
//  outright: "not support"), while the frame buffer page is still exactly one
//  640x480 RGB888 image (307200 words) because that is what the BMP player
//  writes.  This module therefore keeps the raster at 1280x720 and maps the
//  640x480 buffer into a centred window:
//
//      canvas 1280x720                         window 640x480
//      +--------------------------------+      +------------------+
//      |            black               |      | WIN_X=320        |
//      |        +----------------+      |      | WIN_Y=120        |
//      |        |   640 x 480    |      |  ->  the page is read
//      |        |     page       |      |      only inside this box,
//      |        +----------------+      |      1 SDRAM word per box pixel
//      |            black               |
//      +--------------------------------+
//
//  The two read ports of Sdram_Control_4Port are consumed exactly once per
//  window pixel as well, so their FIFO heads stay locked to the page offset:
//  one full frame consumes exactly 307200 words per port, i.e. one page, and
//  the controller's wrap point (RD1_MAX_ADDR = page end) puts both heads back
//  at the page base at every frame start.  The page swap is executed in the
//  vertical blanking exactly like m3_video_src.v.
//
//  AXIS:  valid = every active pixel of the 1280x720 canvas,
//         data  = page pixel inside the window, black everywhere else,
//         user  = first active pixel of the frame,  last = last pixel of a line.
//  (m0_720p proved this hand-shake works with the encrypted HDMI core.)
//=============================================================================
`timescale 1ns / 10ps

module m5_video_src720 #(
    parameter HTOTAL  = 1650,
    parameter HSA     = 40,
    parameter HBP     = 220,
    parameter HFP     = 110,
    parameter HACTIVE = 1280,

    parameter VTOTAL  = 750,
    parameter VSA     = 5,
    parameter VBP     = 20,
    parameter VFP     = 5,
    parameter VACTIVE = 720,

    // 640x480 frame-buffer window inside the 1280x720 canvas
    parameter WIN_X   = 320,
    parameter WIN_Y   = 120,
    parameter WIN_W   = 640,
    parameter WIN_H   = 480,

    // M3 interaction: KEY0 held for HOLD_CLKS == 1 s toggles the slide show.
    // 73.333 MHz pixel clock -> 1 s = 73_333_332 clocks (26 bit counter).
    parameter HOLD_CLKS  = 73_333_332,
    // automatic step every AUTO_FRAMES frame starts: 179 x 16.875 ms = 3.02 s
    parameter AUTO_FRAMES = 179
) (
    input  wire        I_clk,           // 73.333 MHz pixel clock
    input  wire        I_rst,           // active high

    input  wire        I_key0_n,        // KEY0 (S0): short = next, long = pause
    input  wire        I_key1_n,        // KEY1 (S1): short = previous
    input  wire        I_sdram_ready,   // level from the 100 MHz domain

    input  wire [31:0] I_rd1_data,      // SDRAM read port 1 (page A)
    input  wire [31:0] I_rd2_data,      // SDRAM read port 2 (page B)
    output wire        O_rd1_re,
    output wire        O_rd2_re,

    input  wire        I_ready_tog,     // loader: a page has been completed
    input  wire        I_ready_page,    // which page
    input  wire        I_st_has_img,    // the FAT layer knows at least one image
    output wire        O_disp_page,     // page currently on screen

    output wire        O_key_next_tog,  // forwarded to the 100 MHz domain
    output wire        O_key_prev_tog,

    // M3 interaction status (25 MHz / 73 MHz domain, consumed locally)
    output wire        O_paused,        // 1 = slide show paused
    output wire        O_ready_pulse,   // 1 cycle: a page has just completed

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

    localparam HBLANK = HTOTAL - HACTIVE;   // 370
    localparam VBLANK = VTOTAL - VACTIVE;   //  30

    //-------------------------------------------------------------------------
    // raster counters
    //-------------------------------------------------------------------------
    reg [10:0] S_col_cnt;
    reg [9:0]  S_line_cnt;

    always @(posedge I_clk) begin
        if (I_rst)
            S_col_cnt <= 11'd0;
        else if (S_col_cnt == HTOTAL - 1)
            S_col_cnt <= 11'd0;
        else
            S_col_cnt <= S_col_cnt + 11'd1;
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

    // centred 640x480 window
    localparam WIN_X0 = HBLANK + WIN_X;         // 690
    localparam WIN_Y0 = VBLANK + WIN_Y;         // 150
    localparam WIN_X1 = WIN_X0 + WIN_W;         // 1330
    localparam WIN_Y1 = WIN_Y0 + WIN_H;         // 630

    wire S_win = S_active &&
                 (S_col_cnt >= WIN_X0) && (S_col_cnt < WIN_X1) &&
                 (S_line_cnt >= WIN_Y0) && (S_line_cnt < WIN_Y1);

    wire S_vstart = (S_line_cnt == 10'd0) && (S_col_cnt == 11'd0);
    wire S_sof    = (S_line_cnt == VBLANK) && (S_col_cnt == HBLANK);
    wire S_eol    = S_active && (S_col_cnt == HTOTAL - 1);

    //-------------------------------------------------------------------------
    // KEY0 / KEY1 debounce (73.33 MHz, 2^19 clocks = 7.1 ms)
    //-------------------------------------------------------------------------
    reg [3:0]  S_key_ss;
    reg [1:0]  S_key_stb, S_key_stb_d;
    reg [18:0] S_key_cnt [0:1];

    integer k;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_key_ss    <= 4'b1111;
            S_key_stb   <= 2'b11;
            S_key_stb_d <= 2'b11;
            for (k = 0; k < 2; k = k + 1)
                S_key_cnt[k] <= 19'd0;
        end else begin
            S_key_ss <= {S_key_ss[1:0], I_key1_n, I_key0_n};

            for (k = 0; k < 2; k = k + 1) begin
                if (S_key_ss[2+k] != S_key_stb[k]) begin
                    if (S_key_cnt[k] == 19'h7FFFF) begin
                        S_key_cnt[k] <= 19'd0;
                        S_key_stb[k] <= S_key_ss[2+k];
                    end else begin
                        S_key_cnt[k] <= S_key_cnt[k] + 19'd1;
                    end
                end else begin
                    S_key_cnt[k] <= 19'd0;
                end
            end

            S_key_stb_d <= S_key_stb;
        end
    end

    wire [1:0] S_key_press = S_key_stb_d & ~S_key_stb;
    wire [1:0] S_key_rel   = ~S_key_stb_d & S_key_stb;

    //-------------------------------------------------------------------------
    // KEY0 long press (>= 1 s) toggles auto play.  The event fires at the
    // 1 s mark and S_hold_done swallows the following release, so a long press
    // never also steps to the next image.
    //-------------------------------------------------------------------------
    //  1 s at 73.333 MHz = 73_333_332 clocks, which does NOT fit in 26 bits
    //  (2^26 = 67_108_864), so the counter must be 27 bit wide -- with 26 bit
    //  the comparison below never became true and KEY0 long press did nothing.
    reg [26:0] S_hold_cnt;
    reg        S_hold_done;
    reg        S_paused;
    reg        S_pause_ev;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_hold_cnt  <= 27'd0;
            S_hold_done <= 1'b0;
            S_paused    <= 1'b0;
            S_pause_ev  <= 1'b0;
        end else begin
            S_pause_ev <= 1'b0;

            if (S_key_press[0]) begin
                S_hold_cnt  <= 27'd0;
                S_hold_done <= 1'b0;
            end else if (!S_key_stb[0] && !S_hold_done) begin
                if (S_hold_cnt >= (HOLD_CLKS - 1)) begin
                    S_hold_done <= 1'b1;
                    S_paused    <= ~S_paused;
                    S_pause_ev  <= 1'b1;
                end else begin
                    S_hold_cnt  <= S_hold_cnt + 27'd1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // short press requests: the action fires on release
    //-------------------------------------------------------------------------
    reg S_next_pulse, S_prev_pulse;
    reg S_kn_tog, S_kp_tog;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_next_pulse <= 1'b0;
            S_prev_pulse <= 1'b0;
        end else begin
            S_next_pulse <= S_key_rel[0] & ~S_hold_done;
            S_prev_pulse <= S_key_rel[1];
        end
    end

    //-------------------------------------------------------------------------
    // automatic slide show: one step every AUTO_FRAMES frame starts
    //-------------------------------------------------------------------------
    reg [7:0] S_auto_cnt;

    wire S_play      = ~S_paused & I_st_has_img;
    wire S_auto_fire = S_vstart & S_play & (S_auto_cnt >= (AUTO_FRAMES - 1));
    wire S_timer_rst = S_ready_pulse | S_next_pulse | S_prev_pulse | S_pause_ev
                     | S_auto_fire;

    always @(posedge I_clk) begin
        if (I_rst)
            S_auto_cnt <= 8'd0;
        else if (S_timer_rst)
            S_auto_cnt <= 8'd0;
        else if (S_vstart && (S_auto_cnt < (AUTO_FRAMES - 1)))
            S_auto_cnt <= S_auto_cnt + 8'd1;
    end

    wire S_next_ev = S_next_pulse | S_auto_fire;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_kn_tog <= 1'b0;
            S_kp_tog <= 1'b0;
        end else begin
            if (S_next_ev)    S_kn_tog <= ~S_kn_tog;
            if (S_prev_pulse) S_kp_tog <= ~S_kp_tog;
        end
    end

    assign O_key_next_tog = S_kn_tog;
    assign O_key_prev_tog = S_kp_tog;
    assign O_paused       = S_paused;
    assign O_ready_pulse  = S_ready_pulse;

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
    // pixel stream : one SDRAM word per pixel inside the window, black outside
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
            O_video_data  <= (S_win && S_disp_en) ? S_pix : 24'h000000;
        end
    end

    // Read ONLY the display port that is currently on screen.
    //
    //  Bandwidth: inside the window one word per pixel at 73.33 MHz = 73.3 M
    //  words/s.  Reading BOTH ports (as the 640x480 m3_video_src does, where
    //  2 x 25 MHz = 50 M words/s is fine) would need 146 M words/s, which the
    //  single 100 MHz 32 bit SDRAM port of Sdram_Control_4Port cannot deliver
    //  (~90 M words/s) -> the read FIFOs would run dry in the middle of every
    //  line.  One port at 73.3 M words/s is comfortably below the limit.
    //
    //  Consequence: the FIFO of the inactive page keeps the first 256 words it
    //  prefetched while that page was being written, so after a page swap the
    //  first 256 pixels of row 0 may show stale data.  The inactive FIFO never
    //  advances beyond that, so the rest of the frame is always the correct
    //  page from word 0 onwards.
    assign O_rd1_re = S_win && S_rd_en && ~S_disp_page;
    assign O_rd2_re = S_win && S_rd_en &&  S_disp_page;

endmodule
