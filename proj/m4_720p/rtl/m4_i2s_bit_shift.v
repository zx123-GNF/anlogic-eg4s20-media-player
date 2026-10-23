//=============================================================================
//  m4_i2s_bit_shift.v  --  bit level I2C engine (byte / START / STOP / ACK)
//
//  M4 milestone : WM8960 control port on the shared I2C bus (SCL = L16,
//  SDA = M16, shared with the 24LC256 EEPROM and the PCF8563 RTC - neither of
//  them is initialised by M4, so the bus is simply taken over).
//
//  This module is the M4 rewrite of the vendor file src/i2s_bit_shift.v.
//  The byte level protocol (START / 8 data bits / ACK / STOP, 4 phases per SCL
//  period, SCL = SYS_CLOCK/(4*SCL_DIV)) is unchanged - it is a correct I2C
//  master.  What changed:
//    * the tri-state SDA is split into oe / o / i (same idea as the vendor
//      src/function_pin.v) so that the ACK bit can be read back,
//    * O_nack is captured in the middle of the ACK bit and reported per byte,
//    * a clean "bus idle" state: SCL = 1, SDA released (high by pull-up),
//    * comments and a single 3 bit command port instead of the vendor's 6 bit
//      one-hot command.
//
//  Timing (SYS_CLOCK = 50 MHz, SCL_CLOCK = 40 kHz)
//      DIV        = 50e6/(40e3*4) = 312
//      SCL period = 4 * 312 * 20 ns = 24.96 us  ->  40.06 kHz  (vendor: 40 kHz)
//      one byte   = 9 SCL periods = 225 us
//      one register write = 3 bytes = 675 us   (13 registers -> 8.8 ms)
//=============================================================================
`timescale 1ns / 10ps

module m4_i2s_bit_shift #(
    parameter SYS_CLOCK = 50_000_000,   // I_clk frequency
    parameter SCL_CLOCK = 40_000        // SCL frequency (vendor used 40 kHz)
)(
    input  wire       I_clk,
    input  wire       I_rst,        // synchronous, high active

    // command interface
    input  wire       I_go,         // 1 cycle pulse, sampled while idle
    input  wire [2:0] I_cmd,        // bit0 = START, bit1 = WRITE byte, bit2 = STOP
    input  wire [7:0] I_tx_data,    // byte to send
    output reg  [7:0] O_rx_data,    // byte received (register read, unused in M4)
    output reg        O_nack,       // 1 = the slave did not acknowledge
    output reg        O_done,       // 1 cycle pulse, command finished

    // I2C pins (tri-state handled by the top level)
    output reg        O_scl,
    output reg        O_sda_o,
    output reg        O_sda_oe,
    input  wire       I_sda_i
);

    localparam [1:0] C_START = 2'd0,
                     C_WRITE = 2'd1,
                     C_STOP  = 2'd2;

    localparam [15:0] DIV = SYS_CLOCK / (SCL_CLOCK * 4);   // 312

    //-------------------------------------------------------------------------
    // baud rate divider : runs only while a command is in progress, so that the
    // first phase after I_go always gets a full SCL period
    //-------------------------------------------------------------------------
    reg [15:0] S_div;
    reg        S_busy;
    wire       S_tick = (S_div == (DIV - 1));

    always @(posedge I_clk) begin
        if (I_rst || !S_busy)
            S_div <= 16'd0;
        else if (S_tick)
            S_div <= 16'd0;
        else
            S_div <= S_div + 16'd1;
    end

    //-------------------------------------------------------------------------
    // sequencer
    //-------------------------------------------------------------------------
    reg [1:0] S_st;
    reg [1:0] S_ph;         // 0..3 phase inside one SCL period
    reg [3:0] S_bit;        // 0..7 data bits, 8 = ACK
    reg       S_hold;       // 1 = inside a frame, between two bytes : SCL held LOW

    // THE multi byte bug (found with the I2C bus scanner, 2026-10-23)
    // ---------------------------------------------------------------
    // A register write on the WM8960 is three bytes in ONE frame
    // (dev, reg+data8, data7:0).  After the ACK bit of a byte that is not the
    // last one this engine returned to the idle branch, which drives SCL = 1.
    // SCL was low at the end of the ACK phase, so the slave saw an extra rising
    // edge with SDA released (high) between every two bytes: the second and
    // third byte arrived one bit shifted and were refused -> NACK, "codec not
    // answering" - while a single byte probe (the scanner) worked fine.
    // Fix: keep SCL low between the bytes of a frame (S_hold), exactly like a
    // master that stretches the clock while it prepares the next byte.  The bus
    // only returns to the idle-high state after a STOP or an abort.

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st      <= C_START;
            S_ph      <= 2'd0;
            S_bit     <= 4'd0;
            S_busy    <= 1'b0;
            S_hold    <= 1'b0;
            O_scl     <= 1'b1;
            O_sda_o   <= 1'b1;
            O_sda_oe  <= 1'b0;
            O_nack    <= 1'b0;
            O_done    <= 1'b0;
            O_rx_data <= 8'd0;
        end
        else begin
            O_done <= 1'b0;

            if (!S_busy) begin
                //--------------------------------------------- bus idle / hold
                // S_hold : still inside a frame, waiting for the next byte.
                // Keep SCL LOW (no extra clock edge!) and SDA released.
                if (S_hold) begin
                    O_scl    <= 1'b0;
                    O_sda_oe <= 1'b0;
                    O_sda_o  <= 1'b1;
                end
                else begin
                    O_scl    <= 1'b1;
                    O_sda_oe <= 1'b0;
                    O_sda_o  <= 1'b1;
                end
                if (I_go) begin
                    S_busy <= 1'b1;
                    S_ph   <= 2'd0;
                    S_bit  <= 4'd0;
                    O_nack <= 1'b0;
                    S_hold <= 1'b0;
                    if (I_cmd[0])
                        S_st <= C_START;
                    else if (I_cmd[1])
                        S_st <= C_WRITE;
                    else if (I_cmd[2])
                        S_st <= C_STOP;
                    else begin
                        S_busy <= 1'b0;
                        O_done <= 1'b1;
                    end
                end
            end

            else if (S_tick) begin
                case (S_st)
                //----------------------------------------------------- START
                //  ph0 : SCL = 1, SDA = 1   (bus was idle high)
                //  ph1 : SDA = 0 while SCL = 1   -> START condition
                //  ph2 : SCL = 0
                //  ph3 : hold, then go to the first data byte
                C_START: begin
                    case (S_ph)
                    2'd0: begin O_scl <= 1'b1; O_sda_oe <= 1'b1; O_sda_o <= 1'b1; end
                    2'd1: begin O_scl <= 1'b1; O_sda_o <= 1'b0; end
                    2'd2: begin O_scl <= 1'b0; end
                    2'd3: begin O_scl <= 1'b0; end
                    endcase
                    if (S_ph == 2'd3) begin
                        S_ph <= 2'd0;
                        S_st <= C_WRITE;
                    end
                    else
                        S_ph <= S_ph + 2'd1;
                end
                //----------------------------------------------------- 8 bits + ACK
                //  ph0 : SCL = 0, SDA = data bit   (data changes while SCL low)
                //  ph1 : SCL = 1                   (slave samples SDA here)
                //  ph2 : SCL = 1                   (ACK: master samples SDA here)
                //  ph3 : SCL = 0
                C_WRITE: begin
                    case (S_ph)
                    2'd0: begin
                        O_scl <= 1'b0;
                        if (S_bit == 4'd8) begin
                            O_sda_oe <= 1'b0;           // release SDA for the ACK
                        end
                        else begin
                            O_sda_oe <= 1'b1;
                            O_sda_o  <= I_tx_data[3'd7 - S_bit[2:0]];
                        end
                    end
                    2'd1: begin O_scl <= 1'b1; end
                    2'd2: begin
                        O_scl <= 1'b1;
                        if (S_bit == 4'd8) begin
                            O_nack <= I_sda_i;          // 1 = not acknowledged
                        end
                        // (O_rx_data is not used: M4 only writes registers, so
                        //  SDA is driven by this master during the data bits.)
                    end
                    2'd3: begin O_scl <= 1'b0; end
                    endcase
                    if (S_ph == 2'd3) begin
                        S_ph <= 2'd0;
                        if (S_bit == 4'd8) begin
                            if (I_cmd[2]) begin
                                S_st   <= C_STOP;
                                S_hold <= 1'b0;
                            end
                            else begin
                                // end of a byte that is not the last one of the
                                // frame : hold SCL low until the next I_go
                                S_busy <= 1'b0;
                                O_done <= 1'b1;
                                S_hold <= 1'b1;
                                O_scl  <= 1'b0;
                                O_sda_oe <= 1'b0;
                            end
                        end
                        else begin
                            S_bit <= S_bit + 4'd1;
                        end
                    end
                    else
                        S_ph <= S_ph + 2'd1;
                end
                //----------------------------------------------------- STOP
                //  ph0 : SCL = 0, SDA = 0
                //  ph1 : SCL = 1
                //  ph2 : SDA released while SCL = 1  -> STOP condition
                //  ph3 : hold
                C_STOP: begin
                    case (S_ph)
                    2'd0: begin O_scl <= 1'b0; O_sda_oe <= 1'b1; O_sda_o <= 1'b0; end
                    2'd1: begin O_scl <= 1'b1; end
                    2'd2: begin O_scl <= 1'b1; O_sda_oe <= 1'b0; end
                    2'd3: begin O_scl <= 1'b1; O_sda_oe <= 1'b0; end
                    endcase
                    if (S_ph == 2'd3) begin
                        S_ph   <= 2'd0;
                        S_busy <= 1'b0;
                        S_hold <= 1'b0;
                        O_done <= 1'b1;
                    end
                    else
                        S_ph <= S_ph + 2'd1;
                end
                default: begin
                    S_busy <= 1'b0;
                    O_done <= 1'b1;
                end
                endcase
            end
        end
    end

endmodule
