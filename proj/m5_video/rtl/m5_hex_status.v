//=============================================================================
//  m5_hex_status.v
//  Map the player status onto the vendor HEX8 / HC595_Driver 7 segment chain.
//
//  The display is the board's 8 digit module driven by 2 x 74HC595.  The vendor
//  example (HEX_top = HEX8 + HC595_Driver) is proven on this board, so this
//  module only produces the 32 bit digit data, the digit enable mask and the
//  two mode signals; it contains no shift logic at all.
//
//  Digit layout (one BCD nibble per digit, nibble 0 = one end of the chain):
//
//      nibble  7  6 | 5  4 | 3  2  1  0
//            [count    ] [blank] [index+1   ]
//
//      e.g.  "0005  --  0002"  = 5 images indexed, currently showing #2
//      on error: "----  --  E<n>"  with n = the FAT error code
//
//  I_paused goes to HEX8's mode input, which lights the DP of the two end
//  digits ("pause" indicator).  The status inputs come from the 100 MHz
//  domain; they change at most once per page load, so they are re-registered
//  here in the 50 MHz display domain.
//=============================================================================
`timescale 1ns / 10ps

module m5_hex_status #(
    parameter BLANK_MIDDLE = 1      // switch digits 4..5 off (design uses them)
) (
    input  wire        I_clk,           // 50 MHz display domain
    input  wire        I_rst,

    input  wire        I_mounted,
    input  wire [2:0]  I_err,
    input  wire [4:0]  I_count,
    input  wire [4:0]  I_index,
    input  wire        I_busy,
    input  wire        I_paused,

    // bring-up: show I_dbg_data on all eight digits instead of the normal
    // E<n> / count+index layout
    input  wire        I_dbg_en,
    input  wire [31:0] I_dbg_data,

    output reg  [31:0] O_disp_data,
    output wire [7:0]  O_sw,            // digit enable mask, 0 = digit off
    output wire        O_mode           // HEX8 mode: 1 = DP on digits 3 / 7
);

    //-------------------------------------------------------------------------
    // binary -> BCD for the small ranges used here (0..16, 1..16)
    //-------------------------------------------------------------------------
    function [7:0] BCD2;                // {tens, ones}
        input [4:0] v;
        begin
            if (v >= 5'd10) BCD2 = {4'd1, (v[3:0] - 4'd10)};
            else            BCD2 = {4'd0, v[3:0]};
        end
    endfunction

    function [15:0] BCD4;               // {ones, tens, hundreds, thousands}
        input [4:0] v;
        begin
            if (v >= 5'd10) BCD4 = {12'd0, 4'd1, (v[3:0] - 4'd10)};
            else            BCD4 = {12'd0, v[3:0]};
        end
    endfunction

    reg        Q_mnt;
    reg [2:0]  Q_err;
    reg [4:0]  Q_count, Q_index;
    reg        Q_busy, Q_paused;

    always @(posedge I_clk) begin
        if (I_rst) begin
            Q_mnt    <= 1'b0;
            Q_err    <= 3'd0;
            Q_count  <= 5'd0;
            Q_index  <= 5'd0;
            Q_busy   <= 1'b0;
            Q_paused <= 1'b0;
        end else begin
            Q_mnt    <= I_mounted;
            Q_err    <= I_err;
            Q_count  <= I_count;
            Q_index  <= I_index;
            Q_busy   <= I_busy;
            Q_paused <= I_paused;
        end
    end

    wire [7:0]  W_cnt2 = BCD2(Q_count);
    wire [7:0]  W_idx2 = BCD2(Q_index + 5'd1);

    always @(*) begin
        if (I_dbg_en) begin
            O_disp_data = I_dbg_data;
        end else if (Q_err != 3'd0) begin
            // "E<n>": nibble1 = 'E', nibble0 = error code
            O_disp_data = {16'hFFFF, 4'hF, 4'hF, 4'hE, {1'b0, Q_err}};
        end else begin
            // digits 1..0 = index+1 (1..16), digits 7..6 = number of images,
            // digits 5..2 blanked by O_sw
            O_disp_data = {W_cnt2, 16'hFFFF, W_idx2};
        end
    end

    // digits 2..5 are not used: 1100_1100 disables them (1 = digit on)
    assign O_sw   = I_dbg_en ? 8'hFF
                  : (BLANK_MIDDLE ? 8'b1100_0011 : 8'hFF);
    assign O_mode = Q_paused;

endmodule
