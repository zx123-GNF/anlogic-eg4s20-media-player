`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:18:48
// Design Name: 
// Module Name: bcd_to_hex
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
module bcd_to_hex #(parameter bcd_bit = 8, hex_bit = 4) (
    output reg         [hex_bit - 1:0]  hex                        ,
    input              [bcd_bit - 1:0]  bcd                         
);

    integer                             i,                       j;
    reg                [bcd_bit - 1:0]  temp_bcd                   ;

    always @ (bcd) begin
        temp_bcd = bcd;
        hex = 0;
        for (i = 0; i < hex_bit; i = i + 1) begin
            hex[i] = temp_bcd[0];
            temp_bcd = temp_bcd >> 1;
            for (j = bcd_bit - 4; j >= 0; j = j - 4) begin
                if (temp_bcd[j+:4] > 7)
                    temp_bcd[j+:4] = temp_bcd[j+:4] - 3;
            end
        end
    end
endmodule
