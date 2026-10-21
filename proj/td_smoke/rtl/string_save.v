`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:10:59
// Design Name: 
// Module Name: string_save
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
module string_save #(parameter byte_num = 1,start_signal = ".",limit_width = byte_num > 0 ?  $clog2(byte_num) : 1) (
    output             [byte_num * 8 - 1 : 0]str_buf               ,
    output             [limit_width - 1:0]str_cnt                  ,
    input              [   7: 0]        str_in                     ,
    input                               rx_flag                    ,
    input                               clk                        ,
    input                               rst                         
    );
    
    reg                                 dp_en                      ;
    reg                                 cnt_rst                    ;
    reg                [byte_num * 8 - 1 : 0]str_temp              ;
    
    assign                              str_buf                   = dp_en ? str_temp : 0;
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            dp_en <= 0;
        else if(rx_flag && str_in == start_signal)
            dp_en <= 1;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            cnt_rst <= 1;
        else if(rx_flag && str_in == start_signal)
            cnt_rst <= 1;
        else
            cnt_rst <= 0;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            str_temp <= 0;
        else begin
            if(rx_flag) begin
                if(str_in == start_signal)
                    str_temp <= 0;
                else
                    str_temp[(str_cnt+1)*8-1-:8] <= str_in;
            end
        end
    end
    
    cnt #(
    .dir                                (1                         ),
    .en                                 (1                         ),
    .limit                              (1                         ),
    .max_value                          (byte_num                  ) 
        ) CNT0
        (
    .cnt_value                          (str_cnt                   ),
    .cnt_en                             (rx_flag                   ),
    .clk                                (clk                       ),
    .rst                                (cnt_rst                   ) 
        );
endmodule
