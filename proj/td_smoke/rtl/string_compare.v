`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:11:55
// Design Name: 
// Module Name: string_compare
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
module string_compare #(parameter byte_num = 1)(
    output reg                          equal                      ,
    output reg                          greater                    ,
    output reg                          less                       ,
    input              [byte_num * 8 - 1 : 0]str_in0               ,
    input              [byte_num * 8 - 1 : 0]str_in1                
    );
    
    always@(*) begin
        if(str_in0 == str_in1)
            {equal,greater,less} <= 3'b100;
        else if(str_in0 > str_in1)
            {equal,greater,less} <= 3'b010;
        else
            {equal,greater,less} <= 3'b001;
    end
endmodule
