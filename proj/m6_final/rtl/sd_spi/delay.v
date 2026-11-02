`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:15:49
// Design Name: 
// Module Name: delay
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
//如果en为0，那么延时器的计时是一直生效的
//如果en为1，如果此时延时还未开始，则delay_start与delay_en均为高电平才可开始本次延时
//如果en为1，且此时在延时的过程中，则若delay_en不为高电平则延时过程暂停，
//直到delay_en再度恢复高电平，延时过程才会恢复（计数值会保留）
//如果var为0，那么延时周期为max_delay_cycle
//如果var为1，那么最大可设置延时周期为max_delay_cycle，并且由delay_cycle端口设置延时周期
//延时周期为延时持续的时钟周期
//由于var为system_verilog原语言，如使用system_verilog实例化本模块时
//可以用var_option参数代替var使用
module delay #(parameter max_delay_cycle = 100_000_000,en = 0,var_option = 0,var = var_option,cycle_width = max_delay_cycle > 0 ? $clog2(max_delay_cycle + 1) : 1)(
    output                              delay_done                 ,
    input              [cycle_width-1: 0]delay_cycle               ,
    input                               delay_start                ,
    input                               delay_en                   ,
    input                               clk                        ,
    input                               rst                         
);
    
    wire               [cycle_width-1: 0]cnt_value                 ;
    
    reg                                 cnt_en                     ;

    always@(*)
    begin
        if(en) begin
            if(cnt_empty)
                cnt_en <= delay_start & delay_en;
            else
                cnt_en <= delay_en;
        end
        else begin
            if(cnt_empty)
                cnt_en <= delay_start;
            else
                cnt_en <= 1;
        end
    end
    
    cnt #(
    .dir                                (0                         ),
    .en                                 (1                         ),
    .var                                (var                       ),
    .max_value                          (max_delay_cycle           ) 
        ) CNT0
        (
    .cnt_value                          (cnt_value                 ),
    .done                               (delay_done                ),
    .empty                              (cnt_empty                 ),
    .var_value                          (delay_cycle               ),
    .cnt_en                             (cnt_en                    ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
    
endmodule
