//=============================================================================
//  m5_fat_bmp.v
//  FAT32-lite (read only) + BMP header check + pixel stream, 100 MHz domain.
//
//  Supported subset (documented in docs/research/m2-report.md):
//    * MBR partitioned card (first partition of type 01/04/06/0B/0C/0E)
//      or a "super floppy" (BPB at LBA 0, no partition table);
//    * FAT32 only: BPB_BytsPerSec = 512, BPB_FATSz16 = 0, BPB_FATSz32 != 0,
//      BPB_RootClus >= 2, SecPerClus a power of two (1..128);
//    * ROOT DIRECTORY only, and only the first MAXF (16) *.BMP entries of it;
//      no sub directories, no long file names (LFN entries are skipped);
//    * the list is kept in DIRECTORY order; "next / previous image" is
//      answered by a serial min/max scan on the 4 digit number of
//      "IMGnnnn.BMP" (names that do not match get key 0xFFFF and therefore
//      sort last).  See the file-list comment below for why there is no
//      sorting network;
//    * BMP: 'BM', biSize = 40, 640x480 (biHeight +480 bottom-up or -480
//      top-down), 24 bpp, biCompression = 0 (low half).  bfOffBits may be
//      anything above 54: the palette/prefix is skipped sector by sector.
//
//  Cluster -> sector mapping
//      cluster N (N >= 2) first sector = DATA_LBA + ((N-2) << log2(SecPerClus))
//      DATA_LBA = PART_LBA + RsvdSecCnt + NumFATs * FATSz32
//      FAT_LBA  = PART_LBA + RsvdSecCnt
//      FAT entry of cluster N : sector FAT_LBA + (N >> 7), byte (N & 127) * 4
//
//  Every sector access is serialised through the single 512 byte buffer:
//      issue -> wait -> consume.
//  The "issue" steps are separate states (S_RD1 / S_BS1 / S_WR1) because the
//  helper modules latch their inputs on the clock edge of the start pulse, so
//  all parameters are driven one clock *before* the pulse.
//
//  Time: ~190 us per sector on SPI (400 kHz init, then 25 MHz),
//  1800 data sectors + ~225 FAT sectors  ->  ~0.39 s per image, while the
//  previous page keeps being displayed.
//=============================================================================
`timescale 1ns / 10ps

module m5_fat_bmp #(
    parameter MAXF = 16
) (
    input  wire         I_clk,
    input  wire         I_rst,              // active high, 100 MHz domain
    input  wire         I_sdram_ready,

    // ---- sector engine -----------------------------------------------------
    output reg          O_sd_init,          // 1 = card init command
    output reg          O_sd_start,
    output reg  [31:0]  O_sd_lba,
    input  wire         I_sd_busy,
    input  wire         I_sd_done,
    input  wire         I_sd_err,

    // ---- byte sequence reader (sector buffer -> register) -------------------
    output reg          O_bs_start,
    output reg  [8:0]   O_bs_off,
    output reg  [5:0]   O_bs_cnt,
    input  wire         I_bs_done,
    input  wire [271:0] I_bs_val,

    // ---- pixel pump (sector buffer -> pixels) ------------------------------
    output reg          O_pp_start,
    output reg  [8:0]   O_pp_off,
    output reg  [9:0]   O_pp_cnt,
    input  wire         I_pp_done,
    input  wire         I_pp_pix_valid,
    input  wire [23:0]  I_pp_pix_data,

    // ---- pixel stream to the page writer -----------------------------------
    output wire         O_pix_valid,
    output wire [23:0]  O_pix_data,
    input  wire         I_pix_ready,

    // ---- page writer -------------------------------------------------------
    output reg          O_wr_start,
    output reg          O_wr_page,
    output reg          O_wr_bottom_up,
    output reg          O_wr_flush,
    input  wire         I_wr_done,

    // ---- display side (25 MHz domain) --------------------------------------
    input  wire         I_disp_page,
    output reg          O_ready_tog,
    output reg          O_ready_page,

    // ---- keys (toggles from the 25 MHz debouncer) --------------------------
    input  wire         I_key_next_tog,
    input  wire         I_key_prev_tog,

    // ---- status ------------------------------------------------------------
    output reg          O_mounted,
    output reg  [2:0]   O_err,
    output wire [4:0]   O_count,
    output reg  [4:0]   O_index,
    output wire         O_buf_sel,     // 1 = the pixel pump owns the buffer port
    output wire [5:0]   O_dbg_st,      // debug: current FSM state (UART dumper)
    output wire [7:0]   O_dbg_ck       // debug: BPB checks {spc,rsvd,nfat,root,fatsz32,bps}
);

    localparam [31:0] PIX_BYTES = 32'd921600;       // 640*480*3 = 0x0E1000
    localparam [27:0] EOC       = 28'h0FFFFFF8;

    //-------------------------------------------------------------------------
    // state encoding
    //-------------------------------------------------------------------------
    localparam S_POR    = 6'd0;
    localparam S_BOOT   = 6'd1;      // 10 ms power-on delay, raises O_sd_init
    localparam S_INIT1  = 6'd2;      // init start pulse
    localparam S_INIT_W = 6'd3;
    localparam S_MBR    = 6'd4;      // read LBA 0
    localparam S_RD1    = 6'd5;      // sector read start pulse
    localparam S_RD_W   = 6'd6;
    localparam S_BS1    = 6'd7;      // byte sequence start pulse
    localparam S_BS_W   = 6'd8;
    localparam S_WR1    = 6'd9;      // page writer start pulse
    localparam S_MBR_W  = 6'd10;
    localparam S_FS     = 6'd11;     // byte_seq(82,8) "FAT32"
    localparam S_FS_C   = 6'd12;
    localparam S_PENT_C = 6'd13;     // partition entry check
    localparam S_BPB    = 6'd14;     // read partition boot sector
    localparam S_BPB_W  = 6'd15;
    localparam S_BF1_C  = 6'd16;
    localparam S_BF2_C  = 6'd17;
    localparam S_DIR    = 6'd18;     // read directory sector
    localparam S_DIR_W  = 6'd19;
    localparam S_ENT    = 6'd20;     // byte_seq(ent*32,32)
    localparam S_ENT_C  = 6'd21;
    localparam S_DIRN   = 6'd22;
    localparam S_DFAT   = 6'd23;     // FAT sector of the directory chain
    localparam S_DFAT_C = 6'd24;
    localparam S_DFAT_V = 6'd25;
    localparam S_SEL    = 6'd26;
    localparam S_SCAN_W = 6'd27;     // wait for the list scan
    localparam S_HDR    = 6'd28;     // read the file's first sector
    localparam S_HDR_W  = 6'd29;
    localparam S_HF_C   = 6'd30;
    localparam S_DSEC   = 6'd31;     // start of a data sector
    localparam S_DSEC_W = 6'd32;
    localparam S_PP_W   = 6'd33;
    localparam S_ADV    = 6'd34;
    localparam S_CFAT   = 6'd35;     // FAT sector of the file chain
    localparam S_CFAT_C = 6'd36;
    localparam S_CFAT_V = 6'd37;
    localparam S_DEND   = 6'd38;
    localparam S_SW0    = 6'd39;
    localparam S_SW1    = 6'd40;
    localparam S_SHOW   = 6'd41;
    localparam S_KEY    = 6'd42;
    localparam S_PAT0   = 6'd43;
    localparam S_PAT    = 6'd44;
    localparam S_PAT_E  = 6'd45;
    localparam S_ERR    = 6'd46;
localparam S_SIG_C  = 6'd47;    // DEBUG: MBR signature 0x55AA check

    //-------------------------------------------------------------------------
    // registers
    //-------------------------------------------------------------------------
    reg [5:0]  S_st;
    reg [5:0]  S_rd_ret, S_bs_ret, S_wr_ret;

    reg [31:0] S_part_lba, S_fat_lba, S_data_lba, S_fatsz, S_root_clus;

    // BPB read #1 fields, latched in S_BF1_C (B[] only holds one read)
    reg [15:0] Q_bps;
    reg [7:0]  Q_spc;
    reg [15:0] Q_rsvd;
    reg [7:0]  Q_nfat;
    wire Q_spc_ok = (Q_spc != 8'd0) &&
                    ((Q_spc & (Q_spc - 8'd1)) == 8'd0) &&
                    (Q_spc <= 8'd128);
    reg [7:0]  S_spc;
    reg [3:0]  S_log2spc;

    reg [31:0] S_clus;          // cluster being walked (directory or file)
    reg [7:0]  S_sec;           // sector index inside S_clus
    reg [3:0]  S_pent;          // partition entry index 0..3
    reg [3:0]  S_ent;           // directory entry index 0..15

    reg [31:0] S_skip;          // bytes still to skip before the pixel data
    reg [31:0] S_pixleft;       // pixel bytes still to read
    reg        S_inload;        // page writer is filling a BMP page
    reg        S_patdone;       // test pattern has already been shown once
    reg [19:0] S_wd;            // boot delay
    reg [4:0]  S_att;           // per-file attempt counter
    reg [1:0]  S_dly;           // ready handshake delay
    reg [23:0] S_show_to;       // swap wait timeout
    reg        S_cnt_clr;       // one cycle: clear the file list
    reg [15:0] S_cur_key;       // key of the image on screen
    reg [31:0] S_cur_size;      // its directory entry size (read at scan time)
    reg [15:0] C_ref;           // list scan: reference key (main FSM driven)
    reg        C_mode;          // list scan: 0 = next, 1 = previous

    // file list (directory order)
    reg [15:0] S_fkey  [0:MAXF-1];
    reg [31:0] S_fclus [0:MAXF-1];
    reg [31:0] S_fsize [0:MAXF-1];

    // fallback pattern counters
    reg [9:0]  S_px;
    reg [8:0]  S_py;

    integer   ii;

    //-------------------------------------------------------------------------
    // clock domain crossings (from the 25 MHz pixel domain)
    //-------------------------------------------------------------------------
    reg [2:0]  S_kn_s, S_kp_s;
    reg [1:0]  S_dp_s;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_kn_s <= 3'b000;
            S_kp_s <= 3'b000;
            S_dp_s <= 2'b00;
        end else begin
            S_kn_s <= {S_kn_s[1:0], I_key_next_tog};
            S_kp_s <= {S_kp_s[1:0], I_key_prev_tog};
            S_dp_s <= {S_dp_s[0],   I_disp_page};
        end
    end

    wire S_key_next  = S_kn_s[1] ^ S_kn_s[2];
    wire S_key_prev  = S_kp_s[1] ^ S_kp_s[2];
    wire S_disp_sync = S_dp_s[1];

    //-------------------------------------------------------------------------
    // pending step requests.
    //   The FAT FSM ignores key events while it is loading a page (~1.5 s at
    //   5 MHz SPI), so a press during a load used to be lost -- on the bench
    //   that looked like "S0/S1 work only now and then".  The toggle is now
    //   counted here (saturating at 3) and consumed one per completed load.
    //-------------------------------------------------------------------------
    reg [1:0] Q_pn, Q_pp;
    reg       Q_pn_use, Q_pp_use;

    always @(posedge I_clk) begin
        if (I_rst) begin
            Q_pn <= 2'd0;
            Q_pp <= 2'd0;
        end else begin
            if (S_key_next && (Q_pn != 2'd3)) Q_pn <= Q_pn + 2'd1;
            else if (Q_pn_use)                Q_pn <= Q_pn - 2'd1;

            if (S_key_prev && (Q_pp != 2'd3)) Q_pp <= Q_pp + 2'd1;
            else if (Q_pp_use)                Q_pp <= Q_pp - 2'd1;
        end
    end

    //-------------------------------------------------------------------------
    // sector address arithmetic
    //-------------------------------------------------------------------------
    wire [31:0] S_clus_off = (S_clus - 32'd2) << S_log2spc;
    wire [31:0] S_dir_sec  = S_data_lba + S_clus_off + {24'd0, S_sec};

    //-------------------------------------------------------------------------
    // byte slices of the last byte sequence read
    //     I_bs_val[8*i +: 8] = byte (I_off + i) of the sector
    //-------------------------------------------------------------------------
    wire [7:0] B [0:33];
    genvar gj;
    generate
        for (gj = 0; gj < 34; gj = gj + 1) begin : G_b
            assign B[gj] = I_bs_val[8*gj + 7 : 8*gj];
        end
    endgenerate

    // BPB fields, read #1 (off 11, 7 bytes)
    wire [15:0] W_bps     = {B[1],  B[0]};                    // BytsPerSec  11,12
    wire [7:0]  W_spc_new = B[2];                              // SecPerClus  13
    wire [15:0] W_rsvd    = {B[4],  B[3]};                     // RsvdSecCnt  14,15
    wire [7:0]  W_nfat    = B[5];                              // NumFATs     16

    // BPB fields, read #2 (off 32, 16 bytes): TotSec32, FATSz32, ExtFlags,
    // FSVer, RootClus.  FATSz16 lives at offset 22 and is NOT part of this
    // read; an earlier version checked "FATSz16 == 0" against B[1:0] here,
    // which is really TotSec32[15:0], so every card bigger than 32768 sectors
    // (i.e. every real card) failed the BPB sanity check with error 2.
    // FAT32 is still detected reliably: FATSz32 != 0 while TotSec32 != 0 and
    // RootClus >= 2 is exactly what a FAT32 BPB looks like.
    wire [15:0] W_totsec32_lo = {B[1], B[0]};                  // TotSec32    32,33
    wire [31:0] W_fatsz32 = {B[7],  B[6],  B[5],  B[4]};       // FATSz32    36..39
    wire [31:0] W_rootc   = {B[15], B[14], B[13], B[12]};      // RootClus   44..47

    // directory entry (off ent*32, 32 bytes)
    wire [31:0] W_e_clus  = {B[21], B[20], B[27], B[26]};      // 20,21 + 26,27
    wire [31:0] W_e_size  = {B[31], B[30], B[29], B[28]};      // 28..31

    wire W_e_end  = (B[0] == 8'h00);
    wire W_e_del  = (B[0] == 8'hE5);
    wire W_e_lfn  = (B[11] == 8'h0F);
    wire W_e_vol  = B[11][3];
    wire W_e_dir  = B[11][4];
    wire W_e_dot  = (B[0] == 8'h2E);

    wire W_e_bmp  = ((B[8]  == 8'h42) || (B[8]  == 8'h62)) &&
                    ((B[9]  == 8'h4D) || (B[9]  == 8'h6D)) &&
                    ((B[10] == 8'h50) || (B[10] == 8'h70));

    // "IMGnnnn" : n^0x30 <= 9 is a single comparison per digit
    wire [7:0] W_d3 = B[3] ^ 8'h30;
    wire [7:0] W_d4 = B[4] ^ 8'h30;
    wire [7:0] W_d5 = B[5] ^ 8'h30;
    wire [7:0] W_d6 = B[6] ^ 8'h30;

    wire W_e_num  = (B[0] == 8'h49) && (B[1] == 8'h4D) && (B[2] == 8'h47) &&
                    (W_d3 <= 8'd9) && (W_d4 <= 8'd9) &&
                    (W_d5 <= 8'd9) && (W_d6 <= 8'd9);

    wire [15:0] W_e_key = W_e_num ? {W_d3[3:0], W_d4[3:0], W_d5[3:0], W_d6[3:0]}
                                  : 16'hFFFF;

    wire W_e_add = W_e_bmp && !W_e_lfn && !W_e_vol && !W_e_dir &&
                   !W_e_dot && !W_e_del && !W_e_end;

    // BMP header (off 0, 34 bytes)
    wire [31:0] W_bf_off  = {B[13], B[12], B[11], B[10]};
    wire [31:0] W_bi_size = {B[17], B[16], B[15], B[14]};
    wire [31:0] W_bi_w    = {B[21], B[20], B[19], B[18]};
    wire [31:0] W_bi_h    = {B[25], B[24], B[23], B[22]};
    wire [15:0] W_bi_bpp  = {B[29], B[28]};
    wire [15:0] W_bi_cmp  = {B[31], B[30]};

    wire W_hdr_ok = (B[0] == 8'h42) && (B[1] == 8'h4D) &&
                    (W_bi_size == 32'd40) &&
                    (W_bi_w    == 32'd640) &&
                   ((W_bi_h    == 32'd480) || (W_bi_h == 32'hFFFFFE20)) &&
                    (W_bi_bpp  == 16'd24) &&
                    (W_bi_cmp  == 16'd0);

    //-------------------------------------------------------------------------
    // SecPerClus -> log2 (must be a power of two, 1..128)
    //-------------------------------------------------------------------------
    function [3:0] LOG2SPC;
        input [7:0] v;
        begin
            if      (v >= 8'd128) LOG2SPC = 4'd7;
            else if (v >= 8'd64)  LOG2SPC = 4'd6;
            else if (v >= 8'd32)  LOG2SPC = 4'd5;
            else if (v >= 8'd16)  LOG2SPC = 4'd4;
            else if (v >= 8'd8)   LOG2SPC = 4'd3;
            else if (v >= 8'd4)   LOG2SPC = 4'd2;
            else if (v >= 8'd2)   LOG2SPC = 4'd1;
            else                  LOG2SPC = 4'd0;
        end
    endfunction

    wire W_spc_ok = (W_spc_new != 8'd0) &&
                    ((W_spc_new & (W_spc_new - 8'd1)) == 8'd0) &&
                    (W_spc_new <= 8'd128);

    //-------------------------------------------------------------------------
    // file list : APPEND order (directory order), no sorting network.
    //
    //  A 16 entry combinational insertion sort was tried first and produced a
    //  14.8 ns path (sector byte -> digit check -> key mux -> 16 parallel
    //  comparators -> priority encode -> 16:1 shift into the array), WNS
    //  -5.07 ns at 100 MHz.  The list is therefore kept in directory order and
    //  "next / previous image" is answered by a serial min/max scan
    //  (2 clocks per entry, once per key press):
    //
    //      next : smallest key > current key, else the smallest key
    //      prev : largest  key < current key, else the largest key
    //      boot : smallest key              (ref = 0xFFFF -> falls back)
    //
    //  The scan read is registered, so the array may be mapped to a RAM.
    //-------------------------------------------------------------------------
    reg  [1:0]  C_st;
    reg  [4:0]  C_i;
    reg         C_go;           // one cycle start pulse (driven by the FSM)
    reg         C_done;         // one cycle result pulse (read by the FSM)
    reg  [4:0]  C_idx;          // result: selected list index
    reg  [15:0] C_key;          // result: its key
    reg  [15:0] C_rd;           // registered array read

    reg         C_have_gt;
    reg  [15:0] C_gt;
    reg  [4:0]  C_gt_i;

    reg         C_have_all;
    reg  [15:0] C_all;
    reg  [4:0]  C_all_i;

    reg  [4:0]  S_count;

    // append request (driven by the main FSM, executed by the list block so
    // that the arrays and the counter always have exactly one driver)
    reg         S_app;
    reg  [15:0] S_app_key;
    reg  [31:0] S_app_clus;
    reg  [31:0] S_app_size;

    always @(posedge I_clk) begin
        if (I_rst || S_cnt_clr) begin
            C_st       <= 2'd0;
            C_i        <= 5'd0;
            C_done     <= 1'b0;
            C_idx      <= 5'd0;
            C_key      <= 16'hFFFF;
            C_rd       <= 16'hFFFF;
            C_have_gt  <= 1'b0;
            C_gt       <= 16'hFFFF;
            C_gt_i     <= 5'd0;
            C_have_all <= 1'b0;
            C_all      <= 16'hFFFF;
            C_all_i    <= 5'd0;
            S_count    <= 5'd0;
            for (ii = 0; ii < MAXF; ii = ii + 1) begin
                S_fkey[ii]  <= 16'hFFFF;
                S_fclus[ii] <= 32'd0;
                S_fsize[ii] <= 32'd0;
            end
        end else begin
            C_done <= 1'b0;

            if (S_app && (S_count < MAXF)) begin
                S_fkey[S_count]  <= S_app_key;
                S_fclus[S_count] <= S_app_clus;
                S_fsize[S_count] <= S_app_size;
                S_count          <= S_count + 5'd1;
            end

            case (C_st)
                // start a scan
                2'd0: begin
                    if (C_go) begin
                        C_i        <= 5'd0;
                        C_have_gt  <= 1'b0;
                        C_have_all <= 1'b0;
                        C_gt       <= (C_mode == 1'b0) ? 16'hFFFF : 16'h0000;
                        C_all      <= (C_mode == 1'b0) ? 16'hFFFF : 16'h0000;
                        C_st       <= 2'd1;
                    end
                end

                // read one entry (registered)
                2'd1: begin
                    C_rd <= S_fkey[C_i];
                    C_st <= 2'd2;
                end

                // keep the two best candidates
                2'd2: begin
                    if (C_mode == 1'b0) begin
                        if ((C_rd > C_ref) && (!C_have_gt || (C_rd < C_gt))) begin
                            C_gt      <= C_rd;
                            C_gt_i    <= C_i;
                            C_have_gt <= 1'b1;
                        end
                        if (!C_have_all || (C_rd < C_all)) begin
                            C_all      <= C_rd;
                            C_all_i    <= C_i;
                            C_have_all <= 1'b1;
                        end
                    end else begin
                        if ((C_rd < C_ref) && (!C_have_gt || (C_rd > C_gt))) begin
                            C_gt      <= C_rd;
                            C_gt_i    <= C_i;
                            C_have_gt <= 1'b1;
                        end
                        if (!C_have_all || (C_rd > C_all)) begin
                            C_all      <= C_rd;
                            C_all_i    <= C_i;
                            C_have_all <= 1'b1;
                        end
                    end

                    C_i <= C_i + 5'd1;
                    if (({1'b0, C_i} + 6'd1) >= {1'b0, S_count}) begin
                        C_idx  <= C_have_gt ? C_gt_i : C_all_i;
                        C_key  <= C_have_gt ? C_gt   : C_all;
                        C_done <= 1'b1;
                        C_st   <= 2'd0;
                    end else begin
                        C_st <= 2'd1;
                    end
                end

                default: C_st <= 2'd0;
            endcase
        end
    end

    assign O_count = S_count;

    //-------------------------------------------------------------------------
    // fallback test pattern: M1 gradient + green border, raster order
    //-------------------------------------------------------------------------
    wire [23:0] W_pat_col = (S_px < 10'd8 || S_px >= 10'd632 ||
                             S_py <  9'd8 || S_py >=  9'd472)
                            ? 24'h00FF00
                            : {S_px[9:2], S_py[8:1], 8'h40};

    assign O_buf_sel   = (S_st == S_DSEC_W) || (S_st == S_PP_W);
    assign O_dbg_st    = S_st;
    assign O_dbg_ck    = {2'b00, Q_spc_ok, (Q_rsvd != 16'd0),
                          (Q_nfat >= 8'd1) && (Q_nfat <= 8'd2),
                          (W_rootc >= 32'd2), (W_fatsz32 != 32'd0),
                          (Q_bps == 16'd512)};

    assign O_pix_valid = (S_st == S_PAT) ? 1'b1 : I_pp_pix_valid;
    assign O_pix_data  = (S_st == S_PAT) ? W_pat_col : I_pp_pix_data;

    //-------------------------------------------------------------------------
    // main state machine
    //-------------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st           <= S_POR;
            S_rd_ret       <= S_POR;
            S_bs_ret       <= S_POR;
            S_wr_ret       <= S_POR;
            S_part_lba     <= 32'd0;
            Q_bps          <= 16'd0;
            Q_spc          <= 8'd0;
            Q_rsvd         <= 16'd0;
            Q_nfat         <= 8'd0;
            S_fat_lba      <= 32'd0;
            S_data_lba     <= 32'd0;
            S_fatsz        <= 32'd0;
            S_root_clus    <= 32'd0;
            S_spc          <= 8'd8;
            S_log2spc      <= 4'd3;
            S_clus         <= 32'd0;
            S_sec          <= 8'd0;
            S_pent         <= 4'd0;
            S_ent          <= 4'd0;
            S_skip         <= 32'd0;
            S_pixleft      <= 32'd0;
            S_inload       <= 1'b0;
            S_patdone      <= 1'b0;
            S_wd           <= 20'd0;
            S_att          <= 5'd0;
            S_dly          <= 2'd0;
            S_show_to      <= 24'd0;
            S_cnt_clr      <= 1'b0;
            S_cur_key      <= 16'hFFFF;
            S_cur_size     <= 32'd0;
            S_px           <= 10'd0;
            S_py           <= 9'd0;
            C_go           <= 1'b0;
            S_app          <= 1'b0;
            S_app_key      <= 16'hFFFF;
            S_app_clus     <= 32'd0;
            S_app_size     <= 32'd0;
            O_sd_init      <= 1'b0;
            O_sd_start     <= 1'b0;
            O_sd_lba       <= 32'd0;
            O_bs_start     <= 1'b0;
            O_bs_off       <= 9'd0;
            O_bs_cnt       <= 6'd1;
            O_pp_start     <= 1'b0;
            O_pp_off       <= 9'd0;
            O_pp_cnt       <= 10'd1;
            O_wr_start     <= 1'b0;
            O_wr_page      <= 1'b0;
            O_wr_bottom_up <= 1'b0;
            O_wr_flush     <= 1'b0;
            O_ready_tog    <= 1'b0;
            O_ready_page   <= 1'b0;
            O_mounted      <= 1'b0;
            O_err          <= 3'd0;
            O_index        <= 5'd0;
        end else begin
            O_sd_start <= 1'b0;
            O_bs_start <= 1'b0;
            O_pp_start <= 1'b0;
            O_wr_start <= 1'b0;
            C_go       <= 1'b0;
            S_app      <= 1'b0;
            S_cnt_clr  <= 1'b0;
            Q_pn_use   <= 1'b0;
            Q_pp_use   <= 1'b0;

            case (S_st)

            //------------------------------------------------- boot / card init
            S_POR: begin
                O_err <= 3'd0;
                if (I_sdram_ready) begin
                    S_wd <= 20'd0;
                    S_st <= S_BOOT;
                end
            end

            S_BOOT: begin
                S_wd <= S_wd + 20'd1;
                if (S_wd == 20'hF423F) begin       // 1e6 clocks = 10 ms
                    O_sd_init <= 1'b1;
                    S_st      <= S_INIT1;
                end
            end

            S_INIT1: begin
                O_sd_start <= 1'b1;
                S_st       <= S_INIT_W;
            end

            S_INIT_W: begin
                if (I_sd_done) begin
                    O_sd_init <= 1'b0;
                    S_st      <= S_MBR;
                end else if (I_sd_err) begin
                    O_sd_init <= 1'b0;
                    O_err     <= 3'd1;
                    S_st      <= S_ERR;
                end
            end

            //------------------------------------------------- MBR / super floppy
            S_MBR: begin
                O_sd_lba <= 32'd0;
                S_rd_ret <= S_MBR_W;
                S_st     <= S_RD1;
            end

            S_RD1: begin
                O_sd_start <= 1'b1;
                S_st       <= S_RD_W;
            end

            S_RD_W: begin
                if (I_sd_done)     S_st <= S_rd_ret;
                else if (I_sd_err) S_st <= S_ERR;
            end

            S_BS1: begin
                O_bs_start <= 1'b1;
                S_st       <= S_BS_W;
            end

            S_BS_W: begin
                if (I_bs_done) S_st <= S_bs_ret;
            end

            S_WR1: begin
                O_wr_start <= 1'b1;
                S_st       <= S_wr_ret;
            end

            S_MBR_W: begin
                // DEBUG: first make sure the sector we read is really LBA 0 by
                // checking the 0x55 0xAA boot signature at offset 510.  A wrong
                // clock phase / buffer address shows up here as garbage.
                O_bs_off <= 9'd510;
                O_bs_cnt <= 6'd2;
                S_bs_ret <= S_SIG_C;
                S_st     <= S_BS1;
            end

            S_SIG_C: begin
                if ((B[0] == 8'h55) && (B[1] == 8'hAA)) begin
                    S_pent   <= 4'd0;
                    O_bs_off <= 9'd82;             // "FAT32" file system type
                    O_bs_cnt <= 6'd8;
                    S_bs_ret <= S_FS_C;
                    S_st     <= S_BS1;
                end else begin
                    O_err <= 3'd5;                 // DEBUG: MBR data not valid
                    S_st  <= S_ERR;
                end
            end

            S_FS_C: begin
                if ((B[0] == 8'h46) && (B[1] == 8'h41) && (B[2] == 8'h54) &&
                    (B[3] == 8'h33) && (B[4] == 8'h32)) begin
                    S_part_lba <= 32'd0;           // super floppy, BPB already here
                    S_st       <= S_BPB_W;
                end else begin
                    O_bs_off <= 9'd446;            // partition entry 0
                    O_bs_cnt <= 6'd16;
                    S_bs_ret <= S_PENT_C;
                    S_st     <= S_BS1;
                end
            end

            S_PENT_C: begin
                if ((B[4] == 8'h01) || (B[4] == 8'h04) || (B[4] == 8'h06) ||
                    (B[4] == 8'h0B) || (B[4] == 8'h0C) || (B[4] == 8'h0E)) begin
                    S_part_lba <= {B[11], B[10], B[9], B[8]};
                    S_st       <= S_BPB;
                end else if (S_pent == 4'd3) begin
                    O_err <= 3'd7;                     // DEBUG: partition table rejected
                    S_st  <= S_ERR;
                end else begin
                    S_pent   <= S_pent + 4'd1;
                    O_bs_off <= 9'd446 + {1'b0, S_pent, 4'b0} + 9'd16;
                    O_bs_cnt <= 6'd16;
                    S_bs_ret <= S_PENT_C;
                    S_st     <= S_BS1;
                end
            end

            S_BPB: begin
                O_sd_lba <= S_part_lba;
                S_rd_ret <= S_BPB_W;
                S_st     <= S_RD1;
            end

            S_BPB_W: begin
                O_bs_off <= 9'd11;
                O_bs_cnt <= 6'd7;
                S_bs_ret <= S_BF1_C;
                S_st     <= S_BS1;
            end

            S_BF1_C: begin
                // B[] is a single 34 byte window over the sector buffer, so the
                // four fields of read #1 (offset 11) must be latched NOW: by
                // the time S_BF2_C runs, B[] only holds read #2 (offset 32).
                // Without this latch the BPB check compared BytsPerSec,
                // SecPerClus, RsvdSecCnt and NumFATs against the TotSec32 /
                // FATSz32 / RootClus bytes, so it failed on every real card
                // (error 2) -- confirmed with the debug UART: the check bitmap
                // read 0x16, i.e. only the three read#2 conditions passed.
                Q_bps    <= W_bps;
                Q_spc    <= W_spc_new;
                Q_rsvd   <= W_rsvd;
                Q_nfat   <= W_nfat;
                O_bs_off <= 9'd32;
                O_bs_cnt <= 6'd16;
                S_bs_ret <= S_BF2_C;
                S_st     <= S_BS1;
            end

            S_BF2_C: begin
                if ((Q_bps == 16'd512) &&
                    (W_fatsz32 != 32'd0) &&
                    (W_rootc >= 32'd2) &&
                    (Q_nfat >= 8'd1) && (Q_nfat <= 8'd2) &&
                    (Q_rsvd != 16'd0) && Q_spc_ok) begin
                    S_fatsz     <= W_fatsz32;
                    S_spc       <= Q_spc;
                    S_log2spc   <= LOG2SPC(Q_spc);
                    S_root_clus <= W_rootc;
                    S_fat_lba   <= S_part_lba + {16'd0, Q_rsvd};
                    S_data_lba  <= S_part_lba + {16'd0, Q_rsvd} +
                                   ((Q_nfat == 8'd2) ? {W_fatsz32[30:0], 1'b0}
                                                     : W_fatsz32);
                    S_clus      <= W_rootc;
                    S_sec       <= 8'd0;
                    S_ent       <= 4'd0;
                    S_cnt_clr   <= 1'b1;           // empty the file list
                    O_mounted   <= 1'b1;
                    S_st        <= S_DIR;
                end else begin
                    O_mounted <= 1'b0;
                    O_err     <= 3'd2;
                    S_st      <= S_ERR;
                end
            end

            //------------------------------------------------- root directory scan
            S_DIR: begin
                O_sd_lba <= S_dir_sec;
                S_rd_ret <= S_DIR_W;
                S_st     <= S_RD1;
            end

            S_DIR_W: begin
                S_ent    <= 4'd0;
                O_bs_off <= 9'd0;
                O_bs_cnt <= 6'd32;
                S_bs_ret <= S_ENT_C;
                S_st     <= S_BS1;
            end

            S_ENT: begin
                O_bs_off <= {S_ent, 5'b0};
                O_bs_cnt <= 6'd32;
                S_bs_ret <= S_ENT_C;
                S_st     <= S_BS1;
            end

            S_ENT_C: begin
                if (W_e_end || (S_count == MAXF)) begin
                    S_st <= S_SEL;
                end else begin
                    if (W_e_add) begin
                        S_app_key  <= W_e_key;         // append, no shifting
                        S_app_clus <= W_e_clus;
                        S_app_size <= W_e_size;
                        S_app      <= 1'b1;
                    end

                    if (S_ent == 4'd15) S_st <= S_DIRN;
                    else begin
                        S_ent <= S_ent + 4'd1;
                        S_st  <= S_ENT;
                    end
                end
            end

            S_DIRN: begin
                if (({1'b0, S_sec} + 9'd1) >= {1'b0, S_spc}) begin
                    S_st <= S_DFAT;
                end else begin
                    S_sec <= S_sec + 8'd1;
                    S_st  <= S_DIR;
                end
            end

            S_DFAT: begin
                O_sd_lba <= S_fat_lba + {25'd0, S_clus[31:7]};   // FAT sector = N/128 (was (N>>7)<<7)
                S_rd_ret <= S_DFAT_C;
                S_st     <= S_RD1;
            end

            S_DFAT_C: begin
                O_bs_off <= {S_clus[6:0], 2'b00};
                O_bs_cnt <= 6'd4;
                S_bs_ret <= S_DFAT_V;
                S_st     <= S_BS1;
            end

            S_DFAT_V: begin
                if (I_bs_val[27:0] >= EOC) begin
                    S_st <= S_SEL;                     // end of the directory chain
                end else begin
                    S_clus <= {4'd0, I_bs_val[27:0]};
                    S_sec  <= 8'd0;
                    S_st   <= S_DIR;
                end
            end

            //------------------------------------------------- select / header
            S_SEL: begin
                if (S_count == 5'd0) begin
                    O_index <= 5'd0;
                    S_st    <= S_PAT0;
                end else begin
                    S_att     <= 5'd0;
                    C_mode    <= 1'b0;                 // ascending
                    C_ref     <= 16'hFFFF;             // -> smallest key
                    C_go      <= 1'b1;
                    S_st      <= S_SCAN_W;
                end
            end

            S_SCAN_W: begin
                if (C_done) begin
                    O_index   <= C_idx;
                    S_cur_key  <= C_key;
                    S_cur_size <= S_fsize[C_idx];
                    S_clus     <= S_fclus[C_idx];
                    S_sec     <= 8'd0;
                    S_st      <= S_HDR;
                end
            end

            S_HDR: begin
                O_sd_lba <= S_dir_sec;                 // S_sec == 0 -> first sector
                S_rd_ret <= S_HDR_W;
                S_st     <= S_RD1;
            end

            S_HDR_W: begin
                O_bs_off <= 9'd0;
                O_bs_cnt <= 6'd34;
                S_bs_ret <= S_HF_C;
                S_st     <= S_BS1;
            end

            S_HF_C: begin
                if (W_hdr_ok) begin
                    S_skip         <= W_bf_off;
                    S_pixleft      <= PIX_BYTES;
                    S_sec          <= 8'd0;
                    // the directory entry's file size is only a sanity check:
                    // the pixel count is fixed by the 640x480x24 header
                    O_err          <= ((S_cur_size != 32'd0) &&
                                       (S_cur_size < (W_bf_off + PIX_BYTES)))
                                      ? 3'd6 : 3'd0;
                    O_wr_flush     <= 1'b0;
                    O_wr_page      <= ~S_disp_sync;
                    O_wr_bottom_up <= (W_bi_h == 32'd480);
                    S_inload       <= 1'b1;
                    S_wr_ret       <= S_DSEC;
                    S_st           <= S_WR1;
                end else begin
                    O_err <= 3'd4;                     // not a usable BMP
                    if ((S_att + 5'd1) < S_count) begin
                        S_att  <= S_att + 5'd1;
                        C_mode <= 1'b0;                // try the next image
                        C_ref  <= S_cur_key;
                        C_go   <= 1'b1;
                        S_st   <= S_SCAN_W;
                    end else begin
                        S_st <= S_PAT0;
                    end
                end
            end

            //------------------------------------------------- data sectors
            S_DSEC: begin
                if (S_pixleft == 32'd0) begin
                    S_st <= S_DEND;
                end else if (S_skip >= 32'd512) begin
                    S_skip <= S_skip - 32'd512;
                    S_st   <= S_ADV;                   // whole sector is palette
                end else begin
                    O_pp_off <= S_skip[8:0];
                    O_pp_cnt <= (S_pixleft < (32'd512 - S_skip))
                                ? S_pixleft[9:0]
                                : (10'd512 - S_skip[9:0]);
                    S_skip   <= 32'd0;
                    O_sd_lba <= S_dir_sec;
                    S_rd_ret <= S_DSEC_W;
                    S_st     <= S_RD1;
                end
            end

            S_DSEC_W: begin
                O_pp_start <= 1'b1;
                S_st       <= S_PP_W;
            end

            S_PP_W: begin
                if (I_pp_done) begin
                    // FIX: the counter of pixel bytes still to read was set at the
                    // BMP header (921600) and never decreased, so S_DSEC never saw
                    // pixleft==0: the loader kept pumping sectors until it had
                    // overrun the page, the writer finished and went idle, the
                    // pump then blocked on O_pix_ready and the FSM stayed in
                    // S_PP_W forever -> S_DEND / page swap never happened and the
                    // screen stayed black (no error code either).
                    S_pixleft <= S_pixleft - {22'd0, O_pp_cnt};
                    S_st      <= S_ADV;
                end
            end

            S_ADV: begin
                if (S_pixleft == 32'd0) begin
                    // the image is complete: do NOT walk to the next cluster,
                    // that would only cost one more FAT sector read (and would
                    // report a bogus "chain ends early" when the file happens
                    // to end exactly on a cluster boundary)
                    S_st <= S_DEND;
                end else if (({1'b0, S_sec} + 9'd1) >= {1'b0, S_spc}) begin
                    S_sec <= 8'd0;
                    S_st  <= S_CFAT;
                end else begin
                    S_sec <= S_sec + 8'd1;
                    S_st  <= S_DSEC;
                end
            end

            S_CFAT: begin
                O_sd_lba <= S_fat_lba + {25'd0, S_clus[31:7]};   // FAT sector = N/128 (was (N>>7)<<7)
                S_rd_ret <= S_CFAT_C;
                S_st     <= S_RD1;
            end

            S_CFAT_C: begin
                O_bs_off <= {S_clus[6:0], 2'b00};
                O_bs_cnt <= 6'd4;
                S_bs_ret <= S_CFAT_V;
                S_st     <= S_BS1;
            end

            S_CFAT_V: begin
                if (I_bs_val[27:0] >= EOC) begin
                    O_err <= 3'd5;                     // chain ends too early
                    S_st  <= S_DEND;
                end else begin
                    S_clus <= {4'd0, I_bs_val[27:0]};
                    S_st   <= S_DSEC;
                end
            end

            //------------------------------------------------- page finished
            S_DEND: begin
                O_wr_flush <= (S_pixleft != 32'd0);
                if (I_wr_done) begin
                    O_wr_flush <= 1'b0;
                    S_inload   <= 1'b0;
                    S_st       <= S_SW0;
                end
            end

            S_SW0: begin
                O_ready_page <= O_wr_page;
                S_dly        <= 2'd0;
                S_st         <= S_SW1;
            end

            S_SW1: begin
                S_dly <= S_dly + 2'd1;
                if (S_dly == 2'd3) begin
                    O_ready_tog <= ~O_ready_tog;
                    S_show_to   <= 24'd0;
                    S_st        <= S_SHOW;
                end
            end

            S_SHOW: begin
                S_show_to <= S_show_to + 24'd1;
                if (S_disp_sync == O_ready_page)   S_st <= S_KEY;
                else if (S_show_to == 24'hFFFFFF)  S_st <= S_KEY;
            end

            //------------------------------------------------- key handling
            S_KEY: begin
                Q_pn_use <= 1'b0;
                Q_pp_use <= 1'b0;

                if (S_count == 5'd0) begin
                    // no image list yet: any pending key retries the card init
                    if ((Q_pn != 2'd0) || (Q_pp != 2'd0)) begin
                        if (Q_pn != 2'd0) Q_pn_use <= 1'b1;
                        else              Q_pp_use <= 1'b1;
                        S_wd <= 20'd0;
                        S_st <= S_BOOT;                // card inserted later
                    end
                end else if (Q_pn != 2'd0) begin
                    Q_pn_use <= 1'b1;
                    S_att  <= 5'd0;
                    C_mode <= 1'b0;                    // ascending
                    C_ref  <= S_cur_key;
                    C_go   <= 1'b1;
                    S_st   <= S_SCAN_W;
                end else if (Q_pp != 2'd0) begin
                    Q_pp_use <= 1'b1;
                    S_att  <= 5'd0;
                    C_mode <= 1'b1;                    // descending
                    C_ref  <= S_cur_key;
                    C_go   <= 1'b1;
                    S_st   <= S_SCAN_W;
                end
            end

            //------------------------------------------------- M1 fallback pattern
            S_PAT0: begin
                O_index        <= 5'd0;
                // keep a more specific error (1 = card, 2 = FAT) if there was one
                if ((S_count == 5'd0) && (O_err == 3'd0)) O_err <= 3'd3;
                O_wr_flush     <= 1'b0;
                O_wr_page      <= ~S_disp_sync;
                O_wr_bottom_up <= 1'b0;
                S_px           <= 10'd0;
                S_py           <= 9'd0;
                S_inload       <= 1'b0;
                S_patdone      <= 1'b1;
                S_wr_ret       <= S_PAT;
                S_st           <= S_WR1;
            end

            S_PAT: begin
                if (I_pix_ready) begin
                    if (S_px == 10'd639) begin
                        S_px <= 10'd0;
                        if (S_py == 9'd479) S_st <= S_PAT_E;
                        else                S_py <= S_py + 9'd1;
                    end else begin
                        S_px <= S_px + 10'd1;
                    end
                end
            end

            S_PAT_E: begin
                if (I_wr_done) S_st <= S_SW0;
            end

            //------------------------------------------------- error handling
            S_ERR: begin
                if (S_inload) begin
                    S_pixleft <= 32'd1;                // force the black flush
                    S_st      <= S_DEND;
                end else if (!S_patdone) begin
                    S_st <= S_PAT0;
                end else begin
                    S_st <= S_KEY;
                end
            end

            default: S_st <= S_KEY;
            endcase
        end
    end

endmodule
