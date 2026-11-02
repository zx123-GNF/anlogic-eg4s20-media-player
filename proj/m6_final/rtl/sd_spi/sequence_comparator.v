`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:22:02
// Design Name: 
// Module Name: sequence_comparator
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
module sequence_comparator #(parameter width = 8,filt_sequence = 8'hff,default_value = 0)(
    output reg                          result                     ,
    input                               sequence_in                ,
    input                               clk                        ,
    input                               rst                         
    );
    
    reg                [width-2: 0]     sequence_shift             ;
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            sequence_shift <= default_value;
        else
            sequence_shift <= {sequence_shift[width-2:0],sequence_in};
    end
    
    always@(*)
    begin
        if(rst)
            result = 0;
        else if({sequence_shift[width-2:0],sequence_in} == filt_sequence)
            result = 1;
        else
            result = 0;
    end
endmodule
