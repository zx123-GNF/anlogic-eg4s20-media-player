//=============================================================================
//  m4_top.v  --  M2 milestone : TF card (SPI) -> FAT32 -> 640x480 24 bit BMP
//                 -> SDRAM page B -> page swap -> HDMI
//
//  Board : AC208  (EG4S20BG256, Anlogic SALEAGLE 4, in-die 2M x 32 SDRAM)
//  Tool  : Anlogic TD 2026.1 SP2   (see run_flow.tcl / build.ps1)
//
//  Ports
//      clk          50 MHz board oscillator            K14
//      rst_n        KEY2, active low                   H14
//      key0_n       KEY0, active low : next image      F7
//      key1_n       KEY1, active low : previous image  E7
//      SD_CLK/MOSI/CS  TF card in SPI mode             M2 / L3 / R2
//      SD_MISO                                        K6
//      led[3:0]     status                             M12 R16 R15 T15
//      O_tmds_*     HDMI TMDS pairs                    B10 D11 C11 F10
//
//  Clock domains
//      50 MHz  clk          : reset synchronisers only
//      25 MHz  pixel_clk    : raster + AXIS + page control  (m4_video_src)
//      125 MHz serial_clk   : TMDS serialisers
//      100 MHz sdram_clk    : Sdram_Control_4Port, SD SPI engine, FAT32 FSM,
//                             sector buffer, pixel pump, page writer
//
//  Data path
//      TF --SPI--> sd_card_control (512x8 RD_RAM)
//                      |  (byte reads, 100 MHz)
//                      +--> m4_byte_seq   : FAT32 structures -> registers
//                      +--> m4_pix_pump   : BMP payload -> 24 bit RGB pixels
//                      |
//                      +--> m4_page_wr --> WR1 --> SDRAM page A / page B
//                                                    |
//                          RD1 (page A) -------------+--> mux --> AXIS --> HDMI
//                          RD2 (page B) -------------+
//
//  Page policy: the loader fills the page that is NOT displayed and asks the
//  pixel domain to swap at the next frame start (vertical blanking), so the
//  image appears only when it has been completely written.
//=============================================================================
`timescale 1ns / 10ps

module m4_top #(
    //  0 = normal status LEDs
    //  1 = DEBUG: led[2:0] = ~S_fat_err, i.e. the lights read as the FAT error
    //      code in binary (lit = 1); led[3] off.  Codes: 1 = SD init failed,
    //      2 = FAT32 BPB/dir failed, 3 = no IMGnnnn.BMP found, 4 = bad BMP
    //      header, 5 = MBR signature 0x55AA missing (sector data is garbage),
    //      6 = file smaller than 640x480, 7 = no FAT partition entry accepted.
    // Audio bring-up debug (LED map, all lights active low: LIT = condition true)
    // DEBUG_AUDIO = 2 : I2C bus scanner instead of the initialiser, ASCII report
    //                   on the CH340E UART (rtl/m4_i2c_scan.v; it found the
    //                   codec at 0x1A, plus the EEPROM/RTC/MAC devices).
    // DEBUG_AUDIO = 0 : normal play/status LEDs (release build)
    parameter DEBUG_AUDIO = 1,
    parameter DEBUG_ERR = 0
) (
    input  wire clk,            // 50 MHz, K14
    input  wire rst_n,          // KEY2, H14, low active
    input  wire key0_n,         // KEY0, F7, low active : next image
    input  wire key1_n,         // KEY1, E7, low active : previous image

    output wire SD_CLK,         // M2
    output wire SD_MOSI,        // L3
    input  wire SD_MISO,        // K6
    output wire SD_CS,          // R2

    output wire [3:0] led,      // M12 R16 R15 T15

    output wire uart_tx,        // P2, CH340E debug UART (115200 8N1)

    output wire SEG7_SCLK,      // T14, 74HC595 SHCP
    output wire SEG7_RCLK,      // R12, 74HC595 STCP
    output wire SEG7_DIO,       // R14, 74HC595 DS

    output wire I2S_MCLK,       // B8  codec MCLK   (12.288136 MHz)
    output wire I2S_BCLK,       // C8  codec SCLK   (3.072034 MHz, FPGA master)
    output wire I2S_DACLRC,     // A7  codec LRCK   (48.0005 kHz, FPGA master)
    output wire I2S_DACDAT,     // A8  codec DSDIN  (DAC data)
    //  C7 (core pin 102, ES_ASDOUT = codec ADCDAT) is a CODEC OUTPUT and is
    //  deliberately not driven by the FPGA: the audio path here is playback
    //  only (the old "ADCLRC" output on C7 fought the codec, see IO.adc).
    output wire I2C_SCL,        // L16 shared I2C clock (codec / EEPROM / RTC)
    inout  wire I2C_SDA,        // M16 shared I2C data (tri-state)

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
    //   page length 640*480 = 307200 words = 0x4B000 words = 0x12C000 bytes
    //-------------------------------------------------------------------------
    localparam [20:0] PAGE_A_BASE = 21'h000000;     //       0 W, 0x000000 B
    localparam [20:0] PAGE_B_BASE = 21'h04B000;     //  307200 W, 0x12C000 B
    localparam [20:0] PAGE_A_END  = 21'h04B000;     //  307200 words
    localparam [20:0] PAGE_END    = 21'h096000;     //  614400 words

    //  A page is one 640x480 image -- NOT the 1280x720 output canvas.  The page
    //  writer derives its row length (HACTIVE), row count (VACTIVE) and the
    //  hard-coded row stride (row*640) from these, and the BMP loader / test
    //  pattern produce exactly 640*480 words.  Feeding it the canvas geometry
    //  makes it wait for 1280*720 = 921600 pixels that never arrive, so the
    //  pattern path deadlocks in S_PAT_E while the writer waits in W_ROW:
    //  O_busy stays high, the page never swaps, the screen stays black.
    localparam PAGE_W = 640;
    localparam PAGE_H = 480;

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

    // 50 MHz domain reset (HDMI PLL lock + KEY2), used by the I2C scanner so
    // that it runs even if the audio PLL never locks
    reg [1:0] S_rst50_sync;
    always @(posedge clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_rst50_sync <= 2'b00;
        else
            S_rst50_sync <= {S_rst50_sync[0], 1'b1};
    end
    wire S_rst_50 = ~S_rst50_sync[1];

    // pixel domain (25 MHz)
    reg [1:0] S_rst_pix_sync;
    always @(posedge S_pixel_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_rst_pix_sync <= 2'b00;
        else
            S_rst_pix_sync <= {S_rst_pix_sync[0], 1'b1};
    end
    wire S_rst_pixel = ~S_rst_pix_sync[1];

    // serial domain (125 MHz)
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
    // internal Sdram_PLL (100 MHz) is comfortably locked too; the release is
    // synchronised inside the 100 MHz domain.
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

        // FIFO write side 1 : image page writer (one row per WR1_LOAD)
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

    //-------------------------------------------------------------------------
    // AXIS video source + page control (25 MHz)
    //-------------------------------------------------------------------------
    wire        S_axis_user, S_axis_valid, S_axis_last;
    wire [23:0] S_axis_data;
    wire        S_axis_ready;

    wire        S_ready_tog, S_ready_page, S_disp_page;
    wire        S_key_next_tog, S_key_prev_tog;
    wire        S_st_has_img;
    wire        S_paused;
    wire        S_ready_pulse;

    m4_video_src720 #(
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
        .O_disp_page    (S_disp_page),
        .O_key_next_tog (S_key_next_tog),
        .O_key_prev_tog (S_key_prev_tog),
        .O_paused       (S_paused),
        .O_ready_pulse  (S_ready_pulse),
        .O_video_user   (S_axis_user),
        .O_video_valid  (S_axis_valid),
        .O_video_last   (S_axis_last),
        .O_video_data   (S_axis_data)
    );

    //-------------------------------------------------------------------------
    // page writer (100 MHz)
    //-------------------------------------------------------------------------
    wire        S_pix_valid, S_pix_ready;
    wire [23:0] S_pix_data;

    wire        S_wr_start;
    wire        S_wr_page, S_wr_bup, S_wr_flush, S_wr_done, S_wr_busy;

    m4_page_wr #(
        .HACTIVE (PAGE_W),          // frame buffer geometry, not the canvas
        .VACTIVE (PAGE_H)
    ) u_wr (
        .I_clk         (S_sdram_clk),
        .I_rst         (S_rst_sdram),
        .I_start       (S_wr_start),
        .I_page        (S_wr_page),
        .I_bottom_up   (S_wr_bup),
        .I_pix_data    (S_pix_data),
        .I_pix_valid   (S_pix_valid),
        .O_pix_ready   (S_pix_ready),
        .I_flush       (S_wr_flush),
        .I_fifo_full   (S_wr_full),
        .O_wr          (S_wr),
        .O_wr_data     (S_wr_data),
        .O_load        (S_wr_load),
        .O_addr        (S_wr_addr),
        .O_busy        (S_wr_busy),
        .O_done        (S_wr_done)
    );

    //-------------------------------------------------------------------------
    // SD SPI engine + sector buffer (100 MHz)
    //-------------------------------------------------------------------------
    wire        S_sd_init, S_sd_start, S_sd_busy, S_sd_done, S_sd_err;
    wire [31:0] S_sd_lba;
    wire [8:0]  S_buf_addr;
    wire [7:0]  S_buf_dout;

    m4_sd_sec u_sd (
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
    // byte sequence reader (FAT32 structures) / pixel pump (BMP payload)
    //-------------------------------------------------------------------------
    wire        S_bs_start, S_bs_done;
    wire [8:0]  S_bs_off, S_bs_addr;
    wire [5:0]  S_bs_cnt;
    wire [271:0] S_bs_val;

    wire        S_pp_start, S_pp_done;
    wire [8:0]  S_pp_off, S_pp_addr;
    wire [9:0]  S_pp_cnt;
    wire        S_pp_pv;
    wire [23:0] S_pp_pd;

    wire        S_buf_sel;

    assign S_buf_addr = S_buf_sel ? S_pp_addr : S_bs_addr;

    m4_byte_seq u_bs (
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

    m4_pix_pump u_pp (
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

    //-------------------------------------------------------------------------
    // FAT32-lite + BMP control FSM (100 MHz)
    //-------------------------------------------------------------------------
    wire S_fat_mounted;
    wire [2:0] S_fat_err;
    wire [4:0] S_fat_count, S_fat_index;
    wire [5:0] S_fat_st;
    wire [7:0] S_fat_ck;

    m4_fat_bmp u_fat (
        .I_clk         (S_sdram_clk),
        .I_rst         (S_rst_sdram),
        .I_sdram_ready (S_sdram_ready),

        .O_sd_init     (S_sd_init),
        .O_sd_start    (S_sd_start),
        .O_sd_lba      (S_sd_lba),
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

        .O_wr_start    (S_wr_start),
        .O_wr_page     (S_wr_page),
        .O_wr_bottom_up(S_wr_bup),
        .O_wr_flush    (S_wr_flush),
        .I_wr_done     (S_wr_done),

        .I_disp_page   (S_disp_page),
        .O_ready_tog   (S_ready_tog),
        .O_ready_page  (S_ready_page),

        .I_key_next_tog(S_key_next_tog),
        .I_key_prev_tog(S_key_prev_tog),

        .O_mounted     (S_fat_mounted),
        .O_err         (S_fat_err),
        .O_count       (S_fat_count),
        .O_index       (S_fat_index),
        .O_buf_sel     (S_buf_sel),
        .O_dbg_st      (S_fat_st),
        .O_dbg_ck      (S_fat_ck)
    );

    //-------------------------------------------------------------------------
    // 7 segment display : vendor HEX8 (1 kHz digit scan + BCD decode) feeding
    // the vendor HC595_Driver (16 bit shift chain for the 2 x 74HC595).
    // This pair is the proven code from the vendor board example; our own
    // scan/shift implementation never lit the display on the bench.
    //   digits 7..4 : number of indexed images
    //   digits 3..0 : 1 based index of the picture on screen
    //   "E<n>"      : error code n
    //   HEX8 mode   : lights the DP of the two end digits while paused
    //-------------------------------------------------------------------------
    wire [31:0] S_hex_data;
    wire [7:0]  S_hex_sw;
    wire        S_hex_mode;
    wire [7:0]  S_hex_seg, S_hex_sel;

    m4_hex_status u_hex_status (
        .I_clk       (clk),                 // 50 MHz display domain
        .I_rst       (~S_rst_n_async),
        .I_mounted   (S_fat_mounted),
        .I_err       (S_fat_err),
        .I_count     (S_fat_count),
        .I_index     (S_fat_index),
        .I_busy      (S_wr_busy),
        .I_paused    (S_paused),
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
    // debug UART dumper (CH340E on the baseboard, P2, 115200 8N1)
    //   records the first 8 byte_seq reads (offset, count, FSM state, payload)
    //   and prints them once, 0.5 s after reset at the latest.  See
    //   m4_dbg_uart.v for the line format.
    //-------------------------------------------------------------------------
    wire S_dbg_tx;

    m4_dbg_uart u_dbg (
        .I_clk     (S_sdram_clk),
        .I_rst     (S_rst_sdram),
        .I_bs_done (S_bs_done),
        .I_off     (S_bs_off),
        .I_cnt     (S_bs_cnt),
        .I_st      (S_fat_st),
        .I_val     (S_bs_val),
        .I_live_st (S_fat_st),
        .I_live_err(S_fat_err),
        .I_live_ck (S_fat_ck),
        .O_uart_tx (S_dbg_tx)
    );

    // I2C scanner debug build: its ASCII report replaces the FAT dumper
    wire S_scan_busy, S_scan_done, S_scan_any, S_scan_codec, S_scan_uart;

    assign uart_tx = (DEBUG_AUDIO == 2) ? S_scan_uart : S_dbg_tx;

    assign S_st_has_img = (S_fat_count != 5'd0);

    //=========================================================================
    // M4 audio : third PLL (12.288 MHz) + WM8960 I2C init + I2S + 1 kHz tone
    //=========================================================================
    wire S_mclk;            // 12.288136 MHz
    wire S_audio_lock;

    pll_m4_audio u_pll_audio (
        .refclk  (clk),
        .reset   (1'b0),
        .extlock (S_audio_lock),
        .clk0_out(S_mclk)
    );

    // audio subsystem reset : asynchronous assert (KEY2 or either PLL unlocked),
    // synchronous release in each of the two domains that use it.  The M3 chain
    // above is untouched, so a dead audio PLL cannot blank the HDMI output.
    wire S_rst_n_audio = S_rst_n_async & S_audio_lock;

    // 50 MHz domain (I2C)
    reg [1:0] S_rst_i2c_sync;
    always @(posedge clk or negedge S_rst_n_audio) begin
        if (!S_rst_n_audio)
            S_rst_i2c_sync <= 2'b00;
        else
            S_rst_i2c_sync <= {S_rst_i2c_sync[0], 1'b1};
    end
    wire S_rst_i2c = ~S_rst_i2c_sync[1];

    // MCLK domain (tone + I2S)
    reg [1:0] S_rst_mclk_sync;
    always @(posedge S_mclk or negedge S_rst_n_audio) begin
        if (!S_rst_n_audio)
            S_rst_mclk_sync <= 2'b00;
        else
            S_rst_mclk_sync <= {S_rst_mclk_sync[0], 1'b1};
    end
    wire S_rst_mclk = ~S_rst_mclk_sync[1];

    //-------------------------------------------------------------------------
    // codec I2C path : either the ES8388/WM8960 initialiser (normal builds) or
    // the I2C bus scanner (DEBUG_AUDIO == 2 bring-up build)
    //-------------------------------------------------------------------------
    wire       S_init_busy, S_init_done, S_init_ok, S_init_nack;
    wire [4:0] S_init_idx;
    wire       S_scl_o, S_sda_o, S_sda_oe, S_sda_i;

    generate
    if (DEBUG_AUDIO == 2) begin : g_i2c_scan
        m4_i2c_scan #(
            .CLK_HZ (50_000_000),
            .BAUD   (115200)
        ) u_i2c_scan (
            .I_clk       (clk),
            .I_rst       (S_rst_50),
            .O_scl       (S_scl_o),
            .O_sda_o     (S_sda_o),
            .O_sda_oe    (S_sda_oe),
            .I_sda_i     (S_sda_i),
            .O_uart_tx   (S_scan_uart),
            .O_busy      (S_scan_busy),
            .O_done      (S_scan_done),
            .O_any_ack   (S_scan_any),
            .O_codec_ack (S_scan_codec)
        );
        // the initialiser is not built, so its status is constant
        assign S_init_busy = 1'b0;
        assign S_init_done = 1'b0;
        assign S_init_ok   = 1'b0;
        assign S_init_nack = 1'b0;
        assign S_init_idx  = 5'd0;
    end else begin : g_i2c_init
        m4_i2s_init_dev u_i2c_init (
            .I_clk     (clk),
            .I_rst     (S_rst_i2c),
            .O_busy    (S_init_busy),
            .O_done    (S_init_done),
            .O_ok      (S_init_ok),
            .O_nack_err(S_init_nack),
            .O_index   (S_init_idx),
            .O_scl     (S_scl_o),
            .O_sda_o   (S_sda_o),
            .O_sda_oe  (S_sda_oe),
            .I_sda_i   (S_sda_i)
        );
        assign S_scan_busy  = 1'b0;
        assign S_scan_done  = 1'b0;
        assign S_scan_any   = 1'b0;
        assign S_scan_codec = 1'b0;
        assign S_scan_uart  = 1'b0;
    end
    endgenerate

    // shared I2C bus : push-pull SCL, tri-state SDA (same idea as the vendor
    // src/function_pin.v, but M4 owns the bus for good - the EEPROM and the RTC
    // are never addressed).  After the last STOP both lines are released high.
    assign I2C_SCL = S_scl_o;
    assign I2C_SDA = S_sda_oe ? S_sda_o : 1'bz;
    assign S_sda_i = I2C_SDA;

    //-------------------------------------------------------------------------
    // init_ok -> MCLK domain (2FF); the tone only runs when every register ACKed
    //-------------------------------------------------------------------------
    reg [1:0] S_ok_sync;
    always @(posedge S_mclk or negedge S_rst_n_audio) begin
        if (!S_rst_n_audio)
            S_ok_sync <= 2'b00;
        else
            S_ok_sync <= {S_ok_sync[0], S_init_ok};
    end
    wire S_tone_en = S_ok_sync[1];

    //-------------------------------------------------------------------------
    // 1 kHz sine, 48 kHz sample rate, 16 bit, -6.02 dBFS (design doc §8)
    //-------------------------------------------------------------------------
    wire [15:0] S_tone_sample;
    wire        S_tone_tick;

    m4_sine_tone u_tone (
        .I_clk   (S_mclk),
        .I_rst   (S_rst_mclk),
        .I_tick  (S_tone_tick),
        .I_en    (S_tone_en),
        .O_sample(S_tone_sample)
    );

    //-------------------------------------------------------------------------
    // I2S transmitter : FPGA is master, WM8960 is slave
    //   BCLK = MCLK/4 = 3.072034 MHz, LRCK = BCLK/64 = 48.0005 kHz
    //-------------------------------------------------------------------------
    m4_i2s_tx u_i2s_tx (
        .I_clk   (S_mclk),
        .I_rst   (S_rst_mclk),
        .I_en    (S_tone_en),
        .I_sample(S_tone_sample),
        .O_tick  (S_tone_tick),
        .O_mclk  (I2S_MCLK),
        .O_bclk  (I2S_BCLK),
        .O_lrck  (I2S_DACLRC),
        .O_dacdat(I2S_DACDAT)
    );

    //-------------------------------------------------------------------------
    // status LEDs (100 MHz domain, no CDC needed for a status indication)
    //   led0 : card mounted / FAT32 BPB accepted
    //   led1 : page writer busy (loading)
    //   led2 : last operation reported an error
    //   led3 : page currently on screen (0 = A, 1 = B)
    //-------------------------------------------------------------------------
    reg [3:0] S_led;
    always @(posedge S_sdram_clk) begin
        if (S_rst_sdram)
            S_led <= 4'b0000;
        else
            S_led <= {S_disp_page, (S_fat_err != 3'd0), S_wr_busy, S_fat_mounted};
    end
    assign led = (DEBUG_AUDIO == 2) ? {~S_scan_done, ~S_scan_any, ~S_scan_codec, ~S_scan_busy}
               : DEBUG_AUDIO        ? {~S_audio_lock, ~S_init_ok, ~S_init_nack, ~S_init_busy}
               : DEBUG_ERR          ? {1'b1, ~S_fat_err}
               :                      S_led;

    //-------------------------------------------------------------------------
    // HDMI 1.4b transmitter core (encrypted IP, vendor supplied)
    //-------------------------------------------------------------------------
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
        .I_audio_valid      (1'b0),
        .I_audio_left_data  (24'd0),
        .I_audio_right_data (24'd0),
        .I_acr_valid        (1'b0),
        .I_acr_cts          (20'd0),
        .I_acr_n            (20'd0),
        .O_video_locked     (S_video_locked_unused),
        .O_ddc_scl          (S_ddc_scl_unused),
        .IO_ddc_sda         (S_ddc_sda_unused),
        .O_ch0_tmds_data    (S_ch0_tmds_data),
        .O_ch1_tmds_data    (S_ch1_tmds_data),
        .O_ch2_tmds_data    (S_ch2_tmds_data),
        .O_clk_tmds_data    (S_clk_tmds_data)
    );

    //-------------------------------------------------------------------------
    // TMDS serialisers (4 lanes, ODDR based 10:1)
    //-------------------------------------------------------------------------
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

