`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:34:57
// Design Name: 
// Module Name: clk_div_var
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
//div_width位宽一定要能覆盖到最大的div_value，
//比如最大分频值是3，转化为二进制是2'b11,那么div_width就是2
//one_allow为是否允许一分频，默认为1，是打开状态，
//如不需要用到一分频或者一分频逻辑影响跨时钟域，可设置为0关闭掉
module clk_div_var #(parameter div_width = 2,one_allow = 1) (
    output reg                          clk_out                    ,
    input              [div_width-1: 0] div_value                  ,
    input                               clk_in                     ,
    input                               rst                         
    );
    
    reg                [div_width-1: 0] cnt_value                  ;
    reg                                 clk_out_var                ;
    
    always@(*) begin
        if(one_allow == 1)
        begin
            if(div_value == 1)
                clk_out <= clk_in;
            else
                clk_out <= clk_out_var;
        end
        else
            clk_out <= clk_out_var;
    end
    
    always@(posedge clk_in or posedge rst)
    begin
        if(rst)
            clk_out_var <= 1;
        else if(cnt_value < div_value / 2)
            clk_out_var <= 1;
        else
            clk_out_var <= 0;
    end
    
    always@(negedge clk_in or posedge rst)
    begin
        if(rst)
            cnt_value <= 0;
         else if(cnt_value == div_value - 1)
            cnt_value <= 0;
        else
            cnt_value <= cnt_value + 1;
    end
endmodule
