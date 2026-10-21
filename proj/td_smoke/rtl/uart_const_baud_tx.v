`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:21:22
// Design Name: 
// Module Name: uart_const_baud_tx
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
module uart_const_baud_tx #(parameter clock_freq = 100_000_000,baud_rate = 115200,baud_limit = clock_freq / baud_rate,limit_width = baud_limit > 0 ?  $clog2(baud_limit+1) : 1) (
    output reg                          tx                         ,
    output reg                          tx_done                    ,
    output                              tx_idle                    ,
    input                               tx_start                   ,
    input              [   7: 0]        tx_data                    ,
    input                               clk                        ,
    input                               rst                         
);
    
    localparam                          bit_num                   = 10    ; //1开始位 + 8数据位 + 1停止位
    
    localparam                          IDLE                      = 0     ;
    localparam                          SEND                      = 1     ;
    
    wire               [limit_width - 1:0]baud_cnt                 ;
    wire               [   3: 0]        bit_index                  ;
    wire                                tx_idle_logic              ;
    wire                                tx_done_logic              ;
    
    reg                                 send_en                    ;
    reg                [   8: 0]        tx_shift                   ;
    reg                                 state                      ;
    reg                                 cnt_rst                    ;
    
    assign                              tx_idle                   = state == IDLE ? 1 : 0;
    
    always @(posedge clk or posedge rst) begin
        if (rst)
            state <= IDLE;
        else
            case (state)
                IDLE:
                    if(tx_start)
                        state <= SEND;
                SEND:
                    if (send_cnt_done)
                        state <= IDLE;
                default:
                    state <= IDLE;
            endcase
    end
    
    always @(posedge clk or posedge rst) begin
        if (rst)
            tx_shift <= 9'b1_1111_1111;
        else
            case (state)
                IDLE:
                    if(tx_start)
                        tx_shift <= {1'b1, tx_data};
                    else
                        tx_shift <= 9'b1_1111_1111;
                SEND:
                    if (baud_cnt_done)
                        tx_shift <= {1'b1, tx_shift[8:1]};
                default:
                    tx_shift <= 9'b1_1111_1111;
            endcase
    end
    
    always @(posedge clk or posedge rst) begin
        if (rst)
            tx <= 1;
        else
            case (state)
                IDLE:
                    if(tx_start)
                        tx <= 0;
                    else
                        tx <= 1;
                SEND:
                    if (send_cnt_done)
                        tx <= 1;
                    else if (baud_cnt_done)
                        tx <= tx_shift[0];
                default:
                    tx <= 1;
            endcase
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            tx_done <= 0;
        else if(state == SEND && send_cnt_done)
            tx_done <= 1;
        else
            tx_done <= 0;
    end
    
    always @(*) begin
        if(rst)
            send_en <= 0;
        else if(baud_cnt_done)
            send_en <= 1;
        else
            send_en <= 0;
    end
    
    always @(*) begin
        if (rst)
            cnt_rst <= 1;
        else
            case (state)
                IDLE:
                    cnt_rst <= 1;
                SEND:
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
    .max_value                          (bit_num                   ) 
        ) CNT1
        (
    .cnt_value                          (bit_index                 ),
    .done                               (send_cnt_done             ),
    .cnt_en                             (send_en                   ),
    .clk                                (clk                       ),
    .rst                                (cnt_rst                   ) 
        );
endmodule
