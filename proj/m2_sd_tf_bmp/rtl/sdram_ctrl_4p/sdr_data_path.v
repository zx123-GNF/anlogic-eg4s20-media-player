module sdr_data_path(
        CLK,
        RESET_N,
        DATAIN,
        DM,
        DQOUT,
        DQM
        );

// Address Space Parameters

`define ROWSTART        8          
`define ROWSIZE         11
`define COLSTART        0
`define COLSIZE         8
`define BANKSTART       19
`define BANKSIZE        2

// Address and Data Bus Sizes

`define  ASIZE           21      // total address width of the SDRAM
`define  DSIZE           32      // Width of data bus to SDRAMS

//parameter	INIT_PER	=	100;		//	For Simulation

//	Controller Parameter
////////////	133 MHz	///////////////
/*
parameter	INIT_PER	=	32000;
parameter	REF_PER		=	1536;
parameter	SC_CL		=	3;
parameter	SC_RCD		=	3;
parameter	SC_RRD		=	7;
parameter	SC_PM		=	1;
parameter	SC_BL		=	1;
*/
///////////////////////////////////////
////////////	100 MHz	///////////////
parameter	INIT_PER	=	24000;
parameter	REF_PER		=	1024;
parameter	SC_CL		=	3;
parameter	SC_RCD		=	3;
parameter	SC_RRD		=	7;
parameter	SC_PM		=	1;
parameter	SC_BL		=	1;
///////////////////////////////////////
////////////	50 MHz	///////////////
/*
parameter	INIT_PER	=	12000;
parameter	REF_PER		=	512;
parameter	SC_CL		=	3;
parameter	SC_RCD		=	3;
parameter	SC_RRD		=	7;
parameter	SC_PM		=	1;
parameter	SC_BL		=	1;
*/
///////////////////////////////////////

//	SDRAM Parameter
parameter	SDR_BL		=	(SC_PM == 1)?	3'b111	:
							(SC_BL == 1)?	3'b000	:
							(SC_BL == 2)?	3'b001	:
							(SC_BL == 4)?	3'b010	:
											3'b011	;
parameter	SDR_BT		=	1'b0;	//	Sequential
							//	1'b1:	//	Interteave
parameter	SDR_CL		=	(SC_CL == 2)?	3'b10:
											3'b11;
 	


input                           CLK;                    // System Clock
input                           RESET_N;                // System Reset
input   [`DSIZE-1:0]            DATAIN;                 // Data input from the host
input   [`DSIZE/8-1:0]          DM;                     // byte data masks
output  [`DSIZE-1:0]            DQOUT;
output  [`DSIZE/8-1:0]          DQM;                    // SDRAM data mask ouputs
reg     [`DSIZE/8-1:0]          DQM;
            


// Allign the input and output data to the SDRAM control path
always @(posedge CLK or negedge RESET_N)
begin
        if (RESET_N == 0) 
		DQM		<= `DSIZE/8-1'hF;
        else
 		DQM		<=	DM;                 
end

assign DQOUT = DATAIN;

endmodule

