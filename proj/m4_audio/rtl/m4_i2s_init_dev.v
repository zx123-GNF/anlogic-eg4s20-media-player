//=============================================================================
//  m4_i2s_init_dev.v  --  WM8960 I2C initialisation sequencer (M4)
//
//  M4 rewrite of the vendor file src/i2s_init_dev.v.  Same job (walk a register
//  table once after power-up and stop), but:
//    * the table is m4_wm8960_table.v (13 reviewed entries with a delay column)
//      instead of the broken 40 entry ES8388/ WM8960 mix,
//    * every byte is ACK checked; a register is retried up to RETRY_MAX times
//      and the whole initialisation is aborted with O_ok = 0 if the codec never
//      answers (the tone generator is then held in reset, so the DACDAT pin
//      stays silent instead of outputting noise),
//    * a 10 ms power-on delay before the first write (the WM8960 needs its own
//      POR to finish; the vendor started after only 1.2 ms),
//    * per-register delays (1 ms / 10 ms / 100 ms / 500 ms) so that VMID can
//      charge before the output stages are enabled,
//    * O_busy / O_done / O_ok instead of a single Init_Done that was also used
//      as the "bus owner" mux signal.
//
//  Timings (50 MHz clock, 40 kHz SCL)
//      one register (3 bytes)  = 3 * 9 * 25 us       = 675 us
//      13 registers + delays   = 8.8 ms + 531 ms     = 540 ms
//      first write starts at   = 10 ms after reset release
//=============================================================================
`timescale 1ns / 10ps

module m4_i2s_init_dev #(
    parameter [19:0] POR_CLKS  = 20'd500_000,   // 10 ms at 50 MHz
    parameter [7:0]  DEV_ADDR  = 8'h34,         // WM8960 write address (0x1A << 1)
    parameter [1:0]  RETRY_MAX = 2'd3           // retries per register on NACK
)(
    input  wire I_clk,
    input  wire I_rst,          // synchronous, high active

    output reg  O_busy,
    output reg  O_done,         // 1 cycle pulse at the end (ok or not)
    output reg  O_ok,           // 1 = every register was acknowledged
    output reg  O_nack_err,     // 1 = at least one write was never acknowledged
    output reg  [4:0] O_index,  // register index for ChipWatcher debug

    // I2C pins (tri-state handled by the top level)
    output wire O_scl,
    output wire O_sda_o,
    output wire O_sda_oe,
    input  wire I_sda_i
);

    localparam [4:0] TABLE_LEN = 5'd13;

    localparam [2:0] S_POR   = 3'd0,
                     S_ISSUE = 3'd1,
                     S_WAIT  = 3'd2,
                     S_DELAY = 3'd3,
                     S_NEXT  = 3'd4,
                     S_OK    = 3'd5,
                     S_FAIL  = 3'd6;

    reg [2:0]  S_st;
    reg [4:0]  S_idx;
    reg [1:0]  S_retry;
    reg [19:0] S_por;           // 10 ms power-on counter
    reg [24:0] S_dly;           // register delay counter
    reg [2:0]  S_dly_code;

    reg        S_start;
    reg  [6:0] S_reg;
    reg  [8:0] S_data;
    wire       S_busy;
    wire       S_done;
    wire       S_nack;

    //-------------------------------------------------------------------------
    // register table
    //-------------------------------------------------------------------------
    wire [19:0] S_entry;
    wire [2:0]  S_entry_dly = S_entry[19:17];
    wire [7:0]  S_entry_reg = S_entry[16:9];
    wire [8:0]  S_entry_dat = S_entry[8:0];

    m4_wm8960_table u_table (
        .I_addr  (S_idx),
        .O_entry (S_entry)
    );

    //-------------------------------------------------------------------------
    // one register write (3 byte I2C frame, ACK checked)
    //-------------------------------------------------------------------------
    m4_i2s_control u_ctrl (
        .I_clk   (I_clk),
        .I_rst   (I_rst),
        .I_start (S_start),
        .I_dev   (DEV_ADDR),
        .I_reg   (S_reg),
        .I_data  (S_data),
        .O_busy  (S_busy),
        .O_done  (S_done),
        .O_nack  (S_nack),
        .O_scl   (O_scl),
        .O_sda_o (O_sda_o),
        .O_sda_oe(O_sda_oe),
        .I_sda_i (I_sda_i)
    );

    //-------------------------------------------------------------------------
    // delay select (datasheet: VMID charging, output stage settling)
    //-------------------------------------------------------------------------
    reg [24:0] S_dly_end;
    always @(*) begin
        case (S_dly_code)
        3'd0: S_dly_end = 25'd0;
        3'd1: S_dly_end = 25'd50_000;        //   1 ms
        3'd2: S_dly_end = 25'd500_000;       //  10 ms
        3'd3: S_dly_end = 25'd5_000_000;     // 100 ms
        3'd4: S_dly_end = 25'd25_000_000;    // 500 ms
        default: S_dly_end = 25'd0;
        endcase
    end

    //-------------------------------------------------------------------------
    // sequencer
    //-------------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st       <= S_POR;
            S_idx      <= 5'd0;
            S_retry    <= 2'd0;
            S_por      <= 20'd0;
            S_dly      <= 25'd0;
            S_dly_code <= 3'd0;
            S_start    <= 1'b0;
            S_reg      <= 7'd0;
            S_data     <= 9'd0;
            O_busy     <= 1'b0;
            O_done     <= 1'b0;
            O_ok       <= 1'b0;
            O_nack_err <= 1'b0;
            O_index    <= 5'd0;
        end
        else begin
            S_start <= 1'b0;        // 1 cycle pulse by default
            O_done  <= 1'b0;

            case (S_st)
            //--------------------------------------------------- power on delay
            S_POR: begin
                O_busy <= 1'b1;
                if (S_por != POR_CLKS) begin
                    S_por <= S_por + 20'd1;
                end
                else begin
                    S_idx   <= 5'd0;
                    S_retry <= 2'd0;
                    S_st    <= S_ISSUE;
                end
            end
            //--------------------------------------------------- start one write
            S_ISSUE: begin
                O_busy     <= 1'b1;
                O_index    <= S_idx;
                S_reg      <= S_entry_reg[6:0];
                S_data     <= S_entry_dat;
                S_dly_code <= S_entry_dly;
                S_start    <= 1'b1;
                S_st       <= S_WAIT;
            end
            //--------------------------------------------------- wait for ACK
            S_WAIT: begin
                if (S_done) begin
                    if (S_nack) begin
                        if (S_retry == RETRY_MAX) begin
                            O_nack_err <= 1'b1;
                            O_ok       <= 1'b0;
                            S_st       <= S_FAIL;
                        end
                        else begin
                            S_retry <= S_retry + 2'd1;
                            S_st    <= S_ISSUE;     // same register again
                        end
                    end
                    else begin
                        S_retry <= 2'd0;
                        S_dly   <= 25'd0;
                        S_st    <= S_DELAY;
                    end
                end
            end
            //--------------------------------------------------- post-write delay
            S_DELAY: begin
                if (S_dly >= S_dly_end) begin
                    S_st <= S_NEXT;
                end
                else begin
                    S_dly <= S_dly + 25'd1;
                end
            end
            //--------------------------------------------------- next register
            S_NEXT: begin
                if ((S_idx + 5'd1) >= TABLE_LEN) begin
                    O_ok <= 1'b1;
                    S_st <= S_OK;
                end
                else begin
                    S_idx <= S_idx + 5'd1;
                    S_st  <= S_ISSUE;
                end
            end
            //--------------------------------------------------- finished
            S_OK: begin
                O_busy <= 1'b0;
                O_done <= 1'b1;
            end
            S_FAIL: begin
                O_busy <= 1'b0;
                O_done <= 1'b1;
            end
            default: S_st <= S_POR;
            endcase
        end
    end

endmodule
