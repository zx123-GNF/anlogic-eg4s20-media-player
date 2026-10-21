`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:14:33
// Design Name: 
// Module Name: string_param
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
module string_param #(parameter byte_num = 1,start_signal = "(",end_signal = ")",limit_width = byte_num > 0 ?  $clog2(byte_num) : 1) (
    output reg         [byte_num * 8 - 1 : 0]str_buf               ,
    output             [byte_num * 8 - 1 : 0]str_rank              ,
    output             [limit_width - 1:0]str_cnt                  ,
    output reg                          param_rec_done             ,
    input              [   7: 0]        str_in                     ,
    input                               rx_flag                    ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 0     ,
               SAVE = 1;
    
    reg                                 state                      ;
    reg                                 cnt_en,cnt_rst             ;
    reg                [limit_width - 1:0]rank_times               ;
    
    assign                              str_rank                  = str_buf >> (rank_times * 8);
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            state <= IDLE;
        else begin
            case(state)
                IDLE:
                    if(rx_flag && str_in == start_signal)
                        state <= SAVE;
                
                SAVE:
                    if(rx_flag && str_in == end_signal)
                        state <= IDLE;
            endcase
        end
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            rank_times <= 0;
        else if(state == SAVE && str_in != end_signal && rx_flag)
            rank_times <= str_cnt;
    end
    
    always@(*)
    begin
        if(rst)
            cnt_en <= 0;
        else if(state == SAVE && str_in != end_signal && rx_flag)
            cnt_en <= 1;
        else
            cnt_en <= 0;
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
            str_buf <= 0;
        else if(rx_flag) begin
            if(str_in == start_signal)
                str_buf <= 0;
            else if(state == SAVE && str_in != end_signal)
                str_buf[(str_cnt+1)*8-1-:8] <= str_in;
        end
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            param_rec_done <= 0;
        else if(state == SAVE && rx_flag && str_in == end_signal)
            param_rec_done <= 1;
        else
            param_rec_done <= 0;
    end
    
    cnt #(
    .dir                                (1                         ),
    .en                                 (1                         ),
    .limit                              (1                         ),
    .max_value                          (byte_num                  ) 
        ) CNT0
        (
    .cnt_value                          (str_cnt                   ),
    .cnt_en                             (cnt_en                    ),
    .clk                                (clk                       ),
    .rst                                (cnt_rst                   ) 
        );
    
endmodule
