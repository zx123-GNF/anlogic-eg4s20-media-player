module control_interface(
        CLK,
        RESET_N,
        CMD,
        ADDR,
        REF_ACK,
		INIT_ACK,
        CM_ACK,
        NOP,
        READA,
        WRITEA,
        REFRESH,
        PRECHARGE,
        LOAD_MODE,
        SADDR,
        REF_REQ,
		INIT_REQ,
        CMD_ACK
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
input   [2:0]                   CMD;                    // Command input
input   [`ASIZE-1:0]            ADDR;                   // Address
input                           REF_ACK;                // Refresh request acknowledge
input							INIT_ACK;				// Initial request acknowledge
input                           CM_ACK;                 // Command acknowledge
output                          NOP;                    // Decoded NOP command
output                          READA;                  // Decoded READA command
output                          WRITEA;                 // Decoded WRITEA command
output                          REFRESH;                // Decoded REFRESH command
output                          PRECHARGE;              // Decoded PRECHARGE command
output                          LOAD_MODE;              // Decoded LOAD_MODE command
output  [`ASIZE-1:0]            SADDR;                  // Registered version of ADDR
output                          REF_REQ;                // Hidden refresh request
output                          INIT_REQ;               // Hidden initial request
output                          CMD_ACK;                // Command acknowledge


            
reg                             NOP;
reg                             READA;
reg                             WRITEA;
reg                             REFRESH;
reg                             PRECHARGE;
reg                             LOAD_MODE;
reg     [`ASIZE-1:0]            SADDR;
reg                             REF_REQ;
reg                             INIT_REQ;
reg                             CMD_ACK;

// Internal signals
reg     [15:0]                  timer;
reg		[31:0]					init_timer;



// Command decode and ADDR register
always @(posedge CLK or negedge RESET_N)
begin
        if (RESET_N == 0) 
        begin
                NOP             <= 0;
                READA           <= 0;
                WRITEA          <= 0;
                SADDR           <= 0;
        end
        
        else
        begin
        
                SADDR <= ADDR;                                  // register the address to keep proper
                                                                // alignment with the command
                                                             
                if (CMD == 3'b000)                              // NOP command
                        NOP <= 1;
                else
                        NOP <= 0;
                        
                if (CMD == 3'b001)                              // READA command
                        READA <= 1;
                else
                        READA <= 0;
                 
                if (CMD == 3'b010)                              // WRITEA command
                        WRITEA <= 1;
                else
                        WRITEA <= 0;
                        
        end
end


//  Generate CMD_ACK
always @(posedge CLK or negedge RESET_N)
begin
        if (RESET_N == 0)
                CMD_ACK <= 0;
        else
                if ((CM_ACK == 1) & (CMD_ACK == 0))
                        CMD_ACK <= 1;
                else
                        CMD_ACK <= 0;
end


// refresh timer
always @(posedge CLK or negedge RESET_N) begin
        if (RESET_N == 0) 
        begin
                timer           <= 0;
                REF_REQ         <= 0;
        end        
        else 
        begin
                if (REF_ACK == 1)
				begin
                	timer <= REF_PER;
					REF_REQ	<=0;
				end
				else if (INIT_REQ == 1)
				begin
                	timer <= REF_PER+200;
					REF_REQ	<=0;					
				end
                else
                	timer <= timer - 1'b1;

                if (timer==0)
                    REF_REQ    <= 1;

        end
end

// initial timer
always @(posedge CLK or negedge RESET_N) begin
        if (RESET_N == 0) 
        begin
                init_timer      <= 0;
				REFRESH         <= 0;
                PRECHARGE      	<= 0; 
				LOAD_MODE		<= 0;
				INIT_REQ		<= 0;
        end        
        else 
        begin
                if (init_timer < (INIT_PER+201))
					init_timer 	<= init_timer+1;
					
				if (init_timer < INIT_PER)
				begin
					REFRESH		<=0;
					PRECHARGE	<=0;
					LOAD_MODE	<=0;
					INIT_REQ	<=1;
				end
				else if(init_timer == (INIT_PER+20))
				begin
					REFRESH		<=0;
					PRECHARGE	<=1;
					LOAD_MODE	<=0;
					INIT_REQ	<=0;
				end
				else if( 	(init_timer == (INIT_PER+40))	||
							(init_timer == (INIT_PER+60))	||
							(init_timer == (INIT_PER+80))	||
							(init_timer == (INIT_PER+100))	||
							(init_timer == (INIT_PER+120))	||
							(init_timer == (INIT_PER+140))	||
							(init_timer == (INIT_PER+160))	||
							(init_timer == (INIT_PER+180))	)
				begin
					REFRESH		<=1;
					PRECHARGE	<=0;
					LOAD_MODE	<=0;
					INIT_REQ	<=0;
				end
				else if(init_timer == (INIT_PER+200))
				begin
					REFRESH		<=0;
					PRECHARGE	<=0;
					LOAD_MODE	<=1;
					INIT_REQ	<=0;				
				end
				else
				begin
					REFRESH		<=0;
					PRECHARGE	<=0;
					LOAD_MODE	<=0;
					INIT_REQ	<=0;									
				end
        end
end

endmodule

