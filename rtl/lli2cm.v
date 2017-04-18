////////////////////////////////////////////////////////////////////////////////
//
// Filename:	lli2cm.v
//
// Project:	WBI2C ... a set of Wishbone controlled I2C controller(s)
//
// Purpose:	This is a lower level I2C driver for a master I2C byte-wise
//		interface.  This particular interface is designed to handle
//	all byte level ineraction with he actual port.  The external interface
//	to this module is something akin to wishbone, although without the
//	address register.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2017, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
//
`define I2CMIDLE		4'h0
`define I2CMSTART		4'h1
`define I2CMBIT_SET		4'h2
`define I2CMBIT_POSEDGE		4'h3
`define I2CMBIT_NEGEDGE		4'h4
`define I2CMBIT_CLR		4'h5
`define I2CMACK_SET		4'h6
`define I2CMACK_POSEDGE		4'h7
`define I2CMACK_NEGEDGE		4'h8
`define I2CMACK_CLR		4'h9
`define I2CMRESTART		4'ha
`define I2CMRESTART_POSEDGE	4'hb
`define I2CMRESTART_NEGEDGE	4'hc
`define I2CMSTOP		4'hd
`define I2CMSTOPPD		4'he
`define I2CMFINAL		4'hf
//
//
module lli2cm(i_clk, i_clocks, i_cyc, i_stb, i_we, i_data,
				o_ack, o_busy, o_err, o_data,
			i_scl, i_sda, o_scl, o_sda, o_dbg);
	parameter	[5:0]	TICKBITS		 = 20;
	parameter	[(TICKBITS-1):0] CLOCKS_PER_TICK = 20'd1000;
	parameter	[0:0]		PROGRAMMABLE_RATE= 1'b1;
	input	wire		i_clk;
	//
	input	wire	[(TICKBITS-1):0]	i_clocks;
	//
	input	wire		i_cyc, i_stb, i_we;
	input	wire	[7:0]	i_data;
	output	reg		o_ack, o_busy, o_err;
	output	reg	[7:0]	o_data;
	input	wire		i_scl, i_sda;
	output	reg		o_scl, o_sda;
	output	wire	[31:0]	o_dbg;

	reg	[(TICKBITS-1):0]	clocks_per_tick;
	always @(posedge i_clk)
		clocks_per_tick <= (PROGRAMMABLE_RATE) ? i_clocks
				: CLOCKS_PER_TICK;


	reg	[3:0]	state;
	reg	[(TICKBITS-1):0]	clock;
	reg		zclk, r_cyc, r_err, r_we;
	reg	[2:0]	nbits;
	reg	[7:0]	r_data;


	initial	clock = CLOCKS_PER_TICK;
	initial	zclk  = 1'b1;
	always @(posedge i_clk)
		if (state == `I2CMIDLE)
		begin
			if ((i_stb)&&(!o_busy))
			begin
				clock <= clocks_per_tick;
				zclk  <= 1'b0;
			end else begin
				clock <= 0;
				zclk  <= 1'b1;
			end
		end else if ((clock == 0)||(o_scl)&&(!i_scl))
		begin
			clock <= clocks_per_tick;
			zclk <= 1'b0;
		end else begin	
			clock <= clock - 1'b1;
			zclk <= (clock == 1);
		end

	initial	state  = `I2CMIDLE;
	initial	o_ack  = 1'b0;		
	initial	o_busy = 1'b0;
	initial	r_cyc  = 1'b1;
	initial	nbits  = 3'h0;
	initial	r_we   = 1'b0;
	initial	r_data = 8'h0;
	initial	o_scl  = 1'b1;
	initial	o_sda  = 1'b1;
	always @(posedge i_clk)
	begin
		o_ack  <= 1'b0;
		o_err  <= 1'b0;
		o_busy <= 1'b1;
		r_cyc <= (r_cyc) && (i_cyc);
		if (zclk) case(state)
			`I2CMIDLE: begin
				r_err <= 1'b0;
				nbits <= 3'h0;
				r_cyc <= i_cyc;
				if ((i_stb)&&(!o_busy)) begin
					r_data <= i_data;
					r_we   <= i_we; 
					nbits  <= 0;
					state  <= `I2CMSTART;
					o_sda  <= 1'b0;
				end else
					o_busy <= 1'b0;
			    end
			`I2CMSTART: begin
				state <= `I2CMBIT_SET;
				o_scl <= 1'b0;
			    end
			`I2CMBIT_SET: begin
				o_sda <= (r_we)?r_data[7] : 1'b1;
				if (r_we)
					r_data <= { r_data[6:0], i_sda };
				nbits <= nbits - 1'b1;
				state <= `I2CMBIT_POSEDGE;
				end
			`I2CMBIT_POSEDGE: begin
				if (!r_we)
					r_data <= { r_data[6:0], i_sda };
				o_scl <= 1'b1;
				r_err <= (r_err)||((r_we)&&(o_sda != i_sda));
				state <= `I2CMBIT_NEGEDGE;
				end
			`I2CMBIT_NEGEDGE: begin
				if (i_scl)
				    begin
					o_scl <= 1'b0;
					state <= `I2CMBIT_CLR;
				    end
				end
			`I2CMBIT_CLR: begin
				if (nbits != 3'h0)
					state <= `I2CMBIT_SET;
				else
					state <= `I2CMACK_SET;
				end
			`I2CMACK_SET: begin
					o_sda <= (r_we) ? 1'b1 : 1'b0;
					state <= `I2CMACK_POSEDGE;
				end
			`I2CMACK_POSEDGE: begin
					o_scl <= 1'b1;
					state <= `I2CMACK_NEGEDGE;
				end
			`I2CMACK_NEGEDGE: begin
					if (i_scl)
					begin
						o_scl <= 1'b0;
						r_err <= (r_err)||((r_we)&&(i_sda));
						state <= `I2CMACK_CLR;
					end
				end
			`I2CMACK_CLR: begin
				o_err  <= r_err;
				o_data <= r_data;
				o_ack  <= 1'b1;
				o_sda  <= 1'b0;
				o_scl  <= 1'b0;
				if (r_err)
					state <= `I2CMSTOP;
				else if ((i_stb)&&(r_cyc)&&(i_cyc))
				begin
					o_busy <= 1'b0;
					r_we   <= i_we;
					r_data <= i_data;
				//	if (r_we != i_we)
				//		state <= `I2CMRESTART;
				//	else
						state <= `I2CMSTART;
					nbits <= 0;
				end else if ((i_cyc)&&(i_stb)&&(!r_cyc))
					state <= `I2CMRESTART;
				else // if (!i_cyc)
					state <= `I2CMSTOP;
				end
			`I2CMRESTART: begin
				o_sda <= 1'b1;
				state <= `I2CMRESTART_POSEDGE;
				end
			`I2CMRESTART_POSEDGE: begin
				o_sda <= 1'b1;
				o_scl <= 1'b1;
				state <= `I2CMRESTART_NEGEDGE;
				end
			`I2CMRESTART_NEGEDGE: begin
				o_sda <= 1'b1;
				o_scl <= 1'b1;
				if (i_scl)
				  begin
					state <= `I2CMSTART;
					o_sda <= 1'b0;
				  end
				end
			`I2CMSTOP: begin
				o_scl <= 1'b1;
				o_sda <= 1'b0; // (No change)
				state <= `I2CMSTOPPD;
				end
			`I2CMSTOPPD: begin
				o_scl <= 1'b1;
				o_sda <= 1'b1;
				state <= `I2CMFINAL;
				end
			default: begin
				o_scl <= 1'b1;
				o_sda <= 1'b1;
				state <= `I2CMIDLE;
				end
		endcase
	end

	assign	o_dbg = { i_cyc, 27'h00, i_scl, i_sda, o_scl, o_sda };

endmodule