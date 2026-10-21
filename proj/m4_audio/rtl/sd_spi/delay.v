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
//���enΪ0����ô��ʱ���ļ�ʱ��һֱ��Ч��
//���enΪ1�������ʱ��ʱ��δ��ʼ����delay_start��delay_en��Ϊ�ߵ�ƽ�ſɿ�ʼ������ʱ
//���enΪ1���Ҵ�ʱ����ʱ�Ĺ����У�����delay_en��Ϊ�ߵ�ƽ����ʱ������ͣ��
//ֱ��delay_en�ٶȻָ��ߵ�ƽ����ʱ���̲Ż�ָ�������ֵ�ᱣ���
//���varΪ0����ô��ʱ����Ϊmax_delay_cycle
//���varΪ1����ô����������ʱ����Ϊmax_delay_cycle��������delay_cycle�˿�������ʱ����
//��ʱ����Ϊ��ʱ������ʱ������
//����varΪsystem_verilogԭ���ԣ���ʹ��system_verilogʵ������ģ��ʱ
//������var_option��������varʹ��
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
