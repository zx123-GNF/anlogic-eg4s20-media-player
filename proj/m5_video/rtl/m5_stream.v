//=============================================================================
//  m5_stream.v  --  FAT32 file streamer for the M5 video player
//
//  Reads the file VID0.M5V from the root directory of the TF card and delivers
//  its bytes to the video decoder as a continuous byte stream.  This replaces
//  the M2/M4 "FAT32-lite + BMP" pair: the video player needs the file as one
//  long stream (7.4 MB), not as a series of 900 KB pictures, so the FSM walks
//  the cluster chain and hands out the file byte by byte.
//
//  Sector buffer
//  -------------
//  The vendor SD engine (sd_card_control) has a 512x8 RD_RAM, but its read
//  port has two clocks of latency and is overwritten by the next sector read,
//  which makes random field access (BPB, directory entries, FAT links)
//  awkward.  Every sector is therefore copied once into a local 512x8 dual
//  port buffer (m5_secbuf) and all parsing / streaming works on that copy with
//  a plain one clock read.  The copy costs 512*3 clocks = 15 us per sector,
//  about 2 % of the 820 us a sector read takes at 5 MHz SPI.
//
//  File layout parsed here
//  -----------------------
//      MBR    LBA 0             partition type at 446+4, LBA at 446+8
//      BPB    partition LBA     bytes/sector 11, sec/cluster 13, reserved 14,
//                               number of FATs 16, FAT size 32 at 36,
//                               root cluster at 44
//      root   first cluster of the root directory, 32 byte entries, first
//                             11 bytes of an entry are the 8.3 name
//      stream cluster chain     FAT[N] -> next cluster,
//                               data LBA = data_start + (N-2)*spc + sector
//
//  The file loops forever: the byte after the last one of the file is the
//  first byte again (O_eof pulses), so the decoder can run an endless demo.
//
//  Byte interface : O_byte_valid / O_byte / I_byte_ready
//=============================================================================
`timescale 1ns / 10ps

module m5_stream (
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_sdram_ready,

    // sector engine
    output reg         O_sd_init,
    output reg         O_sd_start,
    output reg  [31:0] O_sd_lba,
    input  wire        I_sd_busy,
    input  wire        I_sd_done,
    input  wire        I_sd_err,

    // vendor sector RAM read port
    output reg  [8:0]  O_ram_addr,
    input  wire [7:0]  I_ram_dout,

    // byte stream to the decoder
    output reg         O_byte_valid,
    output reg  [7:0]  O_byte,
    input  wire        I_byte_ready,

    // status / debug
    output reg         O_mounted,
    output reg  [2:0]  O_err,
    output reg  [5:0]  O_st,
    output reg  [31:0] O_dbg_clus,
    output reg  [31:0] O_dbg_lba,
    output reg  [31:0] O_dbg_byt,
    output reg         O_eof
);

    //=========================================================================
    // sector buffer (dual port, both ports on I_clk)
    //=========================================================================
    wire [7:0] S_dbuf;
    reg  [8:0] S_frd;      // fetch engine read address
    reg  [8:0] S_brd_s;    // streaming byte read address
    reg        S_brd_sel;  // 1 = the streaming side owns the buffer read port
    wire [8:0] S_brd = S_brd_sel ? S_brd_s : S_frd;
    reg  [8:0] S_caddr;
    reg        S_cwe;

    ram_dual_port_simple #(
        .data_width (8),
        .data_num   (512),
        .num_width  (9)
    ) u_secbuf (
        .douta (),
        .doutb (S_dbuf),
        .dina  (I_ram_dout),
        .addra (S_caddr),
        .addrb (S_brd),
        .wea   (S_cwe),
        .clka  (I_clk),
        .clkb  (I_clk)
    );


    //=========================================================================
    // copy engine : vendor RAM (2 clock latency) -> sector buffer
    //   started by a 1 cycle S_cgo, 512 bytes, reports S_cdone
    //=========================================================================
    localparam [1:0] C_IDLE = 2'd0, C_ADDR = 2'd1, C_W1 = 2'd2, C_W2 = 2'd3;

    reg [1:0] S_cst;
    reg [8:0] S_ci;
    reg       S_cgo;
    reg       S_cdone;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_cst      <= C_IDLE;
            S_ci       <= 9'd0;
            S_cwe      <= 1'b0;
            S_caddr    <= 9'd0;
            S_cdone    <= 1'b0;
            O_ram_addr <= 9'd0;
        end else begin
            S_cwe   <= 1'b0;
            S_cdone <= 1'b0;
            case (S_cst)
                C_IDLE: begin
                    if (S_cgo) begin
                        S_ci  <= 9'd0;
                        S_cst <= C_ADDR;
                    end
                end
                C_ADDR: begin
                    O_ram_addr <= S_ci;
                    S_cst      <= C_W1;
                end
                C_W1: S_cst <= C_W2;
                C_W2: begin
                    S_cwe   <= 1'b1;
                    S_caddr <= S_ci;
                    if (S_ci == 9'd511) begin
                        S_cdone <= 1'b1;
                        S_cst   <= C_IDLE;
                    end else begin
                        S_ci  <= S_ci + 9'd1;
                        S_cst <= C_ADDR;
                    end
                end
                default: S_cst <= C_IDLE;
            endcase
        end
    end

    //=========================================================================
    // little endian multi byte fetch from the sector buffer
    //   request: S_fgo + (S_faddr, S_fn)   ->  response: S_fdone + S_fval
    //=========================================================================
    localparam [1:0] F_IDLE = 2'd0, F_CNT = 2'd1, F_CAP = 2'd2;

    reg [1:0]  S_fst;
    reg        S_fgo;
    reg [8:0]  S_faddr;
    reg [2:0]  S_fn;
    reg [31:0] S_fval;
    reg        S_fdone;
    reg [2:0]  S_fi;
    reg [7:0]  S_fbyte;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_fst   <= F_IDLE;
            S_fdone <= 1'b0;
            S_fval  <= 32'd0;
            S_frd   <= 9'd0;
            S_fi    <= 3'd0;
        end else begin
            S_fdone <= 1'b0;
            case (S_fst)
                F_IDLE: begin
                    if (S_fgo) begin
                        S_frd   <= S_faddr;
                        S_fi    <= 3'd0;
                        S_fval  <= 32'd0;
                        S_fst   <= F_CNT;
                    end
                end
                F_CNT: begin
                    S_fbyte <= S_dbuf;
                    S_fst   <= F_CAP;
                end
                F_CAP: begin
                    S_fval <= S_fval | ({24'd0, S_fbyte} << (S_fi * 3'd8));
                    if ((S_fi + 3'd1) == S_fn) begin
                        S_fdone <= 1'b1;
                        S_fst   <= F_IDLE;
                    end else begin
                        S_fi    <= S_fi + 3'd1;
                        S_frd   <= S_frd + 9'd1;
                        S_fst   <= F_CNT;
                    end
                end
                default: S_fst <= F_IDLE;
            endcase
        end
    end

    //=========================================================================
    // main FSM
    //=========================================================================
    localparam [5:0]
        T_POR      = 6'd0,
        T_INIT_GO  = 6'd1,
        T_INIT_W   = 6'd2,
        T_COPY     = 6'd3,      // wait for the sector copy, then S_after
        T_MBR_GO   = 6'd4,
        T_MBR_W    = 6'd5,
        T_PART     = 6'd6,
        T_PART_W   = 6'd7,
        T_PART2    = 6'd8,
        T_PART2_W  = 6'd9,
        T_BPB_GO   = 6'd10,
        T_BPB_W    = 6'd11,
        T_BPS      = 6'd12,
        T_BPS_W    = 6'd13,
        T_SPC      = 6'd14,
        T_SPC_W    = 6'd15,
        T_RSVD     = 6'd16,
        T_RSVD_W   = 6'd17,
        T_NFAT     = 6'd18,
        T_NFAT_W   = 6'd19,
        T_FSZ      = 6'd20,
        T_FSZ_W    = 6'd21,
        T_ROOTC    = 6'd22,
        T_ROOTC_W  = 6'd23,
        T_ROOT_GO  = 6'd24,
        T_ROOT_W   = 6'd25,
        T_DIR_B0   = 6'd26,
        T_DIR_B0_W = 6'd27,
        T_DIR_NAME = 6'd28,
        T_DIR_NM_W = 6'd29,
        T_DIR_CL   = 6'd30,
        T_DIR_CL_W = 6'd31,
        T_DIR_SZ   = 6'd32,
        T_DIR_SZ_W = 6'd33,
        T_ST_GO    = 6'd34,
        T_ST_W     = 6'd35,
        T_ST_BYTE  = 6'd36,
        T_ST_NEXT  = 6'd37,
        T_FAT_GO   = 6'd38,
        T_FAT_W    = 6'd39,
        T_FAT_CL   = 6'd40,
        T_FAT_CL_W = 6'd41,
        T_LOOP     = 6'd42,
        T_RETRY    = 6'd43,
        T_DIR_NEXT = 6'd44;

    localparam [19:0] POR_LIMIT = 20'd1_000_000;    // 10 ms at 100 MHz

    reg [5:0]  S_st, S_after;
    reg [19:0] S_por;
    reg [19:0] S_wait;
    reg [3:0]  S_retry;

    reg [31:0] S_part_lba, S_fat_lba, S_data_lba, S_root_clus;
    reg [7:0]  S_spc, S_nfat;
    reg [15:0] S_rsvd;
    reg [31:0] S_fatsz;
    reg [31:0] S_clus, S_first_clus, S_file_size, S_bytes;
    reg [8:0]  S_sec_in;
    reg [7:0]  S_dir_i;
    reg [4:0]  S_name_i;
    reg [8:0]  S_byte_ptr;
    reg        S_name_ok;
    reg        S_by_req;            // streaming byte : read address in flight

    wire [31:0] S_clus_lba = S_data_lba + (S_clus - 32'd2) * {23'd0, S_spc}
                           + {23'd0, S_sec_in};
    wire [31:0] S_root_lba = S_data_lba + (S_root_clus - 32'd2) * {23'd0, S_spc}
                           + {23'd0, S_sec_in};
    wire [8:0]  S_entry_off = {S_dir_i[3:0], 5'b0};              // dir entry * 32
    wire [8:0]  S_name_off  = S_entry_off + {4'd0, S_name_i};
    wire [8:0]  S_fat_off   = {S_clus[6:0], 2'b0};               // (clus&127)*4
    wire [31:0] S_fat_sec   = S_fat_lba + {25'd0, S_clus[31:7]};

    // 8.3 name "VID0    M5V"
    function [7:0] name_ch;
        input [4:0] i;
        begin
            case (i)
            5'd0:  name_ch = 8'h56;     // V
            5'd1:  name_ch = 8'h49;     // I
            5'd2:  name_ch = 8'h44;     // D
            5'd3:  name_ch = 8'h30;     // 0
            5'd4:  name_ch = 8'h20;
            5'd5:  name_ch = 8'h20;
            5'd6:  name_ch = 8'h20;
            5'd7:  name_ch = 8'h20;
            5'd8:  name_ch = 8'h4D;     // M
            5'd9:  name_ch = 8'h35;     // 5
            5'd10: name_ch = 8'h56;     // V
            default: name_ch = 8'h00;
            endcase
        end
    endfunction

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st         <= T_POR;
            S_after      <= T_POR;
            S_brd_sel    <= 1'b0;
            S_por        <= 20'd0;
            S_wait       <= 20'd0;
            S_retry      <= 4'd0;
            S_part_lba   <= 32'd0;
            S_fat_lba    <= 32'd0;
            S_data_lba   <= 32'd0;
            S_root_clus  <= 32'd0;
            S_spc        <= 8'd1;
            S_nfat       <= 8'd1;
            S_rsvd       <= 16'd0;
            S_fatsz      <= 32'd0;
            S_clus       <= 32'd0;
            S_first_clus <= 32'd0;
            S_file_size  <= 32'd0;
            S_bytes      <= 32'd0;
            S_sec_in     <= 9'd0;
            S_dir_i      <= 8'd0;
            S_name_i     <= 5'd0;
            S_byte_ptr   <= 9'd0;
            S_name_ok    <= 1'b0;
            S_by_req     <= 1'b0;
            S_brd_s      <= 9'd0;
            S_fgo        <= 1'b0;
            S_faddr      <= 9'd0;
            S_fn         <= 3'd0;
            S_cgo        <= 1'b0;
            O_sd_init    <= 1'b0;
            O_sd_start   <= 1'b0;
            O_sd_lba     <= 32'd0;
            O_byte_valid <= 1'b0;
            O_byte       <= 8'd0;
            O_mounted    <= 1'b0;
            O_err        <= 3'd0;
            O_st         <= 6'd0;
            O_dbg_clus   <= 32'd0;
            O_dbg_lba    <= 32'd0;
            O_dbg_byt    <= 32'd0;
            O_eof        <= 1'b0;
        end else begin
            O_sd_start <= 1'b0;
            O_eof      <= 1'b0;
            S_fgo      <= 1'b0;
            S_cgo      <= 1'b0;
            O_st       <= S_st;

            case (S_st)
            //------------------------------------------------- power on delay
            T_POR: begin
                if (S_por == POR_LIMIT) begin
                    S_por <= 20'd0;
                    S_st  <= T_INIT_GO;
                end else
                    S_por <= S_por + 20'd1;
            end
            //------------------------------------------------- card init
            T_INIT_GO: begin
                O_sd_init  <= 1'b1;
                O_sd_start <= 1'b1;
                S_st       <= T_INIT_W;
            end
            T_INIT_W: begin
                O_sd_init <= 1'b0;
                if (I_sd_done)    S_st <= T_MBR_GO;
                else if (I_sd_err) begin O_err <= 3'd1; S_wait <= 20'd0; S_st <= T_RETRY; end
            end
            //------------------------------------------------- shared copy wait
            T_COPY: begin
                if (S_cdone) begin
                    S_st <= S_after;
                    if (S_after == T_ST_BYTE) begin
                        S_brd_sel  <= 1'b1;
                        S_byte_ptr <= 9'd0;
                        S_by_req   <= 1'b0;
                        O_byte_valid <= 1'b0;
                    end
                end
            end
            //------------------------------------------------- MBR
            T_MBR_GO: begin
                O_sd_lba   <= 32'd0;
                O_sd_start <= 1'b1;
                S_st       <= T_MBR_W;
            end
            T_MBR_W: begin
                if (I_sd_done) begin
                    S_cgo  <= 1'b1;
                    S_after <= T_PART;
                    S_st   <= T_COPY;
                end else if (I_sd_err) begin
                    O_err <= 3'd2; S_wait <= 20'd0; S_st <= T_RETRY;
                end
            end
            //  partition type at 446+4 (4 bytes: type, CHS, LBA at +8)
            //  entry 0 only; a zero type means "no partition table" and the
            //  volume may start at LBA 0 (super floppy), which the BPB read
            //  below then simply reads again.
            T_PART: begin
                S_fgo   <= 1'b1; S_faddr <= 9'd450; S_fn <= 3'd4; S_st <= T_PART_W;
            end
            T_PART_W: begin
                if (S_fdone) begin
                    if (S_fval == 32'd0) begin
                        S_part_lba <= 32'd0;
                        S_st       <= T_BPB_GO;
                    end else
                        S_st <= T_PART2;
                end
            end
            T_PART2: begin
                S_fgo <= 1'b1; S_faddr <= 9'd454; S_fn <= 3'd4; S_st <= T_PART2_W;
            end
            T_PART2_W: begin
                if (S_fdone) begin
                    S_part_lba <= S_fval;
                    S_st       <= T_BPB_GO;
                end
            end
            //------------------------------------------------- BPB
            T_BPB_GO: begin
                O_sd_lba   <= S_part_lba;
                O_sd_start <= 1'b1;
                S_st       <= T_BPB_W;
            end
            T_BPB_W: begin
                if (I_sd_done) begin
                    S_cgo  <= 1'b1;
                    S_after <= T_BPS;
                    S_st   <= T_COPY;
                end else if (I_sd_err) begin
                    O_err <= 3'd2; S_wait <= 20'd0; S_st <= T_RETRY;
                end
            end
            T_BPS: begin S_fgo <= 1'b1; S_faddr <= 9'd11; S_fn <= 3'd2; S_st <= T_BPS_W; end
            T_BPS_W: begin
                if (S_fdone) begin
                    if (S_fval != 32'd512) begin
                        O_err <= 3'd2; S_wait <= 20'd0; S_st <= T_RETRY;
                    end else S_st <= T_SPC;
                end
            end
            T_SPC: begin S_fgo <= 1'b1; S_faddr <= 9'd13; S_fn <= 3'd1; S_st <= T_SPC_W; end
            T_SPC_W: begin
                if (S_fdone) begin S_spc <= S_fval[7:0]; S_st <= T_RSVD; end
            end
            T_RSVD: begin S_fgo <= 1'b1; S_faddr <= 9'd14; S_fn <= 3'd2; S_st <= T_RSVD_W; end
            T_RSVD_W: begin
                if (S_fdone) begin S_rsvd <= S_fval[15:0]; S_st <= T_NFAT; end
            end
            T_NFAT: begin S_fgo <= 1'b1; S_faddr <= 9'd16; S_fn <= 3'd1; S_st <= T_NFAT_W; end
            T_NFAT_W: begin
                if (S_fdone) begin S_nfat <= S_fval[7:0]; S_st <= T_FSZ; end
            end
            T_FSZ: begin S_fgo <= 1'b1; S_faddr <= 9'd36; S_fn <= 3'd4; S_st <= T_FSZ_W; end
            T_FSZ_W: begin
                if (S_fdone) begin
                    if (S_fval == 32'd0) begin
                        O_err <= 3'd2; S_wait <= 20'd0; S_st <= T_RETRY;
                    end else begin
                        S_fatsz    <= S_fval;
                        S_fat_lba  <= S_part_lba + {16'd0, S_rsvd};
                        S_data_lba <= S_part_lba + {16'd0, S_rsvd}
                                    + S_fval * {24'd0, S_nfat};
                        if (S_spc == 8'd0 || S_nfat == 8'd0) begin
                            O_err <= 3'd2; S_wait <= 20'd0; S_st <= T_RETRY;
                        end else
                            S_st <= T_ROOTC;
                    end
                end
            end
            T_ROOTC: begin S_fgo <= 1'b1; S_faddr <= 9'd44; S_fn <= 3'd4; S_st <= T_ROOTC_W; end
            T_ROOTC_W: begin
                if (S_fdone) begin
                    S_root_clus <= S_fval;
                    S_clus      <= S_fval;
                    S_sec_in    <= 9'd0;
                    S_st        <= T_ROOT_GO;
                end
            end
            //------------------------------------------------- root directory
            T_ROOT_GO: begin
                O_sd_lba   <= S_root_lba;
                O_sd_start <= 1'b1;
                S_dir_i    <= 8'd0;
                S_st       <= T_ROOT_W;
            end
            T_ROOT_W: begin
                if (I_sd_done) begin
                    S_cgo  <= 1'b1;
                    S_after <= T_DIR_B0;
                    S_st   <= T_COPY;
                end else if (I_sd_err) begin
                    O_err <= 3'd3; S_wait <= 20'd0; S_st <= T_RETRY;
                end
            end
            T_DIR_B0: begin
                S_fgo <= 1'b1; S_faddr <= S_entry_off; S_fn <= 3'd1; S_st <= T_DIR_B0_W;
            end
            T_DIR_B0_W: begin
                if (S_fdone) begin
                    if (S_fval == 32'd0) begin
                        O_err <= 3'd4; S_wait <= 20'd0; S_st <= T_RETRY;
                    end else if (S_fval == 32'd229) begin        // 0xE5 = deleted
                        S_st <= T_DIR_NEXT;
                    end else begin
                        S_name_i  <= 5'd0;
                        S_name_ok <= 1'b1;
                        S_st      <= T_DIR_NAME;
                    end
                end
            end
            T_DIR_NAME: begin
                S_fgo <= 1'b1; S_faddr <= S_name_off; S_fn <= 3'd1; S_st <= T_DIR_NM_W;
            end
            T_DIR_NM_W: begin
                if (S_fdone) begin
                    if (S_fval[7:0] != name_ch(S_name_i)) S_name_ok <= 1'b0;
                    if (S_name_i == 5'd10) S_st <= T_DIR_CL;
                    else begin
                        S_name_i <= S_name_i + 5'd1;
                        S_st      <= T_DIR_NAME;
                    end
                end
            end
            T_DIR_CL: begin
                S_fgo <= 1'b1; S_faddr <= S_entry_off + 9'd26; S_fn <= 3'd4;
                S_st  <= T_DIR_CL_W;
            end
            T_DIR_CL_W: begin
                if (S_fdone) begin
                    S_first_clus <= S_fval;
                    S_st         <= T_DIR_SZ;
                end
            end
            T_DIR_SZ: begin
                S_fgo <= 1'b1; S_faddr <= S_entry_off + 9'd28; S_fn <= 3'd4;
                S_st  <= T_DIR_SZ_W;
            end
            T_DIR_SZ_W: begin
                if (S_fdone) begin
                    if (S_name_ok && (S_fval != 32'd0)) begin
                        S_file_size <= S_fval;
                        S_clus      <= S_first_clus;
                        S_sec_in    <= 9'd0;
                        S_bytes     <= 32'd0;
                        O_mounted   <= 1'b1;
                        O_err       <= 3'd0;
                        S_st        <= T_ST_GO;
                    end else
                        S_st <= T_DIR_NEXT;
                end
            end
            //------------------------------------------------- next directory entry
            T_DIR_NEXT: begin
                if (S_dir_i == 8'd15) begin
                    if ((S_sec_in + 9'd1) >= {1'b0, S_spc}) begin
                        O_err <= 3'd4; S_wait <= 20'd0; S_st <= T_RETRY;
                    end else begin
                        S_sec_in <= S_sec_in + 9'd1;
                        S_st     <= T_ROOT_GO;
                    end
                end else begin
                    S_dir_i <= S_dir_i + 8'd1;
                    S_st    <= T_DIR_B0;
                end
            end
            //------------------------------------------------- stream a sector
            T_ST_GO: begin
                O_sd_lba   <= S_clus_lba;
                O_sd_start <= 1'b1;
                O_dbg_clus <= S_clus;
                O_dbg_lba  <= S_clus_lba;
                S_st       <= T_ST_W;
            end
            T_ST_W: begin
                if (I_sd_done) begin
                    S_cgo   <= 1'b1;
                    S_after <= T_ST_BYTE;
                    S_st    <= T_COPY;
                end else if (I_sd_err) begin
                    O_err <= 3'd5; S_wait <= 20'd0; S_st <= T_RETRY;
                end
            end
            T_ST_BYTE: begin
                if (!O_byte_valid) begin
                    if (!S_by_req) begin
                        S_brd_s  <= S_byte_ptr;
                        S_by_req <= 1'b1;
                    end else begin
                        O_byte       <= S_dbuf;
                        O_byte_valid <= 1'b1;
                        S_by_req     <= 1'b0;
            S_brd_s      <= 9'd0;
                    end
                end else if (I_byte_ready) begin
                    O_byte_valid <= 1'b0;
                    O_dbg_byt    <= O_dbg_byt + 32'd1;
                    S_bytes      <= S_bytes + 32'd1;
                    if ((S_bytes + 32'd1) == S_file_size)
                        S_st <= T_LOOP;
                    else if (S_byte_ptr == 9'd511)
                        S_st <= T_ST_NEXT;
                    else
                        S_byte_ptr <= S_byte_ptr + 9'd1;
                end
            end
            T_ST_NEXT: begin
                if ((S_sec_in + 9'd1) >= {1'b0, S_spc}) begin
                    S_sec_in <= 9'd0;
                    S_st     <= T_FAT_GO;
                end else begin
                    S_sec_in <= S_sec_in + 9'd1;
                    S_st     <= T_ST_GO;
                end
            end
            //------------------------------------------------- FAT chain
            T_FAT_GO: begin
                O_sd_lba   <= S_fat_sec;
                O_sd_start <= 1'b1;
                S_st       <= T_FAT_W;
            end
            T_FAT_W: begin
                if (I_sd_done) begin
                    S_cgo   <= 1'b1;
                    S_after <= T_FAT_CL;
                    S_st    <= T_COPY;
                end else if (I_sd_err) begin
                    O_err <= 3'd6; S_wait <= 20'd0; S_st <= T_RETRY;
                end
            end
            T_FAT_CL: begin
                S_fgo <= 1'b1; S_faddr <= S_fat_off; S_fn <= 3'd4; S_st <= T_FAT_CL_W;
            end
            T_FAT_CL_W: begin
                if (S_fdone) begin
                    if (S_fval >= 32'h0FFFFFF8)                  // end of chain
                        S_st <= T_LOOP;
                    else begin
                        S_clus <= S_fval;
                        S_st   <= T_ST_GO;
                    end
                end
            end
            //------------------------------------------------- loop forever
            T_LOOP: begin
                O_eof     <= 1'b1;
                S_clus    <= S_first_clus;
                S_sec_in  <= 9'd0;
                S_bytes   <= 32'd0;
                S_st      <= T_ST_GO;
            end
            //------------------------------------------------- error / retry
            T_RETRY: begin
                O_byte_valid <= 1'b0;
                S_by_req     <= 1'b0;
            S_brd_s      <= 9'd0;
                if (S_wait == 20'hFFFFF) begin        // ~10 ms
                    S_wait <= 20'd0;
                    if (S_retry != 4'd5) S_retry <= S_retry + 4'd1;
                    S_st <= T_INIT_GO;
                end else
                    S_wait <= S_wait + 20'd1;
            end
            default: S_st <= T_POR;
            endcase
        end
    end

endmodule
