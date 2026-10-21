`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:20:15
// Design Name: 
// Module Name: uart_const_baud_rx
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
module uart_const_baud_rx #(parameter clock_freq = 100_000_000,baud_rate = 115200,baud_limit = clock_freq / baud_rate / 2,baud_width = baud_limit > 0 ?  $clog2(baud_limit+1) : 1)(
    output reg         [   7: 0]        data                       ,
    output reg                          data_rec                   ,
    input                               rx                         ,
    input                               clr                        ,
    input                               clk                        ,
    input                               rst                         
);
    
    localparam                          bit_num                   = 9     ;
    
    localparam                          IDLE                      = 0     ;
    localparam                          RECEIVE                   = 1     ;
    
    reg                                 cnt_rst                    ;
    reg                [   0: 0]        state                    =IDLE;
    reg                [   7: 0]        data_temp                  ;
    
    wire               [baud_width-1: 0]baud_cnt                   ;
    wire               [   4: 0]        bit_index                  ;
    
    always@(posedge clk or posedge rst) begin
        if(rst)
            data_temp <= 8'b1111_1111;
        else if(baud_cnt_done && !bit_index[0])
            data_temp <= {rx,data_temp[7:1]};
    end
    
    always@(posedge clk or posedge rst) begin
        if(rst)
            data = 8'hff;
        else if(send_cnt_done)
            data = data_temp[7:0];
    end
    
    always@(posedge clk or posedge rst) begin
        if(rst)
            state <= IDLE;
        else if(state == IDLE & !rx)
                state <= RECEIVE;
        else if(state == RECEIVE & send_cnt_done)
            state <= IDLE;
    end
    
    always@(posedge clk or posedge rst) begin
        if(rst)
            data_rec <= 0;
        else if(send_cnt_done)
            data_rec <= 1;
        else if(clr)
            data_rec <= 0;
    end
    
    always @(posedge clk or posedge rst) begin
        if (rst)
            cnt_rst <= 1;
        else
            case (state)
                IDLE:
                    cnt_rst <= 1;
                RECEIVE:
                    cnt_rst <= 0;
                default:
                    cnt_rst <= 1;
            endcase
    end
    
    cnt #(
    .dir                                (0                         ),
    .max_value                          (baud_limit                ) 
        ) CNT0
        (
    .cnt_value                          (baud_cnt                  ),
    .done                               (baud_cnt_done             ),
    .clk                                (clk                       ),
    .rst                                (cnt_rst                   ) 
        );
        
    cnt #(
    .dir                                (0                         ),
    .en                                 (1                         ),
    .max_value                          (bit_num*2+1               ) 
        ) CNT1
        (
    .cnt_value                          (bit_index                 ),
    .done                               (send_cnt_done             ),
    .cnt_en                             (baud_cnt_done             ),
    .clk                                (clk                       ),
    .rst                                (cnt_rst                   ) 
        );
endmodule
