//=============================================================================
//  m5_i2c_scan.v  --  I2C bus scanner (M4 audio bring-up, DEBUG_AUDIO == 2)
//
//  Why
//  ---
//  The audio codec never acknowledges its I2C address: 0x34 (WM8960) and 0x20
//  (ES8388 with CE low) both NACKed, the audio PLL is locked and the bit engine
//  sends a textbook START / byte / ACK / STOP frame.  Before touching the
//  register table again, find out whether the shared bus answers at ANY address.
//
//  The board schematic (02_AUDIO.SchDoc) shows the codec is an ES8388 at
//  7 bit address 0x10 (CE low, 8 bit write 0x20) or 0x11 (CE high, 0x22) and
//  that the same two wires (SCL = L16, SDA = M16) also carry a 24LC256 EEPROM
//  (0x50) and a PCF8563 RTC (0x51).  The EEPROM and the RTC answer a plain
//  address probe without any initialisation, so:
//
//      EEPROM/RTC ACK  ->  the FPGA I2C master + pins are fine, the codec is
//                          the problem (not fitted / unpowered / SPI mode / CE)
//      nothing ACKs    ->  the bus, the pins or the pull ups are the problem
//
//  What it does
//  ------------
//    * 50 ms after reset, captures the idle level of SDA (released: expect 1)
//    * probes the 7 bit addresses 127..0 with   START | {addr,0} | ACK? | STOP
//      (40 kHz SCL, ~1.1 ms per address, 140 ms for the whole range)
//    * prints the result as plain ASCII on the CH340E UART (115200 8N1):
//            #SDA=1              idle level, printed once
//            #10:1               address 0x10 acknowledged
//            #7F:0               address 0x7F did not answer
//      i.e. 8 + 128*7 = 904 characters, ~78 ms, repeated every ~0.67 s, so the
//      PC never has to listen at the exact moment of the reset.
//
//  The two status LEDs driven by the top level are the fast read-out:
//      led3 = a full scan has completed, led2 = any address ACKed,
//      led1 = 0x10 / 0x11 / 0x1A ACKed, led0 = scan running
//=============================================================================
`timescale 1ns / 10ps

module m5_i2c_scan #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115200
)(
    input  wire I_clk,
    input  wire I_rst,          // synchronous, high active

    // I2C pins (tri-state handled by the top level)
    output wire O_scl,
    output wire O_sda_o,
    output wire O_sda_oe,
    input  wire I_sda_i,

    output reg  O_uart_tx,      // 115200 8N1, idle high

    output reg  O_busy,
    output reg  O_done,         // 1 after the first complete scan
    output reg  O_any_ack,
    output reg  O_codec_ack     // 0x10 / 0x11 / 0x1A answered
);

    localparam integer DIV = CLK_HZ / BAUD;         // 434 for 50 MHz / 115200

    //-------------------------------------------------------------------------
    // bit level engine (same one the real initialiser uses)
    //-------------------------------------------------------------------------
    reg        S_go;
    reg  [2:0] S_cmd;
    reg  [7:0] S_tx;
    wire       S_bdone;
    wire       S_bnack;

    m5_i2s_bit_shift #(
        .SYS_CLOCK (CLK_HZ),
        .SCL_CLOCK (40_000)
    ) u_bit (
        .I_clk     (I_clk),
        .I_rst     (I_rst),
        .I_go      (S_go),
        .I_cmd     (S_cmd),
        .I_tx_data (S_tx),
        .O_rx_data (),
        .O_nack    (S_bnack),
        .O_done    (S_bdone),
        .O_scl     (O_scl),
        .O_sda_o   (O_sda_o),
        .O_sda_oe  (O_sda_oe),
        .I_sda_i   (I_sda_i)
    );

    //-------------------------------------------------------------------------
    // 8N1 transmitter registers (declared before the sequencer that uses them)
    //-------------------------------------------------------------------------
    reg        S_busy;
    reg [15:0] S_bcnt;
    reg [3:0]  S_bidx;
    reg [7:0]  S_lat;

    //-------------------------------------------------------------------------
    // scan sequencer
    //-------------------------------------------------------------------------
    localparam [2:0] P_POR   = 3'd0,
                     P_CAP   = 3'd1,
                     P_ISSUE = 3'd2,
                     P_WAIT  = 3'd3,
                     P_REP   = 3'd4,
                     P_REPW1 = 3'd5,    // wait for the transmitter to get busy
                     P_REPW2 = 3'd6,    // wait for the character to finish
                     P_HOLD  = 3'd7;

    localparam [18:0] POR_CLKS  = 19'd2_500_000;    // 50 ms at 50 MHz
    localparam [24:0] HOLD_CLKS = 25'd20_000_000;   // 400 ms between passes

    reg [2:0]   P_st;
    reg [18:0]  P_por;
    reg [24:0]  P_hold;
    reg [6:0]   P_addr;
    reg [127:0] P_ack;          // bit n = 7 bit address n acknowledged
    reg         P_sda_idle;

    // report counters
    reg         P_phase;        // 0 = header, 1 = address lines
    reg [2:0]   P_hdr;          // 0..7 header character index
    reg [6:0]   P_r;            // address being printed
    reg [2:0]   P_m;            // 0..6 field inside one address line

    wire [127:0] W_next = {P_ack[126:0], ~S_bnack};

    //-------------------------------------------------------------------------
    // character to send
    //-------------------------------------------------------------------------
    function [7:0] hexch;
        input [3:0] n;
        begin
            hexch = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
        end
    endfunction

    reg [7:0] W_chr;
    always @(*) begin
        if (P_phase == 1'b0) begin
            case (P_hdr)
            3'd0: W_chr = 8'h23;                    // '#'
            3'd1: W_chr = 8'h53;                    // 'S'
            3'd2: W_chr = 8'h44;                    // 'D'
            3'd3: W_chr = 8'h41;                    // 'A'
            3'd4: W_chr = 8'h3D;                    // '='
            3'd5: W_chr = P_sda_idle ? 8'h31 : 8'h30;
            3'd6: W_chr = 8'h0D;
            default: W_chr = 8'h0A;
            endcase
        end
        else begin
            case (P_m)
            3'd0: W_chr = 8'h23;                    // '#'
            3'd1: W_chr = hexch({1'b0, P_r[6:4]});
            3'd2: W_chr = hexch(P_r[3:0]);
            3'd3: W_chr = 8'h3A;                    // ':'
            3'd4: W_chr = P_ack[P_r] ? 8'h31 : 8'h30;
            3'd5: W_chr = 8'h0D;
            default: W_chr = 8'h0A;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // sequencer
    //-------------------------------------------------------------------------
    reg S_txen;     // 1 cycle pulse: start sending S_chr
    reg [7:0] S_chr;

    always @(posedge I_clk) begin
        if (I_rst) begin
            P_st       <= P_POR;
            P_por      <= 19'd0;
            P_hold     <= 25'd0;
            P_addr     <= 7'd127;
            P_ack      <= 128'd0;
            P_sda_idle <= 1'b1;
            P_phase    <= 1'b0;
            P_hdr      <= 3'd0;
            P_r        <= 7'd0;
            P_m        <= 3'd0;
            S_go       <= 1'b0;
            S_cmd      <= 3'b000;
            S_tx       <= 8'd0;
            S_txen     <= 1'b0;
            S_chr      <= 8'd0;
            O_busy     <= 1'b0;
            O_done     <= 1'b0;
            O_any_ack  <= 1'b0;
            O_codec_ack<= 1'b0;
        end
        else begin
            S_go   <= 1'b0;
            S_txen <= 1'b0;

            case (P_st)
            //----------------------------------------------------- power on wait
            P_POR: begin
                if (P_por == POR_CLKS) begin
                    P_por <= 19'd0;
                    P_st  <= P_CAP;
                end
                else
                    P_por <= P_por + 19'd1;
            end
            //----------------------------------------------------- capture + start
            P_CAP: begin
                P_sda_idle <= I_sda_i;
                P_addr     <= 7'd127;
                P_ack      <= 128'd0;
                O_busy     <= 1'b1;
                P_st       <= P_ISSUE;
            end
            //----------------------------------------------------- probe address
            P_ISSUE: begin
                S_cmd <= 3'b111;                    // START + WRITE + STOP
                S_tx  <= {P_addr, 1'b0};            // 7 bit address, W
                S_go  <= 1'b1;
                P_st  <= P_WAIT;
            end
            P_WAIT: begin
                if (S_bdone) begin
                    P_ack <= W_next;
                    if (P_addr == 7'd0) begin
                        O_busy      <= 1'b0;
                        O_done      <= 1'b1;
                        O_any_ack   <= |W_next;
                        O_codec_ack <= W_next[7'h10] | W_next[7'h11] | W_next[7'h1A];
                        P_phase     <= 1'b0;
                        P_hdr       <= 3'd0;
                        P_r         <= 7'd0;
                        P_m         <= 3'd0;
                        P_st        <= P_REP;
                    end
                    else begin
                        P_addr <= P_addr - 7'd1;
                        P_st   <= P_ISSUE;
                    end
                end
            end
            //----------------------------------------------------- print pass
            P_REP: begin
                if (!S_busy) begin
                    S_chr  <= W_chr;
                    S_txen <= 1'b1;
                    P_st   <= P_REPW1;
                end
            end
            P_REPW1: begin
                if (S_busy) P_st <= P_REPW2;
            end
            P_REPW2: begin
                if (!S_busy) begin
                    if (P_phase == 1'b0) begin
                        if (P_hdr == 3'd7) begin
                            P_phase <= 1'b1;
                            P_r     <= 7'd0;
                            P_m     <= 3'd0;
                        end
                        else
                            P_hdr <= P_hdr + 3'd1;
                        P_st <= P_REP;
                    end
                    else begin
                        if (P_m == 3'd6) begin
                            P_m <= 3'd0;
                            if (P_r == 7'd127) begin
                                P_hold <= 25'd0;
                                P_st   <= P_HOLD;
                            end
                            else begin
                                P_r <= P_r + 7'd1;
                                P_st <= P_REP;
                            end
                        end
                        else begin
                            P_m <= P_m + 3'd1;
                            P_st <= P_REP;
                        end
                    end
                end
            end
            //----------------------------------------------------- wait and repeat
            P_HOLD: begin
                if (P_hold == HOLD_CLKS) begin
                    P_hold <= 25'd0;
                    P_st   <= P_CAP;
                end
                else
                    P_hold <= P_hold + 25'd1;
            end
            default: P_st <= P_POR;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // 8N1 transmitter (same structure as m5_dbg_uart)
    //-------------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (I_rst) begin
            O_uart_tx <= 1'b1;
            S_busy    <= 1'b0;
            S_bcnt    <= 16'd0;
            S_bidx    <= 4'd0;
            S_lat     <= 8'h00;
        end
        else if (!S_busy) begin
            O_uart_tx <= 1'b1;
            if (S_txen) begin
                S_lat     <= S_chr;
                S_busy    <= 1'b1;
                S_bcnt    <= 16'd0;
                S_bidx    <= 4'd0;
                O_uart_tx <= 1'b0;              // start bit
            end
        end
        else if (S_bcnt == (DIV - 1)) begin
            S_bcnt <= 16'd0;
            if (S_bidx == 4'd9) begin
                S_busy    <= 1'b0;
                O_uart_tx <= 1'b1;
            end
            else begin
                S_bidx    <= S_bidx + 4'd1;
                O_uart_tx <= (S_bidx == 4'd8) ? 1'b1 : S_lat[S_bidx];
            end
        end
        else
            S_bcnt <= S_bcnt + 16'd1;
    end

endmodule
