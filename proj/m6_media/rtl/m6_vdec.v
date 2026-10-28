//=============================================================================
//  m6_vdec.v  --  M5V1 video decoder + frame pacer (100 MHz domain)
//
//  Consumes the byte stream produced by m6_stream and writes complete 640x480
//  pages into the SDRAM ring ("continuous WR1"), one page per video frame.
//
//  WHY A CONTINUOUS RING INSTEAD OF m4_page_wr
//  -------------------------------------------
//  m4_page_wr writes a page row by row and waits DRAIN=4096 clocks between
//  rows (a safety margin for the BMP path).  For a 640x480 page that is
//  480*4096 = 1.97 M clocks = 19.7 ms per frame, which a 15 fps budget of
//  66.7 ms cannot afford on top of the ~50 ms the card needs to deliver the
//  frame.  A video page is exactly 307200 words = 2400 bursts of 128 words,
//  so it can be streamed instead: WR1_LOAD is pulsed once, WR1_ADDR = page A
//  base is the wrap point, and the controller auto-increments in 128 word
//  bursts.  Frames then land on page boundaries by construction and the two
//  display read ports keep seeing page A / page B alternately.
//
//  SOURCE FORMAT (see tools/m6_encode.py)
//  --------------------------------------
//  320x240 RGB332, RLE; frame block = u32 len, u16 audio_samples, u16 bpp,
//  then len bytes of RLE payload, then audio_samples*2 bytes mono s16 (big
//  endian).  Every source pixel becomes a 2x2 block (640x480), so the M4
//  display chain (640x480 window inside 1280x720) needs no change.
//
//  RLE token (16 bit big endian)
//      1 = repeat : count = (tok & 0x0FFF) + 1, next 1 byte is the pixel
//      2 = literal: count = (tok & 0x0FFF) + 1, next count bytes are pixels
//      0 = end of frame
//
//  Pacing: one frame per PERIOD = 100 MHz / fps clocks, so the video time base
//  matches the audio chunks the encoder wrote into the file.
//=============================================================================
`timescale 1ns / 10ps

module m6_vdec #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer FPS    = 15
) (
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_sdram_ready,

    // byte stream from m6_stream
    input  wire        I_byte_valid,
    input  wire [7:0]  I_byte,
    output wire        O_byte_ready,
    input  wire        I_eof,

    // SDRAM write ring (WR1)
    output wire        O_wr,
    output wire [31:0] O_wr_data,
    input  wire        I_wr_full,
    output reg         O_wr_load,
    output wire [20:0] O_wr_addr,

    // M6 playlist : which of the two pages the FIRST frame must be written to
    // (0 = page A at word 0, 1 = page B at word 0x4B000).  Set to the page that
    // is NOT on screen when the clip starts, so frame 0 lands in the hidden
    // buffer and the switch-over happens on a complete frame.
    input  wire        I_start_page,

    // page ready handshake to m6_video_src720.  M6 does not drive the toggle
    // directly any more: m6_top owns the single toggle so that the image loader
    // and the video decoder can share it without a mux glitch.
    output reg         O_pg_done,       // 1 cycle: a complete page is in SDRAM
    output reg         O_pg_page,       // which page
    output reg         O_clip_end,      // 1 cycle: the last frame of the clip is up

    // status
    output wire        O_busy,
    output reg  [15:0] O_frame_cnt,
    output reg  [5:0]  O_st,
    output reg  [2:0]  O_err,

    // audio chunk (mono s16) for the I2S side
    output reg         O_aud_we,
    output reg  [15:0] O_aud_data,

    // bring-up observability (UART status line)
    output wire [31:0] O_dbg_vbyt,      // bytes consumed by the decoder
    output wire [31:0] O_dbg_px,        // pixels written in the current frame
    output wire [15:0] O_dbg_audn,      // audio samples of the last frame header
    output wire [31:0] O_dbg_len,       // payload length of the last frame header
    output wire [31:0] O_dbg_endv,      // byte counter when the first end token was seen
    output wire [31:0] O_dbg_hdrb,      // first 4 bytes of the last frame block header
    output wire [31:0] O_dbg_raw32,     // raw stream bytes at positions 32..35
    output wire [31:0] O_dbg_rawh       // raw stream bytes at positions 4..7
);

    localparam integer PERIOD = CLK_HZ / FPS;       // 6_666_666 for 15 fps

    //-------------------------------------------------------------------------
    // frame period timer (free running, a frame may start on the wrap)
    //-------------------------------------------------------------------------
    reg [31:0] S_tmr;
    wire S_tmr_wrap = (S_tmr >= PERIOD - 1);

    always @(posedge I_clk) begin
        if (I_rst)           S_tmr <= 32'd0;
        else if (S_tmr_wrap) S_tmr <= 32'd0;
        else                 S_tmr <= S_tmr + 32'd1;
    end

    //-------------------------------------------------------------------------
    // header / frame header latches
    //-------------------------------------------------------------------------
    reg  [255:0] S_hdr;
    reg  [7:0]   S_hcnt;
    reg  [63:0]  S_fhdr;
    reg  [3:0]   S_fcnt;
    reg  [31:0]  S_len;
    reg  [15:0]  S_aud_n;
    reg  [15:0]  S_aud_i;
    reg  [31:0]  S_frames;   // frame count from the file header
    reg  [8:0]  S_rows;     // source rows emitted in the current frame
    reg  [31:0] S_endv;     // S_vbyt when the first end-of-frame token was seen
    reg         S_endv_cap;

    // deterministic frame framing (see the header comments)
    reg  [31:0] S_pend;     // absolute byte position just past this frame payload
    reg  [31:0] S_skip;     // payload bytes still to be discarded
    reg  [31:0] S_hdrb;     // first 4 bytes after the file header (frame block header)
    reg         S_align_b;  // 1 = the header parse was one byte short, fix it up

    //-------------------------------------------------------------------------
    // row buffer : 320 source pixels of the row being decoded
    //-------------------------------------------------------------------------
    reg  [7:0] S_row [0:319];
    reg  [8:0] S_x;                 // source pixel index 0..319
    reg  [9:0] S_tx;                // output pixel index 0..639
    reg        S_pass;              // the source row is written twice
    reg  [7:0] S_pix;               // pixel of a repeat token
    reg  [11:0] S_left;             // pixels still to write for this token
    reg        S_rep;               // 1 = repeat token, 0 = literal
    reg  [15:0] S_tok;
    reg  [7:0] S_aud_hi;
    reg        S_aud_lo;

    wire [11:0] S_cnt = S_tok[11:0];

    // RGB332 -> RGB888 by bit replication (7 -> 255, 1 -> 36, ...)
    wire [7:0] S_src = S_row[S_tx[9:1]];
    wire [7:0] S_r8  = {S_src[7:5], S_src[7:6], S_src[7:5]};
    wire [7:0] S_g8  = {S_src[4:2], S_src[4:3], S_src[4:2]};
    wire [7:0] S_b8  = {S_src[1:0], S_src[1:0], S_src[1:0], S_src[1:0]};
    wire [23:0] S_rgb = {S_r8, S_g8, S_b8};

    assign O_wr       = (S_st == V_EMIT) && !I_wr_full;
    assign O_wr_data  = {8'h00, S_rgb};

    //-------------------------------------------------------------------------
    // WR1 start address / ring
    //
    //  Sdram_Control_4Port wraps the write address back to the CURRENT WR1_ADDR
    //  input (not to 0) once a burst would cross WR1_MAX_ADDR, and every frame
    //  is exactly 307200 words = half of the 614400 word ring.  So
    //    * frame k lands on page  (start_page ^ k[0]),
    //    * WR1_ADDR must be the start page for exactly the WR1_LOAD cycle so the
    //      first frame really begins at that page (a 1 cycle pulse is enough:
    //      the controller latches rWR1_ADDR on WR1_LOAD),
    //    * and it must be 0 for every later burst, so that after frame 0 the
    //      address wraps to word 0 and the full two page ring is used again.
    //  With I_start_page = 0 this is exactly the M5 behaviour (WR1_ADDR = 0).
    //-------------------------------------------------------------------------
    assign O_wr_addr = (O_wr_load && I_start_page) ? 21'h04B000 : 21'd0;

    assign O_busy     = (S_st != V_WAIT);

    // bring-up counters
    reg [31:0] S_vbyt;
    reg [31:0] S_px;
    wire W_consume = I_byte_valid && O_byte_ready;

    assign O_dbg_vbyt = S_vbyt;
    assign O_dbg_px   = S_px;
    assign O_dbg_audn = S_aud_n;
    assign O_dbg_len  = S_len;
    assign O_dbg_endv = S_endv;
    assign O_dbg_hdrb = S_hdrb;

    //-------------------------------------------------------------------------
    // raw byte probes : sample the stream purely by its byte position, without
    // any header / frame parsing involved.  A correctly aligned stream gives
    //   positions  4.. 7 : 01 40 00 F0   (width / height of the file header)
    //   positions 32..35 : 00 00 45 0A   (u32 payload length of frame block 0)
    // so a mismatch here proves the byte stream itself lost / gained a byte.
    //-------------------------------------------------------------------------
    reg  [31:0] S_raw32;
    reg  [31:0] S_rawh;
    always @(posedge I_clk) begin
        if (I_rst) begin
            S_raw32 <= 32'd0;
            S_rawh  <= 32'd0;
        end else if (W_consume) begin
            if ((S_vbyt >= 32'd4)  && (S_vbyt < 32'd8))  S_rawh  <= {S_rawh[23:0],  I_byte};
            if ((S_vbyt >= 32'd32) && (S_vbyt < 32'd36)) S_raw32 <= {S_raw32[23:0], I_byte};
        end
    end
    assign O_dbg_raw32 = S_raw32;
    assign O_dbg_rawh  = S_rawh;

    // byte position after the current access, i.e. the value S_vbyt takes at the
    // next clock edge
    wire [31:0] S_vbyt_nx = S_vbyt + {31'd0, W_consume};
    // frame block header as it was shifted in (bytes b0..b3 of the 8 byte block)
    wire [31:0] S_len_w   = S_fhdr[55:24];
    // file header bpp field.  The terminator byte of V_HDR_R is being shifted
    // into S_hdr in the very cycle the comparison below is evaluated, so the
    // fields must be extracted from the NEXT value of the shift register,
    // {S_hdr[247:0], I_byte} - otherwise the comparison sees only 28 latched
    // bytes and every field is off by one byte.
    //   a) 32 header bytes consumed -> 29 bytes latched -> byte 3..31
    //   b) 31 header bytes consumed -> 28 bytes latched -> byte 3..30
    wire [255:0] S_hdr_nx = {S_hdr[247:0], I_byte};
    wire [15:0] S_bpp_a   = S_hdr_nx[175:160];   // file bytes 10,11
    wire [15:0] S_bpp_b   = S_hdr_nx[167:152];   // file bytes 10,11 when one short
    // frame count of the clip (sanity clamped so a corrupt value cannot make the
    // decoder wrap the stream forever)
    wire [31:0] S_fr_w    = (S_bpp_a == 16'd1) ? S_hdr_nx[159:128]
                                               : S_hdr_nx[151:120];
    wire [31:0] S_fr_n    = ((S_fr_w == 32'd0) || (S_fr_w > 32'd10000))
                            ? 32'd60000 : S_fr_w;

    //-------------------------------------------------------------------------
    // FSM
    //-------------------------------------------------------------------------
    localparam [5:0]
        V_WAIT   = 6'd0,
        V_HDR_M  = 6'd1,        // resync : wait for 'M'
        V_HDR_5  = 6'd2,
        V_HDR_V  = 6'd3,
        V_HDR_1  = 6'd4,
        V_HDR_R  = 6'd5,        // remaining 31 header bytes
        V_FRAME  = 6'd6,        // wait for the period boundary
        V_FHDR   = 6'd7,        // 8 byte frame block header
        V_TOKEN0 = 6'd8,
        V_TOKEN1 = 6'd9,
        V_PARSE  = 6'd10,
        V_REPPIX = 6'd11,       // pixel byte of a repeat token
        V_WRITE  = 6'd12,       // write pixels into the row buffer
        V_EMIT   = 6'd13,
        V_AUDIO  = 6'd14,
        V_DONE   = 6'd15,
        V_ALIGN1 = 6'd16,       // fallback: swallow one extra header byte
        V_PSKIP  = 6'd17,       // discard the rest of a frame payload
        V_PEND   = 6'd18;       // compute the payload end position (timing)

    reg [5:0] S_st;

    //-------------------------------------------------------------------------
    // Byte handshake
    //-------------------------------------------------------------------------
    // O_byte_ready must be high in the SAME cycle the FSM samples I_byte_valid.
    // When it was a registered output it was still low during the first cycle
    // of every new state, so a byte that the stream had already presented was
    // latched into the state machine while the handshake did not happen: the
    // byte was then consumed one cycle later and used a second time, i.e. one
    // byte of the stream was silently dropped per occurrence and the RLE stream
    // desynchronised.  Drive it combinationally from the state instead.
    wire S_byte_want =
           (S_st == V_HDR_M)  || (S_st == V_HDR_5) || (S_st == V_HDR_V) ||
           (S_st == V_HDR_1)  || (S_st == V_HDR_R) || (S_st == V_ALIGN1) ||
           (S_st == V_FHDR)   || (S_st == V_TOKEN0)|| (S_st == V_TOKEN1) ||
           (S_st == V_REPPIX) || (S_st == V_PSKIP) || (S_st == V_AUDIO)  ||
           ((S_st == V_WRITE) && !S_rep);
    assign O_byte_ready = S_byte_want;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st         <= V_WAIT;
            S_hdr        <= 256'd0;
            S_hcnt       <= 8'd0;
            S_fhdr       <= 64'd0;
            S_fcnt       <= 4'd0;
            S_len        <= 32'd0;
            S_aud_n      <= 16'd0;
            S_aud_i      <= 16'd0;
            S_frames     <= 32'd0;
            S_aud_lo     <= 1'b0;
            S_aud_hi     <= 8'd0;
            S_pix        <= 8'd0;
            S_left       <= 12'd0;
            S_rep        <= 1'b0;
            S_tok        <= 16'd0;
            S_x          <= 9'd0;
            S_tx         <= 10'd0;
            S_pass       <= 1'b0;
            O_wr_load    <= 1'b0;
            O_pg_done    <= 1'b0;
            O_pg_page    <= 1'b0;
            O_clip_end   <= 1'b0;
            O_frame_cnt  <= 16'd0;
            O_st         <= V_WAIT;
            O_err        <= 3'd0;
            O_aud_we     <= 1'b0;
            O_aud_data   <= 16'd0;
            S_vbyt       <= 32'd0;
            S_px         <= 32'd0;
            S_rows       <= 9'd0;
            S_endv       <= 32'd0;
            S_endv_cap   <= 1'b0;
            S_pend       <= 32'd0;
            S_skip       <= 32'd0;
            S_hdrb       <= 32'd0;
            S_align_b    <= 1'b0;
        end else begin
            O_st         <= S_st;
            O_wr_load    <= 1'b0;
            O_aud_we     <= 1'b0;
            O_pg_done    <= 1'b0;
            O_clip_end   <= 1'b0;

            if (W_consume) S_vbyt <= S_vbyt + 32'd1;

            case (S_st)
            //------------------------------------------------- start
            V_WAIT: begin
                if (I_sdram_ready) begin
                    O_wr_load <= 1'b1;
                    S_st      <= V_HDR_M;
                end
            end
            //------------------------------------------------- header resync
            V_HDR_M: begin
                if (I_byte_valid && I_byte == 8'h4D) S_st <= V_HDR_5;
            end
            V_HDR_5: begin
                if (I_byte_valid) S_st <= (I_byte == 8'h35) ? V_HDR_V : V_HDR_M;
            end
            V_HDR_V: begin
                if (I_byte_valid) S_st <= (I_byte == 8'h56) ? V_HDR_1 : V_HDR_M;
            end
            V_HDR_1: begin
                if (I_byte_valid) begin
                    if (I_byte == 8'h31) begin
                        S_hdr  <= {S_hdr[247:0], I_byte};
                        S_hcnt <= 8'd1;
                        S_st   <= V_HDR_R;
                    end else
                        S_st <= V_HDR_M;
                end
            end
            V_HDR_R: begin
                if (I_byte_valid) begin
                    S_hdr  <= {S_hdr[247:0], I_byte};
                    S_hcnt <= S_hcnt + 8'd1;
                    if (S_hcnt == 8'd28) begin
                        // This byte is file byte 31, so the whole 32 byte header
                        // has been consumed and S_hdr holds its bytes 3..31
                        // (29 bytes): byte 3 at [231:224] and byte i at
                        // [8*(31-i)+7 : 8*(31-i)].
                        //   bpp    file bytes 10,11 -> S_hdr[175:160]
                        //   frames file bytes 12..15 -> S_hdr[159:128]
                        // S_bpp_b is the bpp field for the (buggy) case that only
                        // 28 bytes were latched; accepting it makes a one byte
                        // short header parse recoverable instead of looping in
                        // the resync state forever.
                        if (S_bpp_a == 16'd1) begin
                            S_align_b <= 1'b0;
                            S_frames  <= S_fr_n;
                            S_st      <= V_FRAME;
                        end else if (S_bpp_b == 16'd1) begin
                            S_align_b <= 1'b1;
                            S_frames  <= S_fr_n;
                            S_st      <= V_ALIGN1;      // swallow leftover byte
                        end else begin
                            O_err <= 3'd1;              // not a RGB332 M5V1
                            S_st  <= V_HDR_M;
                        end
                    end
                end
            end
            //------------------------------------------------- one byte realign
            V_ALIGN1: begin
                if (I_byte_valid) begin
                    S_fcnt <= 4'd0;
                    S_fhdr <= 64'd0;
                    S_st   <= V_FRAME;
                end
            end
            //------------------------------------------------- frame boundary
            V_FRAME: begin
                if (S_tmr_wrap) begin
                    S_fcnt  <= 4'd0;
                    S_fhdr  <= 64'd0;
                    S_hdrb  <= 32'd0;
                    S_st    <= V_FHDR;
                end
            end
            V_FHDR: begin
                if (I_byte_valid) begin
                    S_fhdr <= {S_fhdr[55:0], I_byte};
                    if (S_fcnt < 4'd4) S_hdrb <= {S_hdrb[23:0], I_byte};
                    S_fcnt <= S_fcnt + 4'd1;
                    if (S_fcnt == 4'd7) begin
                        // S_fhdr holds bytes b0..b6 (b0 in bits 55:48), I_byte b7
                        S_len   <= S_len_w;
                        S_aud_n <= (S_fhdr[23:8] > 16'd8000) ? 16'd0
                                                           : S_fhdr[23:8];
                        S_aud_i <= 16'd0;
                        S_x     <= 9'd0;
                        S_px    <= 32'd0;
                        S_rows  <= 9'd0;
                        if ((S_len_w < 32'd256) || (S_len_w > 32'd65535)) begin
                            O_err <= 3'd4;      // frame block header out of range
                            S_st  <= V_HDR_M;   // resync on the next "M5V1"
                        end else
                            S_st <= V_PEND;     // one more cycle for the adder
                    end
                end
            end
            //------------------------------------------------- payload end pointer
            // computed in its own state so the 32 bit adder is not stacked on top
            // of the state decode / byte handshake (100 MHz timing)
            V_PEND: begin
                S_pend <= S_vbyt + S_len;
                S_st   <= V_TOKEN0;
            end
            //------------------------------------------------- RLE tokens
            V_TOKEN0: begin
                if (I_byte_valid) begin
                    S_tok[15:8] <= I_byte;
                    S_st        <= V_TOKEN1;
                end
            end
            V_TOKEN1: begin
                if (I_byte_valid) begin
                    S_tok[7:0] <= I_byte;
                    S_st       <= V_PARSE;
                end
            end
            V_PARSE: begin
                if (S_tok[15:12] == 4'd0) begin
                    // end of this frame's payload
                    S_aud_i  <= 16'd0;
                    S_aud_lo <= 1'b0;
                    // a well formed frame is 240 source rows ; anything else
                    // means the RLE stream desynced (bring-up warning only, the
                    // frame framing itself comes from S_len)
                    if (S_rows != 9'd240) O_err <= 3'd2;
                    if (!S_endv_cap) begin S_endv <= S_vbyt_nx; S_endv_cap <= 1'b1; end
                    if (S_vbyt_nx < S_pend) begin
                        // end token arrived early: discard the rest of the block
                        // payload so the next frame header lands on a boundary
                        S_skip <= S_pend - S_vbyt_nx;
                        S_st   <= V_PSKIP;
                    end else
                        S_st <= (S_aud_n != 16'd0) ? V_AUDIO : V_DONE;
                end else if (S_vbyt_nx >= S_pend) begin
                    // payload complete but the end token never showed up
                    O_err    <= 3'd5;
                    S_aud_i  <= 16'd0;
                    S_aud_lo <= 1'b0;
                    if (!S_endv_cap) begin S_endv <= S_vbyt_nx; S_endv_cap <= 1'b1; end
                    S_st <= (S_aud_n != 16'd0) ? V_AUDIO : V_DONE;
                end else begin
                    S_left <= S_cnt + 12'd1;
                    S_rep  <= (S_tok[15:12] == 4'd1);
                    S_st   <= (S_tok[15:12] == 4'd1) ? V_REPPIX : V_WRITE;
                end
            end
            //------------------------------------------------- payload discard
            V_PSKIP: begin
                if (I_byte_valid) begin
                    S_skip <= S_skip - 32'd1;
                    if (S_skip == 32'd1)
                        S_st <= (S_aud_n != 16'd0) ? V_AUDIO : V_DONE;
                end
            end
            V_REPPIX: begin
                if (I_byte_valid) begin
                    S_pix <= I_byte;
                    S_st  <= V_WRITE;
                end
            end
            V_WRITE: begin
                if (S_rep) begin
                    // no bytes to consume, just replicate
                    S_row[S_x] <= S_pix;
                    S_px       <= S_px + 32'd1;
                    S_x        <= S_x + 9'd1;
                    S_left     <= S_left - 12'd1;
                    if (S_x == 9'd319) begin
                        S_x    <= 9'd0;
                        S_tx   <= 10'd0;
                        S_pass <= 1'b0;
                        S_st   <= V_EMIT;
                    end else if (S_left == 12'd1) begin
                        S_st <= V_TOKEN0;
                    end
                end else begin
                        if (I_byte_valid) begin
                        S_row[S_x] <= I_byte;
                        S_px       <= S_px + 32'd1;
                        S_x        <= S_x + 9'd1;
                        S_left     <= S_left - 12'd1;
                        if (S_x == 9'd319) begin
                            S_x    <= 9'd0;
                            S_tx   <= 10'd0;
                            S_pass <= 1'b0;
                            S_st   <= V_EMIT;
                        end else if (S_left == 12'd1) begin
                            S_st <= V_TOKEN0;
                        end
                    end
                end
            end
            //------------------------------------------------- emit two rows
            V_EMIT: begin
                if (!I_wr_full) begin
                    if (S_tx == 10'd639) begin
                        S_tx <= 10'd0;
                        if (S_pass == 1'b0)
                            S_pass <= 1'b1;
                        else begin
                            S_pass <= 1'b0;
                            S_rows <= S_rows + 9'd1;
                            S_st   <= (S_left != 12'd0) ? V_WRITE : V_TOKEN0;
                        end
                    end else
                        S_tx <= S_tx + 10'd1;
                end
            end
            //------------------------------------------------- audio chunk
            //  The encoder (tools/m6_encode.py) extracts the soundtrack with
            //  ffmpeg "-f s16le", i.e. the frame audio is LITTLE endian:
            //  first byte = LSB, second byte = MSB.  Assembling it big endian
            //  byte swaps every sample, which turns music into full scale noise
            //  (that was the "very loud gibberish" on the monitor speaker).
            V_AUDIO: begin
                if (I_byte_valid) begin
                    if (!S_aud_lo) begin
                        S_aud_hi <= I_byte;         // first byte = low byte
                        S_aud_lo <= 1'b1;
                    end else begin
                        O_aud_we   <= 1'b1;
                        O_aud_data <= {I_byte, S_aud_hi};   // {MSB, LSB}
                        S_aud_lo   <= 1'b0;
                    end
                    S_aud_i <= S_aud_i + 16'd1;
                    if ((S_aud_i + 16'd1) >= {S_aud_n, 1'b0}) S_st <= V_DONE;
                end
            end
            //------------------------------------------------- frame done
            V_DONE: begin
                O_pg_done <= 1'b1;
                O_pg_page <= I_start_page ^ O_frame_cnt[0];
                if ((O_frame_cnt + 16'd1) >= S_frames[15:0]) begin
                    //  end of the clip: the stream loops back to the file header,
                    //  so the decoder must resync on "M5V1" instead of reading
                    //  the next frame block header.  M6 additionally reports it,
                    //  the playlist uses it to step to the next item; the
                    //  decoder keeps running (and looping) until m6_top freezes
                    //  or resets it, so the last frame stays on screen.
                    O_clip_end  <= 1'b1;
                    O_frame_cnt <= 16'd0;
                    S_st        <= V_HDR_M;
                end else begin
                    O_frame_cnt <= O_frame_cnt + 16'd1;
                    S_st        <= V_FRAME;
                end
            end
            default: S_st <= V_WAIT;
            endcase
        end
    end

endmodule
