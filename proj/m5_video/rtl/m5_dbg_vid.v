//=============================================================================
//  m5_dbg_vid.v  --  ASCII status line for the M5 video path (CH340E UART)
//
//  The board has no onboard USB-serial bridge, so this line is only useful with
//  an external CH340E cable on the UART pin.  It prints one line every ~0.5 s:
//
//      V<sst> <vst> <err> <mnt> <frm> <vbyt> <vpx> <audn> <len> <byt>
//      <chk> <first> <lba> <size> <eof>\r\n
//
//  All values are hex, MSB first, fixed width:
//      sst   : 2   streamer FSM state (T_* encoding of rtl/m5_stream.v)
//      vst   : 2   decoder FSM state  (V_* encoding of rtl/m5_vdec.v)
//      err   : 2   combined error code (streamer or decoder)
//      mnt   : 1   card mounted / FAT32 accepted
//      frm   : 4   frames displayed
//      vbyt  : 8   bytes consumed by the decoder
//      vpx   : 8   pixels written in the current frame
//      audn  : 4   audio samples of the last frame block header
//      len   : 8   payload length of the last frame block header
//      byt   : 8   bytes delivered by the streamer
//      chk   : 8   first 4 stream bytes read back (4D4D4D4D = 'M' x4)
//      first : 8   first cluster of the file
//      lba   : 8   current sector LBA
//      size  : 8   file size in bytes
//      eof   : 1   streamer wrapped around to the start of the file
//
//  115200 8N1, LSB first, no flow control.
//=============================================================================
`timescale 1ns / 10ps

module m5_dbg_vid #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire        I_clk,
    input  wire        I_rst,

    input  wire [5:0]  I_sst,
    input  wire [5:0]  I_vst,
    input  wire [2:0]  I_err,
    input  wire        I_mnt,
    input  wire [15:0] I_frm,

    input  wire [31:0] I_vbyt,
    input  wire [31:0] I_vpx,
    input  wire [15:0] I_audn,
    input  wire [31:0] I_len,
    input  wire [31:0] I_byt,
    input  wire [31:0] I_chk,
    input  wire [31:0] I_first,
    input  wire [31:0] I_lba,
    input  wire [31:0] I_size,
    input  wire        I_eof,

    output reg         O_uart_tx
);

    //-------------------------------------------------------------------------
    // baud generator / byte transmitter
    //-------------------------------------------------------------------------
    localparam integer BAUD_DIV = CLK_HZ / BAUD;        // 434 @ 50 MHz

    reg  [15:0] S_baud;
    reg  [3:0]  S_bit;
    reg  [9:0]  S_shift;        // {stop, data[7:0], start}
    reg         S_txbusy;
    reg         S_bstart;
    reg  [7:0]  S_bdata;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_baud    <= 16'd0;
            S_bit     <= 4'd0;
            S_shift   <= 10'h3FF;
            S_txbusy  <= 1'b0;
            O_uart_tx <= 1'b1;
        end else if (!S_txbusy) begin
            O_uart_tx <= 1'b1;
            S_bit     <= 4'd0;
            if (S_bstart) begin
                S_shift   <= {1'b1, S_bdata, 1'b0};     // stop, data, start
                S_baud    <= 16'd0;
                S_txbusy  <= 1'b1;
                O_uart_tx <= 1'b0;                      // start bit
            end
        end else begin
            if (S_baud == BAUD_DIV - 1) begin
                S_baud <= 16'd0;
                if (S_bit == 4'd9) begin
                    S_txbusy  <= 1'b0;
                    O_uart_tx <= 1'b1;
                end else begin
                    S_shift   <= {1'b1, S_shift[9:1]};
                    O_uart_tx <= S_shift[1];
                    S_bit     <= S_bit + 4'd1;
                end
            end else
                S_baud <= S_baud + 16'd1;
        end
    end

    //-------------------------------------------------------------------------
    // report timer : one line every ~0.5 s
    //-------------------------------------------------------------------------
    localparam integer REPORT_DIV = CLK_HZ / 2;

    reg [25:0] S_rep;
    wire       S_rep_tick = (S_rep == REPORT_DIV - 1);

    always @(posedge I_clk) begin
        if (I_rst)           S_rep <= 26'd0;
        else if (S_rep_tick) S_rep <= 26'd0;
        else                 S_rep <= S_rep + 26'd1;
    end

    //-------------------------------------------------------------------------
    // field selector : value and nibble count of the current field
    //   fields 0..14 are printed with a trailing space, field 15 (eof) is the
    //   last one before CR/LF
    //-------------------------------------------------------------------------
    reg  [4:0]  S_fi;
    reg  [4:0]  S_ni;           // nibbles still to send in this field

    reg  [31:0] S_fval;
    reg  [4:0]  S_fnib;

    always @(*) begin
        S_fval = 32'd0;
        S_fnib = 5'd2;
        case (S_fi)
            5'd0:  begin S_fval = {26'd0, I_sst};   S_fnib = 5'd2; end
            5'd1:  begin S_fval = {26'd0, I_vst};   S_fnib = 5'd2; end
            5'd2:  begin S_fval = {29'd0, I_err};   S_fnib = 5'd2; end
            5'd3:  begin S_fval = {31'd0, I_mnt};   S_fnib = 5'd1; end
            5'd4:  begin S_fval = {16'd0, I_frm};   S_fnib = 5'd4; end
            5'd5:  begin S_fval = I_vbyt;           S_fnib = 5'd8; end
            5'd6:  begin S_fval = I_vpx;            S_fnib = 5'd8; end
            5'd7:  begin S_fval = {16'd0, I_audn};  S_fnib = 5'd4; end
            5'd8:  begin S_fval = I_len;            S_fnib = 5'd8; end
            5'd9:  begin S_fval = I_byt;            S_fnib = 5'd8; end
            5'd10: begin S_fval = I_chk;            S_fnib = 5'd8; end
            5'd11: begin S_fval = I_first;          S_fnib = 5'd8; end
            5'd12: begin S_fval = I_lba;            S_fnib = 5'd8; end
            5'd13: begin S_fval = I_size;           S_fnib = 5'd8; end
            default: begin S_fval = {31'd0, I_eof}; S_fnib = 5'd1; end
        endcase
    end

    // hex digit -> ASCII
    function [7:0] hexa;
        input [3:0] d;
        begin
            hexa = (d < 4'd10) ? (8'h30 + {4'd0, d})
                               : (8'h57 + {4'd0, d});   // 'a' + d - 10
        end
    endfunction

    //-------------------------------------------------------------------------
    // line sequencer : one byte at a time, waits for the transmitter
    //-------------------------------------------------------------------------
    localparam [2:0]
        D_IDLE  = 3'd0,
        D_HDR   = 3'd1,     // 'V'
        D_FSTART= 3'd2,     // load the nibble counter of the current field
        D_DIGIT = 3'd3,     // send one hex digit
        D_SEP   = 3'd4,     // field separator, advance to the next field
        D_CR    = 3'd5,
        D_LF    = 3'd6,
        D_END   = 3'd7;

    reg [2:0] S_dst;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_dst    <= D_IDLE;
            S_bstart <= 1'b0;
            S_bdata  <= 8'd0;
            S_fi     <= 5'd0;
            S_ni     <= 5'd0;
        end else begin
            S_bstart <= 1'b0;
            case (S_dst)
            D_IDLE: begin
                if (S_rep_tick) begin
                    S_bdata  <= 8'h56;          // 'V'
                    S_bstart <= 1'b1;
                    S_fi     <= 5'd0;
                    S_dst    <= D_HDR;
                end
            end
            D_HDR: begin
                if (!S_txbusy && !S_bstart) S_dst <= D_FSTART;
            end
            D_FSTART: begin
                S_ni  <= S_fnib - 5'd1;
                S_dst <= D_DIGIT;
            end
            D_DIGIT: begin
                if (!S_txbusy && !S_bstart) begin
                    S_bdata  <= hexa((S_fval >> (4 * S_ni)) & 32'hF);
                    S_ni     <= S_ni - 5'd1;
                    S_bstart <= 1'b1;
                    if (S_ni == 5'd0) S_dst <= D_SEP;
                    else              S_dst <= D_DIGIT;
                end
            end
            D_SEP: begin
                if (!S_txbusy && !S_bstart) begin
                    if (S_fi < 5'd14) begin
                        S_bdata  <= 8'h20;      // space
                        S_bstart <= 1'b1;
                        S_fi     <= S_fi + 5'd1;
                        S_dst    <= D_FSTART;
                    end else
                        S_dst <= D_CR;
                end
            end
            D_CR: begin
                if (!S_txbusy && !S_bstart) begin
                    S_bdata  <= 8'h0D;
                    S_bstart <= 1'b1;
                    S_dst    <= D_LF;
                end
            end
            D_LF: begin
                if (!S_txbusy && !S_bstart) begin
                    S_bdata  <= 8'h0A;
                    S_bstart <= 1'b1;
                    S_dst    <= D_END;
                end
            end
            D_END: begin
                if (!S_txbusy && !S_bstart) S_dst <= D_IDLE;
            end
            default: S_dst <= D_IDLE;
            endcase
        end
    end

endmodule
