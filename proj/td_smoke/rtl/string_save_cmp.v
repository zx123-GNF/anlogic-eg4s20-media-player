`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:09:55
// Design Name: 
// Module Name: string_save_cmp
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
module string_save_cmp #(parameter byte_num = 1,byte_offset = 1,start_signal = ".",limit_width = byte_num > 0 ?  $clog2(byte_num) : 1) (
    output             [(byte_num + byte_offset) * 8 - 1 : 0]str_buf,
    output             [limit_width - 1:0]str_cnt                  ,
    output                              equal                      ,
    output                              greater                    ,
    output                              less                       ,
    input              [byte_num * 8 - 1 : 0]str_cmp               ,
    input              [   7: 0]        str_in                     ,
    input                               rx_flag                    ,
    input                               clk                        ,
    input                               rst                         
    );
    
    string_save #(.byte_num(byte_num + byte_offset),.start_signal(start_signal)) STR_SAVE0(
    .str_buf                            (str_buf                   ),
    .str_cnt                            (str_cnt                   ),
    .str_in                             (str_in                    ),
    .rx_flag                            (rx_flag                   ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
    string_compare #(.byte_num(byte_num)) STR_CMP0(
    .equal                              (equal                     ),
    .greater                            (greater                   ),
    .less                               (less                      ),
    .str_in0                            (str_buf[byte_offset*8+:byte_num*8]),
    .str_in1                            (str_cmp                   ) 
        );
        
endmodule
