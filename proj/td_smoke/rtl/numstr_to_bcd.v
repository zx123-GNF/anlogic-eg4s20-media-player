`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:17:54
// Design Name: 
// Module Name: numstr_to_bcd
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
module numstr_to_bcd #(parameter str_num = 1) (
    output reg         [str_num * 4 - 1 : 0]bcd                    ,
    input              [str_num * 8 - 1 : 0]numstr                  
    );
    
    integer                             i                          ;
    
    always@(*)
    begin
        for(i = 0; i < str_num;i = i + 1)
            bcd[i*4+:4] = numstr[i*8+:4];
    end
endmodule
