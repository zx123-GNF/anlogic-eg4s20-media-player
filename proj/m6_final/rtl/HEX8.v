/***************************************************
*	Module Name		:	HEX8		   
*	Engineer		:	小梅哥
*	Target Device	:	EP4CE10F17C8
*	Tool versions	:	Quartus II 13.0
*	Create Date		:	2017-3-31
*	Revision		:	v1.0
*	Description		:  	8位7段数码管显示设计
**************************************************/

module HEX8(
    clk,
    rst_n,
    en,
	 sw,
	 switch,
	 mode,
    disp_data,
    sel,
    seg
);
	input clk;
	input rst_n;
	input en; //数码管显示使能，1使能，0关闭
	input switch;
	input mode;
	input [31:0]disp_data;
	output reg [7:0] seg;
	output [7:0] sel;
	input [7:0] sw;
	
	parameter CNT_MAX = 24999;
	//parameter CNT_MAX = 4;  //for simulation
	reg [14:0]divider_cnt;//25000-1
	
	reg clk_1K;
	reg [7:0]sel_r;
	
	reg [4:0]data_tmp;//数据缓存 ;data_tmp[4]用来控制DP显示

	//分频计数器计数模块
	always@(posedge clk or negedge rst_n)
	if(!rst_n)
		divider_cnt <= 15'd0;
	else if(!en)
		divider_cnt <= 15'd0;
	else if(divider_cnt == CNT_MAX)
		divider_cnt <= 15'd0;
	else
		divider_cnt <= divider_cnt + 1'b1;

	//1K扫描时钟生成模块		
	always@(posedge clk or negedge rst_n)
	if(!rst_n)
		clk_1K <= 1'b0;
	else if(divider_cnt == CNT_MAX)
		clk_1K <= ~clk_1K;
	else
		clk_1K <= clk_1K;
	
	//8位循环移位寄存器
	always@(posedge clk_1K or negedge rst_n)
	if(!rst_n)
		sel_r <= 8'b0000_0001;
	else if(sel_r == 8'b1000_0000)
		sel_r <= 8'b0000_0001;
	else
		sel_r <=  sel_r << 1;
		
	assign sel = sel_r& sw;
	
	always@(*)
		case(sel_r)
			8'b0000_0001:seg = switch ? {1'b1, decode(disp_data[3 :0 ])} : 8'h00;
			8'b0000_0010:seg = switch ? {1'b1, decode(disp_data[7 :4 ])} : 8'h00;
			8'b0000_0100:seg = switch ? {1'b1, decode(disp_data[11:8 ])} : 8'h00;
			8'b0000_1000:seg = switch ? {!mode, decode(disp_data[15:12])} : 8'h00;
			8'b0001_0000:seg = switch ? {1'b1, decode(disp_data[19:16])} : 8'h00;
			8'b0010_0000:seg = switch ? {1'b1, decode(disp_data[23:20])} : 8'h00;
			8'b0100_0000:seg = switch ? {1'b1, decode(disp_data[27:24])} : 8'h00;
			8'b1000_0000:seg = switch ? {!mode, decode(disp_data[31:28])} : 8'h00;
			default : seg = 8'hff;
		endcase
	
	function [6:0] decode;
		input [3:0] in;
		begin
			case (in)
				4'h0:decode[6:0] = 7'b1000000; /*0*/
				4'h1:decode[6:0] = 7'b1111001; /*1*/
				4'h2:decode[6:0] = 7'b0100100; /*2*/
				4'h3:decode[6:0] = 7'b0110000; /*3*/
				4'h4:decode[6:0] = 7'b0011001; /*4*/
				4'h5:decode[6:0] = 7'b0010010; /*5*/
				4'h6:decode[6:0] = 7'b0000010; /*6*/
				4'h7:decode[6:0] = 7'b1111000; /*7*/
				4'h8:decode[6:0] = 7'b0000000; /*8*/
				4'h9:decode[6:0] = 7'b0010000; /*9*/
				4'ha:decode[6:0] = 7'b0001000; /*a*/
				4'hb:decode[6:0] = 7'b0000011; /*b*/
				4'hc:decode[6:0] = 7'b1000110; /*c*/
				4'hd:decode[6:0] = 7'b0100001; /*d*/
				4'he:decode[6:0] = 7'b0000110; /*e*/
				4'hf:decode[6:0] = (mode == 'd0) ? 7'b0111111 : 7'b0001110; /*-*//*f*/
			endcase
		end
	endfunction
	
//	assign sel = (en)?sel_r:8'b0000_0000;

endmodule
