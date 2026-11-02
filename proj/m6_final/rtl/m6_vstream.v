//=============================================================================
//  m6_vstream.v  --  cluster chain block streamer for one video clip (100 MHz)
//
//  M6 splits the FAT work differently from M4/M5: m6_fat has already mounted the
//  card, scanned the root directory and found every playlist entry, so it can
//  simply hand this module the five numbers a streamer needs:
//
//      I_clus      first cluster of the file
//      I_size      file size in bytes (defines the end of the file)
//      I_data_lba  first data sector (cluster 2 sector 0)
//      I_fat_lba   first FAT sector
//      I_spc       sectors per cluster (I_log2spc = log2 of it)
//
//  This module then owns the SD engine and the vendor sector buffer until the
//  whole clip has been streamed: it reads one 512 byte sector, copies it into a
//  local buffer, and hands the 512 bytes to the decoder over a valid/ready
//  byte interface.  One sector at a time is read, so the header (V_HDR_M) is
//  streamed before the first frame block, exactly like M5.
//
//  Why a separate sector buffer
//  ----------------------------
//  The vendor RD_RAM has a registered read port and gets overwritten by the next
//  sector read; the byte pump reads the same byte several times (valid held
//  until accepted), so a private copy makes the handshake independent of the SD
//  engine timing.  The copy costs 512*3 clocks = 15 us per sector, ~4 % of the
//  410 us a sector read takes at 10 MHz SPI.
//
//  File layout used here (all parsed by m6_fat)
//      data sector of cluster N, sector S :  DATA_LBA + (N-2)*SPC + S
//      FAT entry of cluster N            :  FAT_LBA + (N >> 7),
//                                            byte (N & 127) * 4, little endian
//      end of chain                      :  >= 0x0FFFFFF8
//
//  When the last byte of the file has been handed over the stream restarts at
//  the first cluster (O_eof pulses).  m6_vdec knows the frame count from the
//  32 byte file header, so it detects the end of the clip itself and m6_top
//  freezes this module before the second pass gets far.
//=============================================================================
`timescale 1ns / 10ps

module m6_vstream (
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_sdram_ready,

    // ---- job parameters (latched on I_go) ----------------------------------
    input  wire        I_go,            // one cycle: start streaming
    input  wire [31:0] I_clus,
    input  wire [31:0] I_size,
    input  wire [31:0] I_data_lba,
    input  wire [31:0] I_fat_lba,
    input  wire [7:0]  I_spc,
    input  wire [4:0]  I_log2spc,

    // ---- sector engine -----------------------------------------------------
    output reg         O_sd_start,
    output reg  [31:0] O_sd_lba,
    input  wire        I_sd_done,
    input  wire        I_sd_err,

    // ---- vendor sector RAM read port ---------------------------------------
    output reg  [8:0]  O_ram_addr,
    input  wire [7:0]  I_ram_dout,

    // ---- byte stream to the decoder ----------------------------------------
    output reg         O_byte_valid,
    output reg  [7:0]  O_byte,
    input  wire        I_byte_ready,

    // ---- status ------------------------------------------------------------
    output wire        O_busy,
    output reg  [2:0]  O_err,
    output reg  [5:0]  O_st,
    output reg  [31:0] O_byt,           // bytes handed to the decoder
    output reg         O_eof            // 1 cycle: the stream wrapped to byte 0
);

    localparam [27:0] EOC = 28'h0FFFFFF8;

    //-------------------------------------------------------------------------
    // state encoding
    //-------------------------------------------------------------------------
    localparam [5:0]
        T_IDLE   = 6'd0,        // waiting for I_go
        T_ST_PRE = 6'd1,        // stage 1 of the sector LBA (multiply)
        T_ST_PRE2= 6'd2,        // stage 2 of the sector LBA (add)
        T_ST_GO  = 6'd3,        // issue the sector read
        T_ST_W   = 6'd4,        // wait for the sector
        T_COPY   = 6'd5,        // vendor RAM -> local buffer
        T_ST_BYTE= 6'd6,        // hand the 512 bytes out
        T_ST_NEXT= 6'd7,        // next sector inside the cluster
        T_FAT_PRE= 6'd8,        // stage 1 of the FAT sector LBA
        T_FAT_GO = 6'd9,
        T_FAT_W  = 6'd10,
        T_FAT_CL = 6'd11,       // fetch the 4 byte FAT entry
        T_FAT_CL2= 6'd14,       // wait for the FAT entry
        T_LOOP   = 6'd12,       // end of file: back to the first cluster
        T_ERR    = 6'd13;

    reg [5:0]  S_st;

    // job parameters
    reg [31:0] S_clus, S_clus_m2, S_first_clus;
    reg [31:0] S_size;
    reg [31:0] S_data_lba, S_fat_lba;
    reg [7:0]  S_spc;
    reg [4:0]  S_log2spc;

    // position inside the file
    reg [8:0]  S_sec_in;            // sector index inside the cluster
    reg [31:0] S_bytes;             // bytes already handed out

    // staged sector LBA
    reg [31:0] S_clus_off;
    reg [31:0] S_lba_r;
    reg [5:0]  S_after;             // COPY -> next state

    wire [31:0] S_cl_off_w = S_clus_m2 * {23'd0, S_spc};
    wire [31:0] S_fat_sec  = S_fat_lba + {25'd0, S_clus[31:7]};
    wire [8:0]  S_fat_off  = {S_clus[6:0], 2'b00};

    //-------------------------------------------------------------------------
    // local sector buffer (512 x 8, both ports on I_clk)
    //-------------------------------------------------------------------------
    wire [7:0] S_dbuf;
    reg  [8:0] S_frd;               // FAT fetch read address
    reg  [8:0] S_brd_s;             // byte pump read address
    reg        S_brd_sel;           // 1 = the byte pump owns the read port
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

    //-------------------------------------------------------------------------
    // copy engine : vendor RAM (registered, 1..2 clocks) -> sector buffer
    //   started by a one cycle S_cgo, 512 bytes, reports S_cdone
    //-------------------------------------------------------------------------
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

    //-------------------------------------------------------------------------
    // FAT entry fetch : 4 bytes little endian at S_fat_off
    //   request S_fgo -> S_fdone + S_fval
    //
    //  The sector buffer has a REGISTERED read port: the address is sampled one
    //  clock after it is presented and the data is available one clock after
    //  that, so a byte must be captured in a state that is TWO cycles after the
    //  address state (F_IDLE sets the address, F_RD waits, F_CNT captures,
    //  F_CAP shifts and issues the next address).  A first version of this file
    //  captured one cycle early, so every FAT entry came back shifted / stale
    //  and the cluster chain jumped to the wrong cluster after the first one -
    //  the clip decoded its first cluster correctly and then filled with
    //  whatever the wrong cluster contained (bench: frame 0 partially decoded,
    //  then the next "frame header" read as zeros).  This is the M5 fetch
    //  engine, verbatim.
    //-------------------------------------------------------------------------
    localparam [1:0] F_IDLE = 2'd0, F_RD = 2'd1, F_CNT = 2'd2, F_CAP = 2'd3;

    reg [1:0]  S_fst;
    reg        S_fgo;
    reg [2:0]  S_fi;
    reg [7:0]  S_fbyte;
    reg [31:0] S_fval;
    reg        S_fdone;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_fst   <= F_IDLE;
            S_fdone <= 1'b0;
            S_fval  <= 32'd0;
            S_frd   <= 9'd0;
            S_fi    <= 3'd0;
            S_fbyte <= 8'd0;
        end else begin
            S_fdone <= 1'b0;
            case (S_fst)
                F_IDLE: begin
                    if (S_fgo) begin
                        S_frd  <= S_fat_off;
                        S_fi   <= 3'd0;
                        S_fval <= 32'd0;
                        S_fst  <= F_RD;
                    end
                end
                F_RD: S_fst <= F_CNT;
                F_CNT: begin
                    S_fbyte <= S_dbuf;
                    S_fst   <= F_CAP;
                end
                default: begin
                    S_fval <= S_fval | ({24'd0, S_fbyte} << {S_fi, 3'b000});
                    if ((S_fi + 3'd1) == 3'd4) begin
                        S_fdone <= 1'b1;
                        S_fst   <= F_IDLE;
                    end else begin
                        S_fi   <= S_fi + 3'd1;
                        S_frd  <= S_frd + 9'd1;
                        S_fst  <= F_RD;
                    end
                end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // byte pump
    //-------------------------------------------------------------------------
    reg [1:0]  S_by_st;
    reg [8:0]  S_byte_ptr;

    assign O_busy = (S_st != T_IDLE) && (S_st != T_ERR);

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st         <= T_IDLE;
            S_clus       <= 32'd0;
            S_clus_m2    <= 32'd0;
            S_first_clus <= 32'd0;
            S_size       <= 32'd0;
            S_data_lba   <= 32'd0;
            S_fat_lba    <= 32'd0;
            S_spc        <= 8'd1;
            S_log2spc    <= 5'd0;
            S_sec_in     <= 9'd0;
            S_bytes      <= 32'd0;
            S_clus_off   <= 32'd0;
            S_lba_r      <= 32'd0;
            S_after      <= T_ST_BYTE;
            S_byte_ptr   <= 9'd0;
            S_by_st      <= 2'd0;
            S_brd_sel    <= 1'b0;
            S_brd_s      <= 9'd0;
            S_cgo        <= 1'b0;
            S_fgo        <= 1'b0;
            O_sd_start   <= 1'b0;
            O_sd_lba     <= 32'd0;
            O_byte_valid <= 1'b0;
            O_byte       <= 8'd0;
            O_err        <= 3'd0;
            O_st         <= T_IDLE;
            O_byt        <= 32'd0;
            O_eof        <= 1'b0;
        end else begin
            O_sd_start <= 1'b0;
            S_cgo      <= 1'b0;
            S_fgo      <= 1'b0;
            O_eof      <= 1'b0;
            O_st       <= S_st;

            case (S_st)
            //------------------------------------------------- idle / start
            T_IDLE: begin
                O_byte_valid <= 1'b0;
                S_by_st      <= 2'd0;
                if (I_go && I_sdram_ready) begin
                    S_clus       <= I_clus;
                    S_clus_m2    <= I_clus - 32'd2;
                    S_first_clus <= I_clus;
                    S_size       <= I_size;
                    S_data_lba   <= I_data_lba;
                    S_fat_lba    <= I_fat_lba;
                    S_spc        <= (I_spc == 8'd0) ? 8'd1 : I_spc;
                    S_log2spc    <= I_log2spc;
                    S_sec_in     <= 9'd0;
                    S_bytes      <= 32'd0;
                    S_byte_ptr   <= 9'd0;
                    O_byt        <= 32'd0;
                    O_err        <= 3'd0;
                    S_st         <= T_ST_PRE;
                end
            end

            //------------------------------------------------- sector address
            //  the multiply is registered on its own stage: "reg -> -2 -> *spc"
            //  in one clock was a 10.5 ns path in M5 (SWNS -0.839 ns)
            T_ST_PRE: begin
                S_clus_off <= S_cl_off_w;
                S_st       <= T_ST_PRE2;
            end

            T_ST_PRE2: begin
                S_lba_r <= S_data_lba + S_clus_off + {23'd0, S_sec_in};
                S_st    <= T_ST_GO;
            end

            T_ST_GO: begin
                O_sd_lba   <= S_lba_r;
                O_sd_start <= 1'b1;
                S_st       <= T_ST_W;
            end

            T_ST_W: begin
                if (I_sd_done) begin
                    S_cgo   <= 1'b1;
                    S_after <= T_ST_BYTE;
                    S_st    <= T_COPY;
                end else if (I_sd_err) begin
                    O_err <= 3'd5;              // sector read timeout
                    S_st  <= T_ERR;
                end
            end

            //------------------------------------------------- shared copy wait
            T_COPY: begin
                if (S_cdone) begin
                    S_brd_sel <= (S_after == T_ST_BYTE);
                    S_by_st   <= 2'd0;
                    S_st      <= S_after;
                end
            end

            //------------------------------------------------- byte handshake
            T_ST_BYTE: begin
                if (!O_byte_valid) begin
                    case (S_by_st)
                    2'd0: begin
                        S_brd_s <= S_byte_ptr;
                        S_by_st <= 2'd1;
                    end
                    2'd1: S_by_st <= 2'd2;      // registered RAM read latency
                    default: begin
                        O_byte       <= S_dbuf;
                        O_byte_valid <= 1'b1;
                        S_by_st      <= 2'd0;
                    end
                    endcase
                end else if (I_byte_ready) begin
                    O_byte_valid <= 1'b0;
                    O_byt        <= O_byt + 32'd1;
                    S_bytes      <= S_bytes + 32'd1;
                    if ((S_bytes + 32'd1) == S_size)
                        S_st <= T_LOOP;         // end of the clip: wrap to byte 0
                    else if (S_byte_ptr == 9'd511) begin
                        S_byte_ptr <= 9'd0;
                        S_st       <= T_ST_NEXT;
                    end else
                        S_byte_ptr <= S_byte_ptr + 9'd1;
                end
            end

            T_ST_NEXT: begin
                if (({1'b0, S_sec_in} + 10'd1) >= {2'd0, S_spc}) begin
                    S_sec_in <= 9'd0;
                    S_st     <= T_FAT_PRE;
                end else begin
                    S_sec_in <= S_sec_in + 9'd1;
                    S_st     <= T_ST_PRE;
                end
            end

            //------------------------------------------------- FAT chain
            T_FAT_PRE: begin
                S_lba_r <= S_fat_sec;
                S_st    <= T_FAT_GO;
            end

            T_FAT_GO: begin
                O_sd_lba   <= S_lba_r;
                O_sd_start <= 1'b1;
                S_st       <= T_FAT_W;
            end

            T_FAT_W: begin
                if (I_sd_done) begin
                    S_cgo   <= 1'b1;
                    S_after <= T_FAT_CL;
                    S_st    <= T_COPY;
                end else if (I_sd_err) begin
                    O_err <= 3'd6;              // FAT read timeout
                    S_st  <= T_ERR;
                end
            end

            T_FAT_CL: begin
                S_brd_sel <= 1'b0;
                S_fgo     <= 1'b1;
                S_st      <= T_FAT_CL2;
            end

            T_FAT_CL2: begin
                if (S_fdone) begin
                    if (S_fval[27:0] >= EOC) begin
                        S_st <= T_LOOP;         // 1 cluster file (or chain end)
                    end else begin
                        S_clus    <= S_fval;
                        S_clus_m2 <= S_fval - 32'd2;
                        S_st      <= T_ST_PRE;
                    end
                end
            end

            //------------------------------------------------- wrap to byte 0
            T_LOOP: begin
                O_eof     <= 1'b1;
                S_clus    <= S_first_clus;
                S_clus_m2 <= S_first_clus - 32'd2;
                S_sec_in  <= 9'd0;
                S_bytes   <= 32'd0;
                S_byte_ptr<= 9'd0;
                S_st      <= T_ST_PRE;
            end

            //------------------------------------------------- error
            T_ERR: begin
                O_byte_valid <= 1'b0;
                S_by_st      <= 2'd0;
                if (I_go) S_st <= T_IDLE;       // re-armed by the next job
            end

            default: S_st <= T_IDLE;
            endcase
        end
    end

endmodule
