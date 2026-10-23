/***************************************************
*	Module Name		:	HC595_Driver		   
*	Engineer		   :	小梅哥
*	Target Device	:	EP4CE10F17C8
*	Tool versions	:	Quartus II 13.0
*	Create Date		:	2017-3-31
*	Revision		   :	v1.0
*	Description		:  74HC595移位寄存器驱动设计
**************************************************/

module HC595_Driver(
	Clk,
	Rst_n,
	Data,
	S_EN,
	SEG7_SCLK,
	SEG7_RCLK,
	SEG7_DIO
);

	parameter DATA_WIDTH = 16;

	input Clk;
	input Rst_n;
	input [DATA_WIDTH-1 : 0] Data;	//data to send
	input S_EN;	//send en
	output reg SEG7_SCLK;	//shift clock(SH)
	output reg SEG7_RCLK;	//latch data clock(ST)
	output reg SEG7_DIO;	//shift serial data
	
	parameter CNT_MAX = 4;
	
	
	reg [15:0] divider_cnt;//分频计数器
	wire sck_pluse;
	
	reg [4:0]SHCP_EDGE_CNT;//SEG7_SCLK EDGE counter
	
	reg [15:0]r_data;
	
	always@(posedge Clk or negedge Rst_n)
	if(!Rst_n)
		r_data <= 16'd0;
	else if(S_EN)
		r_data <= Data;
	else
		r_data <= r_data;
		
	//clock divide
	always@(posedge Clk or negedge Rst_n)
	if(!Rst_n)
		divider_cnt <= 16'd0;
	else if(divider_cnt == CNT_MAX)
		divider_cnt <= 16'd0;
	else
		divider_cnt <= divider_cnt + 1'b1;
		
	assign sck_pluse = (divider_cnt == CNT_MAX);
	
	always@(posedge Clk or negedge Rst_n)
	if(!Rst_n)
		SHCP_EDGE_CNT <= 5'd0;
	else if(sck_pluse)begin
		if(SHCP_EDGE_CNT ==  5'd31)
			SHCP_EDGE_CNT <= 5'd0;
		else
			SHCP_EDGE_CNT <= SHCP_EDGE_CNT + 1'd1;
	end
	else
		SHCP_EDGE_CNT <= SHCP_EDGE_CNT;
		
	always@(posedge Clk or negedge Rst_n)
	if(!Rst_n)begin
		SEG7_SCLK <= 1'b0;
		SEG7_RCLK <= 1'b0;
		SEG7_DIO <= 1'b0;	
	end
	else begin
		case(SHCP_EDGE_CNT)
			5'd0 :begin SEG7_SCLK <= 1'b0; SEG7_RCLK <= 1'b1; SEG7_DIO <= r_data[15]; end
			5'd1 :begin SEG7_SCLK <= 1'b1; SEG7_RCLK <= 1'b0;end
			5'd2 :begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[14];end
			5'd3 :begin SEG7_SCLK <= 1'b1; end
			5'd4 :begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[13];end
			5'd5 :begin SEG7_SCLK <= 1'b1; end
			5'd6 :begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[12];end
			5'd7 :begin SEG7_SCLK <= 1'b1; end
			5'd8 :begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[11];end
			5'd9 :begin SEG7_SCLK <= 1'b1; end
			5'd10:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[10];end
			5'd11:begin SEG7_SCLK <= 1'b1; end
			5'd12:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[9];end
			5'd13:begin SEG7_SCLK <= 1'b1; end
			5'd14:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[8];end
			5'd15:begin SEG7_SCLK <= 1'b1; end
			5'd16:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[7];end
			5'd17:begin SEG7_SCLK <= 1'b1; end
			5'd18:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[6];end
			5'd19:begin SEG7_SCLK <= 1'b1; end
			5'd20:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[5];end
			5'd21:begin SEG7_SCLK <= 1'b1; end
			5'd22:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[4];end
			5'd23:begin SEG7_SCLK <= 1'b1; end
			5'd24:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[3];end
			5'd25:begin SEG7_SCLK <= 1'b1; end
			5'd26:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[2];end
			5'd27:begin SEG7_SCLK <= 1'b1; end
			5'd28:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[1];end
			5'd29:begin SEG7_SCLK <= 1'b1; end
			5'd30:begin SEG7_SCLK <= 1'b0; SEG7_DIO <= r_data[0];end
			5'd31:begin SEG7_SCLK <= 1'b1; end
		endcase	
	end

endmodule
