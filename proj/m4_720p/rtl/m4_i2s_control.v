//=============================================================================
//  m4_i2s_control.v  --  byte level I2C sequencer for one WM8960 register write
//
//  M4 rewrite of the vendor file src/i2s_control.v.
//
//  THE important fix
//  -----------------
//  A WM8960 control word is 16 bits: B15..B9 = register address (7 bit),
//  B8..B0 = data (9 bit), sent as TWO data bytes after the device address
//  (datasheet page 63, figure 37):
//
//      START | dev+W | ACK | {reg[6:0], data[8]} | ACK | data[7:0] | ACK | STOP
//
//  The vendor sequencer runs with addr_mode = 0 and then jumps cnt 1 -> 3, so it
//  sends only ONE data byte.  The WM8960 ignores an incomplete control word,
//  i.e. the vendor table never configured the codec at all.  This module always
//  sends the full 3 byte frame and reports the ACK of every byte.
//
//  Device address
//  --------------
//  WM8960 7 bit address = 0011010 = 0x1A (datasheet page 63) -> the 8 bit write
//  byte is 0x34.  The vendor used 0x20 (an ES8388 address).  I_DEV is a port so
//  the address can be changed without touching this file.
//
//  Bus behaviour
//  -------------
//  A register write is atomic on the bus: START ... STOP.  When the sequencer is
//  idle the bus is released (SCL = 1, SDA = high impedance), so after
//  initialisation both lines stay idle-high as required.
//=============================================================================
`timescale 1ns / 10ps

module m4_i2s_control (
    input  wire       I_clk,
    input  wire       I_rst,

    // register write request (I_start is a 1 cycle pulse, the inputs are
    // sampled in the same cycle)
    input  wire       I_start,
    input  wire [7:0] I_dev,        // 8 bit write address, 0x34 for WM8960
    input  wire [6:0] I_reg,        // 7 bit register address
    input  wire [8:0] I_data,       // 9 bit register value

    output reg        O_busy,
    output reg        O_done,       // 1 cycle pulse
    output reg        O_nack,       // 1 = at least one byte was not acknowledged

    // I2C pins
    output wire       O_scl,
    output wire       O_sda_o,
    output wire       O_sda_oe,
    input  wire       I_sda_i
);

    localparam [2:0] CMD_START_WR = 3'b011,   // START + write byte
                     CMD_WR       = 3'b010,   // write byte (continue the frame)
                     CMD_WR_STOP  = 3'b110,   // write byte + STOP
                     CMD_STOP     = 3'b100;   // STOP only (abort path)

    localparam [2:0] S_IDLE    = 3'd0,
                     S_ISSUE   = 3'd1,
                     S_WAIT    = 3'd2,
                     S_STOP    = 3'd3,
                     S_WAITSTO = 3'd4,
                     S_DONE    = 3'd5;

    reg [2:0] S_st;
    reg [1:0] S_byte;       // 0 = device address, 1 = reg + data[8], 2 = data[7:0]
    reg [7:0] S_dev;
    reg [6:0] S_reg;
    reg [8:0] S_data;

    // to / from the bit engine
    reg        S_go;
    reg  [2:0] S_cmd;
    reg  [7:0] S_tx;
    wire       S_bdone;
    wire       S_bnack;

    //-------------------------------------------------------------------------
    // bit engine
    //-------------------------------------------------------------------------
    m4_i2s_bit_shift #(
        .SYS_CLOCK (50_000_000),
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
    // frame sequencer
    //-------------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st   <= S_IDLE;
            S_byte <= 2'd0;
            S_dev  <= 8'h34;
            S_reg  <= 7'd0;
            S_data <= 9'd0;
            S_go   <= 1'b0;
            S_cmd  <= 3'b000;
            S_tx   <= 8'd0;
            O_busy <= 1'b0;
            O_done <= 1'b0;
            O_nack <= 1'b0;
        end
        else begin
            S_go   <= 1'b0;     // default: 1 cycle pulse only
            O_done <= 1'b0;

            case (S_st)
            S_IDLE: begin
                O_busy <= 1'b0;
                if (I_start) begin
                    S_dev  <= I_dev;
                    S_reg  <= I_reg;
                    S_data <= I_data;
                    S_byte <= 2'd0;
                    O_nack <= 1'b0;
                    O_busy <= 1'b1;
                    S_st   <= S_ISSUE;
                end
            end

            S_ISSUE: begin
                S_go <= 1'b1;
                case (S_byte)
                2'd0: begin
                    S_cmd <= CMD_START_WR;
                    S_tx  <= S_dev;                     // 0x34 = 0x1A<<1 | W=0
                end
                2'd1: begin
                    S_cmd <= CMD_WR;
                    S_tx  <= {S_reg, S_data[8]};        // reg + data bit 8
                end
                default: begin
                    S_cmd <= CMD_WR_STOP;
                    S_tx  <= S_data[7:0];               // data bits 7..0 + STOP
                end
                endcase
                S_st <= S_WAIT;
            end

            S_WAIT: begin
                if (S_bdone) begin
                    if (S_bnack && (S_byte != 2'd2)) begin
                        // the codec is not answering: free the bus, do not send
                        // the remaining bytes, report the error
                        S_st <= S_STOP;
                    end
                    else if (S_byte == 2'd2) begin
                        if (S_bnack)
                            O_nack <= 1'b1;
                        S_st <= S_DONE;
                    end
                    else begin
                        S_byte <= S_byte + 2'd1;
                        S_st   <= S_ISSUE;
                    end
                end
            end

            S_STOP: begin
                S_go  <= 1'b1;
                S_cmd <= CMD_STOP;
                S_st  <= S_WAITSTO;
            end

            S_WAITSTO: begin
                if (S_bdone) begin
                    O_nack <= 1'b1;
                    S_st   <= S_DONE;
                end
            end

            S_DONE: begin
                O_busy <= 1'b0;
                O_done <= 1'b1;
                S_st   <= S_IDLE;
            end

            default: S_st <= S_IDLE;
            endcase
        end
    end

endmodule
