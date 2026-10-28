//=============================================================================
//  m6_top.v  --  M6 : mixed photo + video playlist player
//                  TF card (SPI) -> FAT32 -> { IMGnnnn.BMP | VIDnnnn.M5V }
//                  -> in-die 8 MB SDRAM double buffer -> 1280x720 HDMI
//                  (+ the soundtrack of the clips as HDMI embedded audio)
//
//  Board : AC208  (AC201-EG4S20 baseboard + AC601 core, EG4S20BG256)
//  Tool  : Anlogic TD 2026.1 SP2   (build.ps1 -> run_flow.tcl -> DefaultFlow)
//
//  What M6 adds on top of M3 (photo player) and M5 (video player)
//  -------------------------------------------------------------
//  M3 could only play still images and M5 could only play one hard-coded clip.
//  M6 scans the root directory ONCE and builds one playlist of both kinds:
//
//      key = {is_video, 4 digit number}   ->  "IMG0001.BMP" is key 0x00001,
//                                              "VID0005.M5V" is key 0x10005
//      order = ascending key = the number on the file name, an image before a
//              video of the same number
//
//  so IMG0001..IMG0004.BMP + VID0005/VID0006.M5V plays 4 photos and then the
//  2 clips, and any other order is obtained by renaming the files.  Both kinds
//  share one page buffer pair and one display chain:
//
//   photos : m6_fat  reads the BMP, m6_page_wr writes ONE 640x480 page
//            (row by row, 128 word bursts) into the page that is NOT on screen;
//            the display swaps it in the vertical blanking.
//   videos : m6_fat hands {first cluster, size} to the video engine
//            (m6_vstream + m6_vdec).  m6_vdec decodes 15 fps frames of
//            320x240 RGB332 RLE, upscales 2x2 and streams them into the SDRAM
//            ring with WR1 auto-increment: one frame = 307200 words = exactly
//            one page, so consecutive frames land on page A / page B by
//            construction and the display keeps swapping them.  The first
//            frame is aimed at the HIDDEN page (I_start_page), so the switch
//            from a photo to a clip never tears.
//
//  One SD engine, two owners
//  -------------------------
//  The card is only ever used by one of the two engines:
//    owner = 0 : m6_fat    (mount, directory scan, BMP load)
//    owner = 1 : m6_vstream (clip stream)
//  The owner mux below covers the sector engine inputs, the vendor sector RAM
//  read address, the WR1 write port and the "page complete" pulse; m6_fat
//  waits for I_vid_idle before it touches anything again.
//
//  Interaction (identical to M3)
//  -----------------------------
//    S0 (KEY0) short  : next item          S1 (KEY1) short : previous item
//    S0 long  (>=1 s) : pause / resume - a photo stops auto advancing, a clip
//                       freezes on its last complete frame
//    photos advance by themselves every AUTO_FRAMES = 179 frames (3.02 s),
//    clips advance when m6_vdec reports the last frame of the file.
//  The 8 digit display always shows  "0006    0003"  = 6 items, playing #3;
//  on an error it shows E<n> exactly like M3/M5.
//
//  Ports
//      clk          50 MHz board oscillator            K14
//      rst_n        KEY2, active low                   H14
//      key0_n       KEY0 (S0), active low              F7
//      key1_n       KEY1 (S1), active low              E7
//      SD_*         TF card in SPI mode (10 MHz)        M2 / L3 / R2 / K6
//      led[3:0]     status                             M12 R16 R15 T15
//      uart_tx      CH340E debug UART, 115200 8N1      P2
//      SEG7_*       2 x 74HC595 digit chain            T14 / R12 / R14
//      O_tmds_*     HDMI TMDS pairs                    B10 D11 C11 F10
//
//  Clock domains
//      50 MHz  clk           : reset synchronisers, 7 segment, UART
//      73.333 MHz pixel_clk  : raster + AXIS + page control + HDMI audio strobe
//      366.667 MHz serial    : TMDS serialisers
//      100 MHz sdram_clk     : SDRAM controller, SD engine, FAT, BMP, video
//=============================================================================
`timescale 1ns / 10ps

module m6_top #(
    //  0 = normal status LEDs / 7 segment playlist counter   (release build)
    //  1 = 7 segment shows internal state words instead of "count  index"
    parameter DEBUG_STREAM = 0,
    //  1 = LEDs show {fat err, mounted} instead of the status LEDs
    parameter DEBUG_ERR    = 0,
    //  clips are encoded at this frame rate (tools/m6_encode.py --fps)
    parameter integer FPS  = 15
) (
    input  wire clk,            // 50 MHz, K14
    input  wire rst_n,          // KEY2, H14, low active
    input  wire key0_n,         // KEY0 (S0), F7, low active : next / pause
    input  wire key1_n,         // KEY1 (S1), E7, low active : previous

    output wire SD_CLK,         // M2
    output wire SD_MOSI,        // L3
    input  wire SD_MISO,        // K6
    output wire SD_CS,          // R2

    output wire [3:0] led,      // M12 R16 R15 T15

    output wire uart_tx,        // P2, CH340E debug UART (115200 8N1)

    output wire SEG7_SCLK,      // T14, 74HC595 SHCP
    output wire SEG7_RCLK,      // R12, 74HC595 STCP
    output wire SEG7_DIO,       // R14, 74HC595 DS

    output wire O_tmds_ch0_p,   // D11 / D12
    output wire O_tmds_ch1_p,   // C11 / A11
    output wire O_tmds_ch2_p,   // F10 / H11
    output wire O_tmds_clk_p    // B10 / C9
);

    //-------------------------------------------------------------------------
    // 1280 x 720 @ 59.26 Hz (73.333 MHz pixel clock, 1650 x 750 total)
    //   the 640x480 frame buffer is displayed inside a centred window
    //-------------------------------------------------------------------------
    localparam HTOTAL  = 1650;
    localparam HSA     = 40;
    localparam HFP     = 110;
    localparam HBP     = 220;
    localparam HACTIVE = 1280;

    localparam VTOTAL  = 750;
    localparam VSA     = 5;
    localparam VFP     = 5;
    localparam VBP     = 20;
    localparam VACTIVE = 720;

    //-------------------------------------------------------------------------
    // frame buffer geometry : 32 bit WORD addresses, 1 pixel = 1 word
    //   page length 640*480 = 307200 words = 0x4B000 words
    //-------------------------------------------------------------------------
    localparam [20:0] PAGE_A_BASE = 21'h000000;     //       0 W
    localparam [20:0] PAGE_B_BASE = 21'h04B000;     //  307200 W
    localparam [20:0] PAGE_A_END  = 21'h04B000;     //  307200 words
    localparam [20:0] PAGE_END    = 21'h096000;     //  614400 words (both pages)

    localparam PAGE_W = 640;
    localparam PAGE_H = 480;

    //-------------------------------------------------------------------------
    // clip scheduler state.  Declared up here because three sections consume it:
    // the display (auto advance gate), the playlist engine (video hand-off) and
    // the owner mux.
    //-------------------------------------------------------------------------
    localparam [1:0] V_IDLE = 2'd0, V_ARM = 2'd1, V_RUN = 2'd2, V_STOP = 2'd3;

    reg [1:0]  S_vst;
    reg        S_vid_owner;         // 1 = the video engine owns SD / WR1
    reg        S_vid_rst;           // synchronous reset of m6_vstream + m6_vdec
    reg        S_vid_end;           // one cycle pulse towards m6_fat
    reg        S_vid_start_page;    // page of the first decoded frame
    reg [31:0] S_vs_clus, S_vs_size;
    reg        S_vs_go;
    wire       S_vid_idle;
    wire       S_rst_vid;
    wire [8:0] S_vs_ram_addr;
    wire       S_fat_vid_req;
    //-------------------------------------------------------------------------
    // clocks / resets
    //-------------------------------------------------------------------------
    wire S_pixel_clk;       //  73.333 MHz
    wire S_serial_clk;      // 366.667 MHz
    wire S_pll_lock;
    wire S_clk100_unused;

    pll_hdmi_720p u_pll (
        .refclk  (clk),
        .reset   (1'b0),
        .extlock (S_pll_lock),
        .clk0_out(S_clk100_unused),
        .clk1_out(S_pixel_clk),
        .clk2_out(S_serial_clk)
    );

    // KEY2 is asynchronous -> sample it on the 50 MHz reference clock
    reg [1:0] S_key_n_sync;
    always @(posedge clk) begin
        S_key_n_sync <= {S_key_n_sync[0], rst_n};
    end

    wire S_rst_n_async = S_pll_lock & S_key_n_sync[1];

    // pixel domain
    reg [1:0] S_rst_pix_sync;
    always @(posedge S_pixel_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_rst_pix_sync <= 2'b00;
        else
            S_rst_pix_sync <= {S_rst_pix_sync[0], 1'b1};
    end
    wire S_rst_pixel = ~S_rst_pix_sync[1];

    // serial domain
    reg [1:0] S_rst_ser_sync;
    always @(posedge S_serial_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_rst_ser_sync <= 2'b00;
        else
            S_rst_ser_sync <= {S_rst_ser_sync[0], 1'b1};
    end
    wire S_rst_serial = ~S_rst_ser_sync[1];

    //-------------------------------------------------------------------------
    // SDRAM controller
    //-------------------------------------------------------------------------
    wire        S_sdram_clk;        // 100 MHz, CLK output of the controller
    wire        S_sdr_clk;          // 100 MHz 270 deg, to the SDRAM macro
    wire [10:0] S_sa;
    wire [1:0]  S_ba;
    wire [1:0]  S_cs_n;
    wire        S_cke, S_ras_n, S_cas_n, S_we_n;
    wire [31:0] S_dq;
    wire [3:0]  S_dqm;
    wire        S_test_oe_unused;

    // WR1 write port : owned by m6_page_wr (photos) or m6_vdec (clips)
    wire [31:0] S_wr_data;
    wire        S_wr;
    wire        S_wr_full;
    wire        S_wr_load;
    wire [20:0] S_wr_addr;
    wire [31:0] S_rd1_data;
    wire [31:0] S_rd2_data;
    wire        S_rd1_re, S_rd2_re;
    wire        S_rd1_empty, S_rd2_empty;

    // The controller is kept in reset ~1.3 ms after the HDMI PLL locks so its
    // internal Sdram_PLL (100 MHz) is comfortably locked too.
    reg [15:0] S_sdram_rst_cnt;
    always @(posedge S_pixel_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_sdram_rst_cnt <= 16'd0;
        else if (!S_sdram_rst_cnt[15])
            S_sdram_rst_cnt <= S_sdram_rst_cnt + 16'd1;
    end
    wire S_sdram_rst_n_pix = S_sdram_rst_cnt[15];

    reg [1:0] S_sdram_rst_sync;
    always @(posedge S_sdram_clk or negedge S_sdram_rst_n_pix) begin
        if (!S_sdram_rst_n_pix)
            S_sdram_rst_sync <= 2'b00;
        else
            S_sdram_rst_sync <= {S_sdram_rst_sync[0], 1'b1};
    end
    wire S_sdram_ready = S_sdram_rst_sync[1];
    wire S_rst_sdram   = ~S_sdram_ready;

    Sdram_Control_4Port u_sdram (
        .REF_CLK      (clk),
        .RESET_N      (~S_rst_sdram),
        .CLK          (S_sdram_clk),

        // FIFO write side 1 : page writer (photos) / video decoder (clips)
        .WR1_DATA     (S_wr_data),
        .WR1          (S_wr),
        .WR1_ADDR     (S_wr_addr),
        .WR1_MAX_ADDR (PAGE_END),
        .WR1_LENGTH   (9'h80),
        .WR1_LOAD     (S_wr_load),
        .WR1_CLK      (S_sdram_clk),
        .WR1_FULL     (S_wr_full),
        .WR1_USE      (),

        // FIFO write side 2 : unused
        .WR2_DATA     (32'd0),
        .WR2          (1'b0),
        .WR2_ADDR     (21'd0),
        .WR2_MAX_ADDR (21'd0),
        .WR2_LENGTH   (9'd0),
        .WR2_LOAD     (1'b0),
        .WR2_CLK      (1'b0),
        .WR2_FULL     (),
        .WR2_USE      (),

        // FIFO read side 1 : page A
        .RD1_DATA     (S_rd1_data),
        .RD1          (S_rd1_re),
        .RD1_ADDR     (PAGE_A_BASE),
        .RD1_MAX_ADDR (PAGE_A_END),
        .RD1_LENGTH   (9'h80),
        .RD1_LOAD     (1'b0),
        .RD1_CLK      (S_pixel_clk),
        .RD1_EMPTY    (S_rd1_empty),
        .RD1_USE      (),

        // FIFO read side 2 : page B
        .RD2_DATA     (S_rd2_data),
        .RD2          (S_rd2_re),
        .RD2_ADDR     (PAGE_B_BASE),
        .RD2_MAX_ADDR (PAGE_END),
        .RD2_LENGTH   (9'h80),
        .RD2_LOAD     (1'b0),
        .RD2_CLK      (S_pixel_clk),
        .RD2_EMPTY    (S_rd2_empty),
        .RD2_USE      (),

        // SDRAM side (stays inside the die)
        .SA           (S_sa),
        .BA           (S_ba),
        .CS_N         (S_cs_n),
        .CKE          (S_cke),
        .RAS_N        (S_ras_n),
        .CAS_N        (S_cas_n),
        .WE_N         (S_we_n),
        .DQ           (S_dq),
        .DQM          (S_dqm),
        .SDR_CLK      (S_sdr_clk),
        .test_oe      (S_test_oe_unused)
    );

    sdram_ip u_sdram_mem (
        .clk   (S_sdr_clk),
        .ras_n (S_ras_n),
        .cas_n (S_cas_n),
        .we_n  (S_we_n),
        .addr  (S_sa),
        .ba    (S_ba),
        .dq    (S_dq),
        .cs_n  (S_cs_n[0]),
        .dm0   (S_dqm[0]),
        .dm1   (S_dqm[1]),
        .dm2   (S_dqm[2]),
        .dm3   (S_dqm[3]),
        .cke   (S_cke)
    );

    //=========================================================================
    // display : raster + centred 640x480 window + axis + page swap + keys
    //=========================================================================
    wire        S_axis_user, S_axis_valid, S_axis_last;
    wire [23:0] S_axis_data;
    wire        S_axis_ready;

    wire        S_ready_tog, S_ready_page, S_disp_page;
    wire        S_key_next_tog, S_key_prev_tog;
    wire        S_st_has_img;
    wire        S_paused;

    // crossed into the 100 MHz domain (video start page / freeze / auto gate)
    reg [1:0] S_dp_s100;
    reg [1:0] S_pa_s100;
    always @(posedge S_sdram_clk) begin
        if (S_rst_sdram) begin
            S_dp_s100 <= 2'b00;
            S_pa_s100 <= 2'b00;
        end else begin
            S_dp_s100 <= {S_dp_s100[0], S_disp_page};
            S_pa_s100 <= {S_pa_s100[0], S_paused};
        end
    end
    wire S_disp_page_s = S_dp_s100[1];
    wire S_paused_s    = S_pa_s100[1];

    m6_video_src720 #(
        .HTOTAL  (HTOTAL),  .HSA     (HSA),   .HBP     (HBP),
        .HFP     (HFP),     .HACTIVE (HACTIVE),
        .VTOTAL  (VTOTAL),  .VSA     (VSA),   .VBP     (VBP),
        .VFP     (VFP),     .VACTIVE (VACTIVE)
    ) u_video_src (
        .I_clk          (S_pixel_clk),
        .I_rst          (S_rst_pixel),
        .I_key0_n       (key0_n),
        .I_key1_n       (key1_n),
        .I_sdram_ready  (S_sdram_ready),
        .I_rd1_data     (S_rd1_data),
        .I_rd2_data     (S_rd2_data),
        .O_rd1_re       (S_rd1_re),
        .O_rd2_re       (S_rd2_re),
        .I_ready_tog    (S_ready_tog),
        .I_ready_page   (S_ready_page),
        .I_st_has_img   (S_st_has_img),
        .I_auto_en      (~S_fat_vid_req),   // a clip advances itself
        .O_disp_page    (S_disp_page),
        .O_key_next_tog (S_key_next_tog),
        .O_key_prev_tog (S_key_prev_tog),
        .O_paused       (S_paused),
        .O_ready_pulse  (),
        .O_video_user   (S_axis_user),
        .O_video_valid  (S_axis_valid),
        .O_video_last   (S_axis_last),
        .O_video_data   (S_axis_data)
    );

    //=========================================================================
    // SD SPI engine + sector buffer, shared by the two owners
    //=========================================================================
    wire        S_sd_init, S_sd_start, S_sd_busy, S_sd_done, S_sd_err;
    wire [31:0] S_sd_lba;
    wire [8:0]  S_buf_addr;
    wire [7:0]  S_buf_dout;

    m6_sd_sec u_sd (
        .I_clk      (S_sdram_clk),
        .I_rst      (S_rst_sdram),
        .I_init     (S_sd_init),
        .I_start    (S_sd_start),
        .I_lba      (S_sd_lba),
        .O_busy     (S_sd_busy),
        .O_done     (S_sd_done),
        .O_err      (S_sd_err),
        .I_ram_addr (S_buf_addr),
        .O_ram_dout (S_buf_dout),
        .O_sd_clk   (SD_CLK),
        .O_sd_mosi  (SD_MOSI),
        .O_sd_cs_n  (SD_CS),
        .I_sd_miso  (SD_MISO)
    );

    //-------------------------------------------------------------------------
    // playlist engine : mount, directory scan, photo loading     (owner 0)
    //-------------------------------------------------------------------------
    wire        S_fat_mounted;
    wire [2:0]  S_fat_err;
    wire [4:0]  S_fat_count, S_fat_index;
    wire [5:0]  S_fat_st;
    wire [7:0]  S_fat_ck;
    wire [31:0] S_fat_data_lba, S_fat_fat_lba;
    wire [7:0]  S_fat_spc;
    wire [4:0]  S_fat_log2spc;

    wire        S_fat_sd_init, S_fat_sd_start;
    wire [31:0] S_fat_sd_lba;

    wire        S_bs_start, S_bs_done;
    wire [8:0]  S_bs_off, S_bs_addr;
    wire [5:0]  S_bs_cnt;
    wire [271:0] S_bs_val;

    wire        S_pp_start, S_pp_done;
    wire [8:0]  S_pp_off, S_pp_addr;
    wire [9:0]  S_pp_cnt;
    wire        S_pp_pv;
    wire [23:0] S_pp_pd;

    wire        S_fat_buf_sel;
    wire        S_pix_valid, S_pix_ready;
    wire [23:0] S_pix_data;

    wire        S_pwr_start, S_pwr_page, S_pwr_bup, S_pwr_flush, S_pwr_done;
    wire        S_pwr_busy;
    wire        S_pwr_wr, S_pwr_load;
    wire [31:0] S_pwr_wr_data;
    wire [20:0] S_pwr_addr;

    wire        S_fat_pg_done, S_fat_pg_page;
    wire [31:0] S_fat_vid_clus, S_fat_vid_size;

    m6_fat u_fat (
        .I_clk         (S_sdram_clk),
        .I_rst         (S_rst_sdram),
        .I_sdram_ready (S_sdram_ready),

        .O_sd_init     (S_fat_sd_init),
        .O_sd_start    (S_fat_sd_start),
        .O_sd_lba      (S_fat_sd_lba),
        .I_sd_busy     (S_sd_busy),
        .I_sd_done     (S_sd_done),
        .I_sd_err      (S_sd_err),

        .O_bs_start    (S_bs_start),
        .O_bs_off      (S_bs_off),
        .O_bs_cnt      (S_bs_cnt),
        .I_bs_done     (S_bs_done),
        .I_bs_val      (S_bs_val),

        .O_pp_start    (S_pp_start),
        .O_pp_off      (S_pp_off),
        .O_pp_cnt      (S_pp_cnt),
        .I_pp_done     (S_pp_done),
        .I_pp_pix_valid(S_pp_pv),
        .I_pp_pix_data (S_pp_pd),

        .O_pix_valid   (S_pix_valid),
        .O_pix_data    (S_pix_data),
        .I_pix_ready   (S_pix_ready),

        .O_wr_start    (S_pwr_start),
        .O_wr_page     (S_pwr_page),
        .O_wr_bottom_up(S_pwr_bup),
        .O_wr_flush    (S_pwr_flush),
        .I_wr_done     (S_pwr_done),

        .I_disp_page   (S_disp_page),
        .O_pg_done     (S_fat_pg_done),
        .O_pg_page     (S_fat_pg_page),

        .I_key_next_tog(S_key_next_tog),
        .I_key_prev_tog(S_key_prev_tog),

        .O_mounted     (S_fat_mounted),
        .O_err         (S_fat_err),
        .O_count       (S_fat_count),
        .O_index       (S_fat_index),
        .O_buf_sel     (S_fat_buf_sel),
        .O_dbg_st      (S_fat_st),
        .O_dbg_ck      (S_fat_ck),

        .O_p_data_lba  (S_fat_data_lba),
        .O_p_fat_lba   (S_fat_fat_lba),
        .O_p_spc       (S_fat_spc),
        .O_p_log2spc   (S_fat_log2spc),

        .O_vid_req     (S_fat_vid_req),
        .O_vid_clus    (S_fat_vid_clus),
        .O_vid_size    (S_fat_vid_size),
        .I_vid_end     (S_vid_end),
        .I_vid_idle    (S_vid_idle)
    );

    //-------------------------------------------------------------------------
    // photo path (100 MHz) : FAT32 byte fetcher + BMP pixel pump + page writer
    //-------------------------------------------------------------------------
    m6_byte_seq u_bs (
        .I_clk   (S_sdram_clk),
        .I_rst   (S_rst_sdram),
        .I_start (S_bs_start),
        .I_off   (S_bs_off),
        .I_cnt   (S_bs_cnt),
        .O_busy  (),
        .O_done  (S_bs_done),
        .O_addr  (S_bs_addr),
        .I_din   (S_buf_dout),
        .O_val   (S_bs_val)
    );

    m6_pix_pump u_pp (
        .I_clk       (S_sdram_clk),
        .I_rst       (S_rst_sdram),
        .I_start     (S_pp_start),
        .I_off       (S_pp_off),
        .I_cnt       (S_pp_cnt),
        .O_busy      (),
        .O_done      (S_pp_done),
        .O_addr      (S_pp_addr),
        .I_din       (S_buf_dout),
        .O_pix_valid (S_pp_pv),
        .O_pix_data  (S_pp_pd),
        .I_pix_ready (S_pix_ready)
    );

    m6_page_wr #(
        .HACTIVE (PAGE_W),          // frame buffer geometry, not the canvas
        .VACTIVE (PAGE_H)
    ) u_pwr (
        .I_clk         (S_sdram_clk),
        .I_rst         (S_rst_sdram),
        .I_start       (S_pwr_start),
        .I_page        (S_pwr_page),
        .I_bottom_up   (S_pwr_bup),
        .I_pix_data    (S_pix_data),
        .I_pix_valid   (S_pix_valid),
        .O_pix_ready   (S_pix_ready),
        .I_flush       (S_pwr_flush),
        .I_fifo_full   (S_wr_full),
        .O_wr          (S_pwr_wr),
        .O_wr_data     (S_pwr_wr_data),
        .O_load        (S_pwr_load),
        .O_addr        (S_pwr_addr),
        .O_busy        (S_pwr_busy),
        .O_done        (S_pwr_done)
    );

    //-------------------------------------------------------------------------
    // video path (100 MHz) : cluster streamer + M5V1 decoder          (owner 1)
    //-------------------------------------------------------------------------
    wire        S_vs_sd_start;
    wire [31:0] S_vs_sd_lba;
    wire        S_vs_byte_valid, S_vs_eof;
    wire [7:0]  S_vs_byte;
    wire        S_vs_busy, S_vs_err;
    wire [2:0]  S_vs_err3;
    wire [5:0]  S_vs_st;
    wire [31:0] S_vs_byt;

    wire        S_vd_wr, S_vd_wr_load;
    wire [31:0] S_vd_wr_data;
    wire [20:0] S_vd_wr_addr;
    wire        S_vd_pg_done, S_vd_pg_page, S_vd_clip_end;
    wire        S_vd_busy, S_vd_byte_ready;
    wire [15:0] S_vd_frm;
    wire [5:0]  S_vd_st;
    wire [2:0]  S_vd_err;
    wire        S_aud_we;
    wire [15:0] S_aud_data;
    wire [31:0] S_vdbg_vbyt, S_vdbg_px, S_vdbg_len, S_vdbg_endv;
    wire [31:0] S_vdbg_hdrb, S_vdbg_raw32, S_vdbg_rawh;
    wire [15:0] S_vdbg_audn;

    assign S_rst_vid = S_rst_sdram | S_vid_rst;
    assign S_vid_idle = (S_vst == V_IDLE) && !S_vid_owner;

    // byte handshake, gated by the pause (freeze) and by ownership
    wire S_vb_ready = S_vd_byte_ready & ~S_paused_s & S_vid_owner;

    m6_vstream u_vs (
        .I_clk         (S_sdram_clk),
        .I_rst         (S_rst_vid),
        .I_sdram_ready (S_sdram_ready),
        .I_go          (S_vs_go),
        .I_clus        (S_vs_clus),
        .I_size        (S_vs_size),
        .I_data_lba    (S_fat_data_lba),
        .I_fat_lba     (S_fat_fat_lba),
        .I_spc         (S_fat_spc),
        .I_log2spc     (S_fat_log2spc),
        .O_sd_start    (S_vs_sd_start),
        .O_sd_lba      (S_vs_sd_lba),
        .I_sd_done     (S_sd_done),
        .I_sd_err      (S_sd_err),
        .O_ram_addr    (S_vs_ram_addr),
        .I_ram_dout    (S_buf_dout),
        .O_byte_valid  (S_vs_byte_valid),
        .O_byte        (S_vs_byte),
        .I_byte_ready  (S_vb_ready),
        .O_busy        (S_vs_busy),
        .O_err         (S_vs_err3),
        .O_st          (S_vs_st),
        .O_byt         (S_vs_byt),
        .O_eof         (S_vs_eof)
    );
    assign S_vs_err = (S_vs_err3 != 3'd0);

    //  m6_vdec reports two kinds of error:
    //    1 / 4 : the file header or a frame header is not a valid M5V1 block,
    //            the clip cannot be decoded -> give up on it
    //    2 / 5 : the RLE stream produced a wrong row count / missed end token.
    //            These are bring-up diagnostics of a *desynchronised* stream;
    //            the frame framing itself comes from payload_len, so playback
    //            continues.  They must not abort the clip.
    wire S_vd_fatal = (S_vd_err == 3'd1) || (S_vd_err == 3'd4);

    m6_vdec #(
        .CLK_HZ (100_000_000),
        .FPS    (FPS)
    ) u_vd (
        .I_clk         (S_sdram_clk),
        .I_rst         (S_rst_vid),
        .I_sdram_ready (S_sdram_ready),
        .I_byte_valid  (S_vs_byte_valid),
        .I_byte        (S_vs_byte),
        .O_byte_ready  (S_vd_byte_ready),
        .I_eof         (S_vs_eof),
        .O_wr          (S_vd_wr),
        .O_wr_data     (S_vd_wr_data),
        .I_wr_full     (S_wr_full),
        .O_wr_load     (S_vd_wr_load),
        .O_wr_addr     (S_vd_wr_addr),
        .I_start_page  (S_vid_start_page),
        .O_pg_done     (S_vd_pg_done),
        .O_pg_page     (S_vd_pg_page),
        .O_clip_end    (S_vd_clip_end),
        .O_busy        (S_vd_busy),
        .O_frame_cnt   (S_vd_frm),
        .O_st          (S_vd_st),
        .O_err         (S_vd_err),
        .O_aud_we      (S_aud_we),
        .O_aud_data    (S_aud_data),
        .O_dbg_vbyt    (S_vdbg_vbyt),
        .O_dbg_px      (S_vdbg_px),
        .O_dbg_audn    (S_vdbg_audn),
        .O_dbg_len     (S_vdbg_len),
        .O_dbg_endv    (S_vdbg_endv),
        .O_dbg_hdrb    (S_vdbg_hdrb),
        .O_dbg_raw32   (S_vdbg_raw32),
        .O_dbg_rawh    (S_vdbg_rawh)
    );

    //-------------------------------------------------------------------------
    // SD / WR1 owner mux
    //-------------------------------------------------------------------------
    assign S_buf_addr = S_vid_owner ? S_vs_ram_addr
                                    : (S_fat_buf_sel ? S_pp_addr : S_bs_addr);

    assign S_sd_init  = S_vid_owner ? 1'b0          : S_fat_sd_init;
    assign S_sd_start = S_vid_owner ? S_vs_sd_start : S_fat_sd_start;
    assign S_sd_lba   = S_vid_owner ? S_vs_sd_lba   : S_fat_sd_lba;

    assign S_wr       = S_vid_owner ? S_vd_wr       : S_pwr_wr;
    assign S_wr_data  = S_vid_owner ? S_vd_wr_data  : S_pwr_wr_data;
    assign S_wr_load  = S_vid_owner ? S_vd_wr_load  : S_pwr_load;
    assign S_wr_addr  = S_vid_owner ? S_vd_wr_addr  : S_pwr_addr;

    //-------------------------------------------------------------------------
    // clip scheduler : arm / run / stop the video engine for one playlist item
    //-------------------------------------------------------------------------

    always @(posedge S_sdram_clk) begin
        if (S_rst_sdram) begin
            S_vst            <= V_IDLE;
            S_vid_owner      <= 1'b0;
            S_vid_rst        <= 1'b1;
            S_vs_go          <= 1'b0;
            S_vid_end        <= 1'b0;
            S_vs_clus        <= 32'd0;
            S_vs_size        <= 32'd0;
            S_vid_start_page <= 1'b0;
        end else begin
            S_vs_go   <= 1'b0;
            S_vid_end <= 1'b0;

            case (S_vst)
            V_IDLE: begin
                S_vid_rst <= 1'b1;              // keep the pair parked
                if (S_fat_vid_req) begin
                    S_vs_clus        <= S_fat_vid_clus;
                    S_vs_size        <= S_fat_vid_size;
                    S_vid_start_page <= ~S_disp_page_s;  // frame 0 -> hidden page
                    S_vid_owner      <= 1'b1;
                    S_vst            <= V_ARM;
                end
            end

            V_ARM: begin
                S_vid_rst <= 1'b0;              // release, then start streaming
                S_vs_go   <= 1'b1;
                S_vst     <= V_RUN;
            end

            V_RUN: begin
                //  end of the clip (the decoder counted the frames itself), a
                //  streamer / decoder error, or the playlist engine walking away
                if (S_vd_clip_end || (S_vs_err3 != 3'd0) ||
                    S_vd_fatal || !S_fat_vid_req) begin
                    S_vid_end <= 1'b1;
                    S_vst     <= V_STOP;
                end
            end

            V_STOP: begin
                S_vid_owner <= 1'b0;
                S_vid_rst   <= 1'b1;
                S_vst       <= V_IDLE;
            end

            default: S_vst <= V_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // single "page complete" toggle, shared by the photo loader and the decoder
    //-------------------------------------------------------------------------
    reg S_rtog, S_rpage;
    wire S_pg_done = S_vid_owner ? S_vd_pg_done : S_fat_pg_done;
    wire S_pg_page = S_vid_owner ? S_vd_pg_page : S_fat_pg_page;

    always @(posedge S_sdram_clk) begin
        if (S_rst_sdram) begin
            S_rtog  <= 1'b0;
            S_rpage <= 1'b0;
        end else if (S_pg_done) begin
            S_rtog  <= ~S_rtog;
            S_rpage <= S_pg_page;
        end
    end
    assign S_ready_tog  = S_rtog;
    assign S_ready_page = S_rpage;

    assign S_st_has_img = (S_fat_count != 5'd0);

    //=========================================================================
    // HDMI embedded audio : the decoded 48 kHz mono samples of a clip
    //
    // 48 kHz strobe from the 73.333333 MHz pixel clock : 32 bit phase
    // accumulator, step = round(48000 * 2^32 / 73333333) = 2811250
    //   -> 2811250 / 2^32 * 73.333333 MHz = 47.9999 kHz
    //  A 33 bit accumulator would leave the tick high for half of the cycles -
    //  that was the M5 bug that made the monitor play full scale noise.
    //=========================================================================
    reg  [31:0] S_aph;
    wire [32:0] S_aph_nx = {1'b0, S_aph} + 33'd2811250;

    always @(posedge S_pixel_clk) begin
        if (S_rst_pixel) S_aph <= 32'd0;
        else             S_aph <= S_aph_nx[31:0];
    end
    wire S_aud48 = S_aph_nx[32];        // one pixel clock pulse per sample

    wire [15:0] S_hdmi_sample;
    wire        S_acr_valid;
    wire [19:0] S_acr_cts, S_acr_n;

    wire [13:0] S_hdmi_lvl;
    wire [31:0] S_hdmi_wcnt, S_hdmi_ovf, S_hdmi_unf;

    m6_aud_fifo #(
        .AW (12)                        // 4096 samples = 85 ms
    ) u_hdmi_aud_fifo (
        .I_wclk   (S_sdram_clk),
        .I_wrst   (S_rst_sdram),
        .I_we     (S_aud_we & S_vid_owner),
        .I_wdata  (S_aud_data),
        .O_wlevel (S_hdmi_lvl),
        .O_wr_cnt (S_hdmi_wcnt),
        .O_ovf_cnt(S_hdmi_ovf),
        .I_rclk   (S_pixel_clk),
        .I_rrst   (S_rst_pixel),
        .I_rd     (S_aud48),
        .O_rdata  (S_hdmi_sample),
        .O_unf_cnt(S_hdmi_unf)
    );

    m6_audio_acr #(
        .ACR_N (6144)                   // N for 48 kHz
    ) u_hdmi_acr (
        .I_clk         (S_pixel_clk),
        .I_rst         (S_rst_pixel),
        .I_audio_valid (S_aud48),
        .O_acr_valid   (S_acr_valid),
        .O_acr_cts     (S_acr_cts),
        .O_acr_n       (S_acr_n)
    );

    wire [15:0] S_hdmi_src = S_hdmi_sample;

    //=========================================================================
    // 7 segment display : vendor HEX8 (1 kHz digit scan) + HC595_Driver
    //   digits 7..4 : number of playlist items
    //   digits 3..0 : 1 based index of the item on screen
    //   "E<n>"      : error code n
    //=========================================================================
    wire [31:0] S_hex_data;
    wire [7:0]  S_hex_sw;
    wire        S_hex_mode;
    wire [7:0]  S_hex_seg, S_hex_sel;

    //  DEBUG_STREAM = 1 : four pages of internal state instead of the counter
    reg [26:0] S_dbg_ptmr;
    always @(posedge clk) begin
        if (~S_rst_n_async) S_dbg_ptmr <= 27'd0;
        else                S_dbg_ptmr <= S_dbg_ptmr + 27'd1;
    end
    wire [1:0] S_dbg_ppage = S_dbg_ptmr[26:25];
    reg  [31:0] S_hex_dbg;
    always @(*) begin
        case (S_dbg_ppage)
            // page 0 : playlist state {count, index, fat_st, fat_err, checks}
            2'd0: S_hex_dbg = {S_fat_count, S_fat_index, S_fat_st,
                               S_fat_err, S_fat_ck, 5'd0};
            // page 1 : video state {vdec_st, vstr_st, errs, frame count[13:0]}
            2'd1: S_hex_dbg = {S_vd_st, S_vs_st, S_vd_err, S_vs_err3,
                               S_vd_frm[13:0]};
            // page 2 : bytes the decoder has consumed
            2'd2: S_hex_dbg = S_vdbg_vbyt;
            // page 3 : bytes the streamer has handed over
            default: S_hex_dbg = S_vs_byt;
        endcase
    end

    m6_hex_status u_hex_status (
        .I_clk       (clk),                 // 50 MHz display domain
        .I_rst       (~S_rst_n_async),
        .I_mounted   (S_fat_mounted),
        .I_err       (S_fat_err | S_vs_err3 | {2'd0, S_vd_fatal}),
        .I_count     (S_fat_count),
        .I_index     (S_fat_index),
        .I_busy      (S_pwr_busy | S_vd_busy),
        .I_paused    (S_paused),
        .I_dbg_en    (DEBUG_STREAM),
        .I_dbg_data  (S_hex_dbg),
        .O_disp_data (S_hex_data),
        .O_sw        (S_hex_sw),
        .O_mode      (S_hex_mode)
    );

    HEX8 u_hex8 (
        .clk       (clk),
        .rst_n     (S_rst_n_async),
        .en        (1'b1),
        .switch    (1'b1),
        .mode      (S_hex_mode),
        .sw        (S_hex_sw),
        .disp_data (S_hex_data),
        .sel       (S_hex_sel),
        .seg       (S_hex_seg)
    );

    HC595_Driver u_hc595 (
        .Clk        (clk),
        .Rst_n      (S_rst_n_async),
        .Data       ({S_hex_seg, S_hex_sel}),
        .S_EN       (1'b1),
        .SEG7_SCLK  (SEG7_SCLK),
        .SEG7_RCLK  (SEG7_RCLK),
        .SEG7_DIO   (SEG7_DIO)
    );

    //-------------------------------------------------------------------------
    // debug UART status line (CH340E on the baseboard, P2, 115200 8N1)
    //   see rtl/m6_dbg_vid.v for the fixed width field layout
    //-------------------------------------------------------------------------
    wire S_dbg_tx;

    m6_dbg_vid #(
        .CLK_HZ (50_000_000),
        .BAUD   (115200)
    ) u_dbg (
        .I_clk        (clk),
        .I_rst        (~S_rst_n_async),
        .I_sst        (S_vs_st),
        .I_vst        (S_vd_st),
        .I_err        (S_fat_err | S_vs_err3 | {2'd0, S_vd_fatal}),
        .I_mnt        (S_fat_mounted),
        .I_frm        (S_vd_frm),
        .I_vbyt       (S_vdbg_vbyt),
        .I_vpx        (S_vdbg_px),
        .I_audn       (S_vdbg_audn),
        .I_len        (S_vdbg_len),
        .I_byt        (S_vs_byt),
        .I_chk        ({S_fat_count, S_fat_index, S_fat_st, 3'd0, S_fat_ck[7:0],
                        S_vid_owner}),
        .I_first      (S_fat_fat_lba),
        .I_lba        (S_sd_lba),
        .I_size       (S_vs_size),
        .I_eof        (S_vs_eof),
        .O_uart_tx    (S_dbg_tx)
    );

    assign uart_tx = S_dbg_tx;

    //-------------------------------------------------------------------------
    // status LEDs (active low : lit = the condition is true)
    //   D1 : TF card mounted / FAT32 playlist built
    //   D2 : an error was reported (FAT / streamer / decoder)
    //   D3 : a photo is being loaded or a clip is being decoded
    //   D4 : a clip is on screen (HDMI audio flowing)
    //-------------------------------------------------------------------------
    reg [3:0] S_led;
    always @(posedge S_sdram_clk) begin
        if (S_rst_sdram)
            S_led <= 4'b0000;
        else
            S_led <= {S_vid_owner,
                      ((S_fat_err | S_vs_err3 | {2'd0, S_vd_fatal}) != 3'd0),
                      (S_pwr_busy | S_vd_busy),
                      S_fat_mounted};
    end
    assign led = DEBUG_ERR ? {~S_fat_err, S_fat_mounted} : ~S_led;

    //=========================================================================
    // HDMI 1.4b transmitter core (encrypted IP, vendor supplied) + serialisers
    //=========================================================================
    wire [9:0] S_ch0_tmds_data;
    wire [9:0] S_ch1_tmds_data;
    wire [9:0] S_ch2_tmds_data;
    wire [9:0] S_clk_tmds_data;

    wire S_ddc_scl_unused;
    wire S_ddc_sda_unused;
    wire S_edid_valid_unused;
    wire [7:0] S_edid_data_unused;
    wire S_video_locked_unused;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),
        .HTOTAL            (HTOTAL),
        .HSA               (HSA),
        .HFP               (HFP),
        .HBP               (HBP),
        .HACTIVE           (HACTIVE),
        .VTOTAL            (VTOTAL),
        .VSA               (VSA),
        .VFP               (VFP),
        .VBP               (VBP),
        .VACTIVE           (VACTIVE),
        .VIDEO_VIC         (4),         // 1280x720p @ 60 Hz
        .VIDEO_TPG         ("Disable"), // external AXIS stream only
        .VIDEO_FORMAT      ("RGB"),
        .AUDIO_SAMPLE_RATE ("48K"),
        .IIC_SCL_DIV       (125)
    ) u_hdmi_core (
        .I_pixel_clk        (S_pixel_clk),
        .I_rst              (S_rst_pixel),
        .I_edid_read_trig   (1'b0),
        .O_edid_read_valid  (S_edid_valid_unused),
        .O_edid_read_data   (S_edid_data_unused),
        .I_axis_s_user      (S_axis_user),
        .I_axis_s_valid     (S_axis_valid),
        .I_axis_s_last      (S_axis_last),
        .I_axis_s_data      (S_axis_data),
        .O_axis_s_ready     (S_axis_ready),
        .I_audio_valid      (S_aud48),
        .I_audio_left_data  ({S_hdmi_src, 8'h00}),
        .I_audio_right_data ({S_hdmi_src, 8'h00}),
        .I_acr_valid        (S_acr_valid),
        .I_acr_cts          (S_acr_cts),
        .I_acr_n            (S_acr_n),
        .O_video_locked     (S_video_locked_unused),
        .O_ddc_scl          (S_ddc_scl_unused),
        .IO_ddc_sda         (S_ddc_sda_unused),
        .O_ch0_tmds_data    (S_ch0_tmds_data),
        .O_ch1_tmds_data    (S_ch1_tmds_data),
        .O_ch2_tmds_data    (S_ch2_tmds_data),
        .O_clk_tmds_data    (S_clk_tmds_data)
    );

    hdmi_phy_wrapper #(
        .DEVICE ("EG")
    ) u_hdmi_phy (
        .I_pixel_clk        (S_pixel_clk),
        .I_serial_clk       (S_serial_clk),
        .I_rst              (S_rst_serial),
        .I_tmds_channel_0   (S_ch0_tmds_data),
        .I_tmds_channel_1   (S_ch1_tmds_data),
        .I_tmds_channel_2   (S_ch2_tmds_data),
        .I_tmds_channel_clk (S_clk_tmds_data),
        .O_tmds_ch0_p       (O_tmds_ch0_p),
        .O_tmds_ch1_p       (O_tmds_ch1_p),
        .O_tmds_ch2_p       (O_tmds_ch2_p),
        .O_tmds_clk_p       (O_tmds_clk_p)
    );

endmodule
