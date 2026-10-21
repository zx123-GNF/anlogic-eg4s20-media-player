//=============================================================================
//  m4_video_src.v
//  M3 video source + frame-cache page controller + interaction logic
//  (25 MHz pixel domain).  Derived from m2_video_src.v: the two SDRAM read
//  ports, the 640x480 raster, the AXIS stream and the "swap in vertical
//  blanking" page policy are UNCHANGED.
//
//      RD1  page A   base 0x000000, 307200 words, wraps at 0x0004B000
//      RD2  page B   base 0x04B000, 307200 words, wraps at 0x00096000
//
//  WHAT M3 ADDS (all of it inside this 25 MHz domain - no new clock, no new
//  clock constraint, nothing added to the 100 MHz SDRAM domain):
//
//   * KEY0 / KEY1 debounce keeps the M2 filter (2^18 x 40 ns = 10.5 ms) but
//     the action now fires on RELEASE.  That is what makes a long press
//     distinguishable from a short one.
//   * KEY0 short press  (< 1 s)  -> next image      (toggle to the 100 MHz FSM)
//     KEY0 long  press  (>= 1 s) -> auto play / pause toggle
//     KEY1 short press           -> previous image
//     KEY1 has no long press action: holding it still means "one step back"
//     and never changes the play mode, so browsing backwards can not pause
//     the slide show by accident.
//     The long press fires at the 1.000 s mark (immediate feedback) and the
//     following release is swallowed, so a long press never also steps.
//   * automatic slide show: a frame counter (S_auto_cnt) that saturates at
//     AUTO_FRAMES-1 = 178, so the 179th frame start (3.007 s at 59.52 Hz)
//     issues the same "next" toggle a key press does.  The counter is
//     restarted by
//         - every completed page (I_ready_tog edge) -> every picture gets a
//           full 3 s slot; the ~0.4 s load time does not eat into it,
//         - every manual switch,
//         - every pause/resume toggle (resuming never jumps immediately).
//     Auto play is inhibited while the loader has no image list
//     (I_st_has_img = 0), so an empty / missing card is not re-tried every 3 s
//     (M2 behaviour: a key press re-tries the mount).
//   * keys pressed while the loader is busy are ignored by construction: the
//     100 MHz FSM samples the key toggles only in its S_KEY state, so a toggle
//     that arrives during a load changes the level but produces no edge.
//
//  The 640x480 AXIS timing is bit identical to M1/M2 (see m0-report.md).
//=============================================================================
`timescale 1ns / 10ps

module m4_video_src #(
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

    // 179 x 16.800 ms = 3.007 s   (25 MHz / (800*525) = 59.52 Hz)
    parameter AUTO_FRAMES = 179,
    // 25 000 000 x 40 ns = 1.000 s  (needs 25 bits)
    parameter HOLD_CLKS   = 25000000
) (
    input  wire        I_clk,           // 25 MHz pixel clock
    input  wire        I_rst,           // active high

    input  wire        I_key0_n,        // KEY0, low active : next / long = pause
    input  wire        I_key1_n,        // KEY1, low active : previous
    input  wire        I_sdram_ready,   // level from the 100 MHz domain

    input  wire [31:0] I_rd1_data,      // SDRAM read port 1 (page A)
    input  wire [31:0] I_rd2_data,      // SDRAM read port 2 (page B)
    output wire        O_rd1_re,
    output wire        O_rd2_re,

    input  wire        I_ready_tog,     // loader: a page has been completed
    input  wire        I_ready_page,    // which page
    output wire        O_disp_page,     // page currently on screen

    // quasi static status from the 100 MHz loader (single bit -> 2FF)
    input  wire        I_st_has_img,    // loader has a non empty image list

    output wire        O_key_next_tog,  // forwarded to the 100 MHz domain
    output wire        O_key_prev_tog,

    // interaction status
    output wire        O_paused,        // 1 = slide show paused
    output wire        O_ready_pulse,   // 1 cycle: a page has just completed

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
    //   S_key_stb[k] : 1 = released, 0 = pressed (stable, debounced)
    //   S_key_press  : one cycle, just pressed
    //   S_key_rel    : one cycle, just released
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
    wire [1:0] S_key_rel   = ~S_key_stb_d & S_key_stb;   // 1 = just released

    //-------------------------------------------------------------------------
    // long press of KEY0 : >= HOLD_CLKS while the debounced key stays down
    //   S_pause_ev  : 1 cycle at the 1.000 s mark -> toggle auto play
    //   S_hold_done : sticky until the key is released; swallows the release
    //                 so that a long press never also steps to the next image
    //-------------------------------------------------------------------------
    reg [24:0] S_hold_cnt;
    reg        S_hold_done;
    reg        S_paused;
    reg        S_pause_ev;       // 1 cycle : pause state changed

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_hold_cnt  <= 25'd0;
            S_hold_done <= 1'b0;
            S_paused    <= 1'b0;
            S_pause_ev  <= 1'b0;
        end else begin
            S_pause_ev <= 1'b0;

            if (S_key_press[0]) begin
                S_hold_cnt  <= 25'd0;
                S_hold_done <= 1'b0;
            end else if (!S_key_stb[0] && !S_hold_done) begin
                if (S_hold_cnt >= (HOLD_CLKS - 1)) begin
                    S_hold_done <= 1'b1;         // long press detected
                    S_paused    <= ~S_paused;
                    S_pause_ev  <= 1'b1;
                end else begin
                    S_hold_cnt  <= S_hold_cnt + 25'd1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // short press requests (actions happen on release)
    //-------------------------------------------------------------------------
    reg S_next_pulse, S_prev_pulse;     // 1 cycle, manual step requests
    reg S_kn_tog, S_kp_tog;             // level toggles to the 100 MHz domain

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
    // clock domain crossing : ready toggle + page level, sdram ready level,
    // "image list not empty" level
    //-------------------------------------------------------------------------
    reg [2:0] S_ready_sync;
    reg [1:0] S_ready_pg_sync;
    reg [1:0] S_sdr_sync;
    reg [1:0] S_himg_sync;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_ready_sync    <= 3'b000;
            S_ready_pg_sync <= 2'b00;
            S_sdr_sync      <= 2'b00;
            S_himg_sync     <= 2'b00;
        end else begin
            S_ready_sync    <= {S_ready_sync[1:0], I_ready_tog};
            S_ready_pg_sync <= {S_ready_pg_sync[0], I_ready_page};
            S_sdr_sync      <= {S_sdr_sync[0], I_sdram_ready};
            S_himg_sync     <= {S_himg_sync[0], I_st_has_img};
        end
    end

    wire S_ready_pulse = S_ready_sync[1] ^ S_ready_sync[2];
    wire S_ready_pg    = S_ready_pg_sync[1];
    wire S_sdram_ok    = S_sdr_sync[1];
    wire S_has_img     = S_himg_sync[1];

    assign O_ready_pulse = S_ready_pulse;

    //-------------------------------------------------------------------------
    // automatic slide show timer
    //   16.800 ms per frame  ->  179 frames = 3.007 s
    //   restarted by: page complete, manual step, pause/resume, and the
    //   automatic step itself
    //-------------------------------------------------------------------------
    reg [7:0] S_auto_cnt;

    wire S_play      = ~S_paused & S_has_img;
    wire S_auto_fire = S_vstart & S_play & (S_auto_cnt >= (AUTO_FRAMES - 1));

    // the counter restarts on the auto step itself as well, otherwise it would
    // stay saturated during the ~0.4 s load and issue one "next" toggle per
    // frame (all of them ignored by the busy FSM, but pointless)
    wire S_timer_rst = S_ready_pulse | S_next_pulse | S_prev_pulse | S_pause_ev
                     | S_auto_fire;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_auto_cnt <= 8'd0;
        end else if (S_timer_rst) begin
            S_auto_cnt <= 8'd0;
        end else if (S_vstart) begin
            if (S_auto_cnt < (AUTO_FRAMES - 1))
                S_auto_cnt <= S_auto_cnt + 8'd1;
        end
    end

    // one "next" event per clock at most: a key release or the auto timer
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

    //-------------------------------------------------------------------------
    // page control (unchanged from M2)
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
