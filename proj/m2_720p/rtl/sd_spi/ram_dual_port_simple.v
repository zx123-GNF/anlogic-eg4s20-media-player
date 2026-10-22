`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:34:23
// Design Name: 
// Module Name: ram_dual_port_simple
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
module ram_dual_port_simple #(parameter data_width = 8,data_num = 16,num_width = data_num > 0 ? $clog2(data_num) : 1)(
    output reg         [data_width-1: 0]douta                      ,
    output reg         [data_width-1: 0]doutb                      ,
    input              [data_width-1: 0]dina                       ,
    input              [num_width-1: 0] addra                      ,
    input              [num_width-1: 0] addrb                      ,
    input                               wea                        ,
    input                               clka                       ,
    input                               clkb                        
    );
    
    reg                [data_width-1: 0]ram                 [0:data_num-1]  ;
    
    always@(posedge clka) begin
        douta <= ram[addra];
        if(wea)
            ram[addra] <= dina;
    end
    
    always@(posedge clkb) begin
        doutb <= ram[addrb];
    end
endmodule
