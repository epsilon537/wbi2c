////////////////////////////////////////////////////////////////////////////////
//
// Filename:  wbi2master.v
// {{{
// Project:  WBI2C ... a set of Wishbone controlled I2C controller(s)
//
// Purpose:  This module communicates with an external I2C slave, allowing
//    the WB-master to command the reading and/or writing of I2C
//  values.  The slave is assumed to have 128 bytes of data memory.  This
//  core then allows those bytes to be read or written as commanded.
//
// Registers:
//
// I2C_MASTER_CMD: Command Register and bitfields
// Word address offset 0.
// #define I2C_MASTER_CMD_BUSY 0x80000000
// #define I2C_MASTER_CMD_ERR  0x40000000
// #define I2C_MASTER_CMD_SLV_ADDR_OFFSET 17
// #define I2C_MASTER_CMD_SLV_ADDR_MASK 0x00fe0000
// #define I2C_MASTER_CMD_RD   0x00010000
// #define I2C_MASTER_CMD_WR   0x00000000
// #define I2C_MASTER_CMD_START_ADDR_OFFSET 8
// #define I2C_MASTER_CMD_START_ADDR_MASK 0x0000ff00 /*Initial address to read from or write to.*/
// #define I2C_MASTER_CMD_NUM_BYTES_OFFSET 0
// #define I2C_MASTER_CMD_NUM_BYTES_MASK 0xff /*Number of bytes to read/write*/
//
// I2C_MASTER_SPD: Speed Register:
// The programmable number of system clocks per I2C wait state.
// Nominally, this is one quarter the clock period of the I2C bus.
// Word address offset 1
// #define I2C_MASTER_SPD_MASK 0xfffff /*Max. 20 bits*/
//
// I2C_ISR: Interrupt Status Register:
// Word address offset 2
// #define I2C_ISR_BUSY 0x00000001 : Set when I2C goes from busy to idle
// state. Writing to I2C_ISR clears the bit.
//
// I2C_IEN: Interrtup Enable Register:
// Word address offset 3
// #define I2C_IEN_BUSY 0x00000001 : Set to enable IRQ generation when I2C
// goes from busy to idle state.
//
// I2C_MASTER_MEM_BASE: Local copy of the memory shared between the master
// and the slave.  When commanded to initiate a bus transaction,
// the bus controller will read from or write to this memory.
// In all other cases, it is completely accessable from the WB
// bus.
// Word address offset (1<<(MEM_ADDR_BITS-2))
// E.g is MEMD_ADDR_BITS=8, the memory starts at word address
// 64 (byte address 256).
// I2C_MASTER_MEM_SIZE_BYTES (1<<MEM_ADDR_BITS)
//
// Original Creator:  Dan Gisselquist, Ph.D.
//    Gisselquist Technology, LLC
//
// BoxLambda modifications by Epsilon537:
// - Add reset logic
// - Add ISR and IEN interrupt control registers
// - Add LITTLE_ENDIAN support
// - Add register interface documentation
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2015-2024, Gisselquist Technology, LLC
// {{{
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of the GNU General Public License as published
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
// }}}
// License:  GPL, v3, as defined and found on www.gnu.org,
// {{{
//    http://www.gnu.org/licenses/gpl.html
//
////////////////////////////////////////////////////////////////////////////////
//
`default_nettype none
// }}}
module wbi2cmaster #(
    // {{{
    parameter [0:0] CONSTANT_SPEED = 1'b0, //If set, I2C bus speed is not configurable through the I2C_MASTER_SPEED register.
    READ_ONLY = 1'b0,  //If set, only implement read transactions.
    LITTLE_ENDIAN = 1'b0, //If set, the host CPU interfacing with the wbi2cmaster is little endian. If clear, the host CPU is big endian.
    parameter [5:0] TICKBITS = 6'd20,  //Number of bits of the speed register.
    parameter [(TICKBITS-1):0] CLOCKS_PER_TICK = 20'd1000,  //Default speed register setting.
    parameter MEM_ADDR_BITS = 7 //Local memory address size. Local memory size is (1<<MEM_ADDR_BITS).
    // }}}
) (
    // {{{
    input wire i_clk,
    i_reset,
    // Wishbone
    // {{{
    // Input bus wires
    input wire i_wb_cyc,
    i_wb_stb,
    i_wb_we,
    input wire [(MEM_ADDR_BITS-2):0] i_wb_addr,
    input wire [31:0] i_wb_data,
    input wire [3:0] i_wb_sel,
    // Output bus wires
    output wire o_wb_stall,
    output reg o_wb_ack,
    output reg [31:0] o_wb_data,
    // }}}
    // I2C clock and data wires
    input wire i_i2c_scl,
    i_i2c_sda,
    output wire o_i2c_scl,
    o_i2c_sda,
    // And our output interrupt
    output wire o_int,
    // And some debug wires
    output wire [31:0] o_dbg
    // }}}
);

  // Local declarations
  // {{{
  localparam [2:0]  I2MIDLE     = 3'h0,
        I2MDEVADDR = 3'h1,
        I2MRDSTOP  = 3'h2,
        I2MRDDEV   = 3'h3,
        I2MTXDATA  = 3'h4,
        I2MRXDATA  = 3'h5,
        I2MCLEANUP = 3'h6;

  //
  // Our shared memory structure -- it gets no initial value(s)
  //
  reg [31:0] mem [0:((1<<(MEM_ADDR_BITS-2))-1)];

  // r_speed ... the programmable number of system clocks per I2C
  // wait state.  Nominally, this is one quarter the clock speed of the
  // I2C.
  reg    zero_speed_err;
  reg [(TICKBITS-1):0] r_speed;

  // Parameters used to control and read values from the lower level
  // I2C device driver we are working with.
  reg ll_i2c_cyc, ll_i2c_stb, ll_i2c_we;
  reg [7:0] ll_i2c_tx_data;
  wire ll_i2c_ack, ll_i2c_stall, ll_i2c_err;
  wire [7:0] ll_i2c_rx_data;
  wire [31:0] ll_dbg;

  reg [(MEM_ADDR_BITS-1):0] wr_addr;
  reg [3:0] wr_sel;
  reg [31:0] wr_data;
  reg wr_inc;
  reg r_write_lock;
  //
  // Variables to define the request we are in the process of making
  reg start_request;
  reg [7:1] newdev;
  reg newrx_txn;
  reg [(MEM_ADDR_BITS-1):0] newadr;
  //
  reg r_busy;

  // IRQ control
  reg isr, ien;

  reg last_op;
  reg rd_inc;
  reg last_err;
  reg [6:0] last_dev;
  reg [(MEM_ADDR_BITS-1):0] last_adr;
  reg [(MEM_ADDR_BITS-1):0] count_left;
  reg [31:0] w_wb_status;

  reg [(MEM_ADDR_BITS-1):0] rd_addr;

  reg rd_stb;
  reg [31:0] rd_word;
  reg [7:0] rd_byte;
  reg [1:0] rd_sel;
  wire [7:0] w_byte_addr;
  reg last_ack, last_addr_flag;
  reg [2:0] mstate;
  reg [1:0] acks_pending;
  reg [1:0] r_write_pause;

  //
  // }}}
  ////////////////////////////////////////////////////////////////////////
  //
  // The lower level module we are trying to drive
  // {{{
  ////////////////////////////////////////////////////////////////////////
  //
  //

  lli2cm lowlvl (
      i_clk,
      i_reset,
      r_speed,
      ll_i2c_cyc,
      ll_i2c_stb,
      ll_i2c_we,
      ll_i2c_tx_data,
      ll_i2c_ack,
      ll_i2c_stall,
      ll_i2c_err,
      ll_i2c_rx_data,
      i_i2c_scl,
      i_i2c_sda,
      o_i2c_scl,
      o_i2c_sda,
      ll_dbg
  );
  // }}}
  ////////////////////////////////////////////////////////////////////////
  //
  // Let's interact with the wishbone bus
  // {{{
  ////////////////////////////////////////////////////////////////////////
  //
  //

  // First, to arbitrate who has access to memory, and yet to keep our
  // block RAM, we'll create an intermediate data structure and delay
  // any writes to RAM by one clock.
  initial start_request = 1'b0;
  initial newdev = 7'h0;
  initial newrx_txn = 1'b0;
  initial newadr = 0;
  initial r_speed = CLOCKS_PER_TICK;
  initial zero_speed_err = 1'b0;
  initial isr = 1'b0;
  initial ien = 1'b0;

  always @(posedge i_clk) begin  // Writes from the master wishbone bus
    if (i_reset) begin
      start_request <= 1'b0;
      newdev <= 7'h0;
      newrx_txn <= 1'b0;
      newadr <= 0;
      r_speed <= CLOCKS_PER_TICK;
      zero_speed_err <= 1'b0;
      isr <= 1'b0;
      ien <= 1'b0;
    end else begin
      start_request <= 1'b0;
      //If write to register (as opposed to local memory)
      if ((i_wb_stb) && (i_wb_we) && (!r_busy) && (!i_wb_addr[(MEM_ADDR_BITS-2)])) begin
        //If Command Register
        if (i_wb_addr[1:0] == 2'b00)  // &&(MEM_ADDR_BITS <= 8)
        begin
          newdev <= i_wb_data[23:17];
          newrx_txn <= i_wb_data[16];
          newadr <= i_wb_data[(8+MEM_ADDR_BITS-1):8];

          start_request <= (i_wb_data[(MEM_ADDR_BITS-1):0] != 0) && ((!READ_ONLY) || (i_wb_data[16]));
          // end else if ((MEM_ADDR_BITS > 8)&&(!i_wb_addr))
          // begin
          //  newdev     <= i_wb_data[27:21];
          //  newrx_txn  <= i_wb_data[20];
          //  newadr    <= i_wb_data[(12+MEM_ADDR_BITS-1):12];

          //  start_request <= (i_wb_data[(MEM_ADDR_BITS-1):0] != 0)
          //    &&((!READ_ONLY)||(i_wb_data[20]));
        end

        //If Speed Register
        if ((i_wb_addr[1:0] == 2'b01) && (!CONSTANT_SPEED)) r_speed <= i_wb_data[(TICKBITS-1):0];

        //If ISR Register
        if (i_wb_addr[1:0] == 2'b10) isr <= 1'b0;

        //If IEN Register
        if (i_wb_addr[1:0] == 2'b11) ien <= i_wb_data[0];

        //Write to local memory...
      end else if (zero_speed_err) r_speed <= CLOCKS_PER_TICK;
      zero_speed_err <= (r_speed == 0);
      wr_sel <= 4'h0;
      wr_inc <= 1'b0;
      if (r_write_lock) begin
        if (ll_i2c_ack) begin
          wr_data <= {(4) {ll_i2c_rx_data}};
          wr_addr <= newadr[(MEM_ADDR_BITS-1):0];
          if (LITTLE_ENDIAN)
            case (newadr[1:0])
              2'b11: wr_sel <= 4'b1000;
              2'b10: wr_sel <= 4'b0100;
              2'b01: wr_sel <= 4'b0010;
              2'b00: wr_sel <= 4'b0001;
            endcase
          else
            case (newadr[1:0])
              2'b00: wr_sel <= 4'b1000;
              2'b01: wr_sel <= 4'b0100;
              2'b10: wr_sel <= 4'b0010;
              2'b11: wr_sel <= 4'b0001;
            endcase

          newadr <= newadr + 1'b1;
          wr_inc <= 1'b1;
        end
      end else if (!READ_ONLY) begin
        wr_data <= i_wb_data;
        wr_sel  <= ((i_wb_stb) && (i_wb_we) && (i_wb_addr[MEM_ADDR_BITS-2])) ? i_wb_sel : 4'h0;
        wr_addr <= {i_wb_addr[(MEM_ADDR_BITS-3):0], 2'b00};
      end

      if (wr_sel[3]) mem[wr_addr[(MEM_ADDR_BITS-1):2]][31:24] <= wr_data[31:24];
      if (wr_sel[2]) mem[wr_addr[(MEM_ADDR_BITS-1):2]][23:16] <= wr_data[23:16];
      if (wr_sel[1]) mem[wr_addr[(MEM_ADDR_BITS-1):2]][15:8] <= wr_data[15:8];
      if (wr_sel[0]) mem[wr_addr[(MEM_ADDR_BITS-1):2]][7:0] <= wr_data[7:0];

      //Set ISR if going from busy to idle.
      if ((mstate == I2MIDLE) && r_busy && (!ll_i2c_stall)) isr <= 1'b1;
    end
  end
  // }}}

  // w_wb_status
  // {{{
  always @(*) begin
    w_wb_status = 0;

    w_wb_status[(MEM_ADDR_BITS-1):0] = count_left;
    w_wb_status[(8+MEM_ADDR_BITS-1):8] = last_adr;
    w_wb_status[23:16] = {last_dev, 1'b0};
    w_wb_status[31:24] = {r_busy, last_err, 6'h0};
  end
  // }}}

  // o_wb_data
  // {{{
  always @(posedge i_clk) begin  // Read values and place them on the master wishbone bus.
    //If write to Command Register
    if ((i_wb_stb) && (i_wb_we) && (!r_busy) && (i_wb_addr[1:0] == 2'b00)) begin
      count_left <= i_wb_data[(MEM_ADDR_BITS-1):0];  //Num. bytes
      last_op <= 1'b0;
    end else last_op <= (count_left[(MEM_ADDR_BITS-1):0] == 0);
    if (wr_inc) begin
      last_dev <= newdev;
      last_adr <= wr_addr + 1'b1;
      if (|count_left) count_left <= count_left - 1'b1;
    end else if (rd_inc) begin
      last_dev <= newdev;
      last_adr <= rd_addr - 1'b1;
      if (|count_left) count_left <= count_left - 1'b1;
    end

    casez ({
      i_wb_addr[(MEM_ADDR_BITS-2)], i_wb_addr[1:0]
    })
      3'b000: o_wb_data <= w_wb_status;
      3'b001: o_wb_data <= {{(32 - TICKBITS) {1'b0}}, r_speed};
      3'b010: o_wb_data <= {31'b0, isr};
      3'b011: o_wb_data <= {31'b0, ien};
      3'b1??: o_wb_data <= mem[i_wb_addr[(MEM_ADDR_BITS-3):0]];
    endcase
  end
  // }}}

  // o_wb_ack, o_wb_stall
  // {{{
  initial o_wb_ack = 1'b0;
  always @(posedge i_clk) o_wb_ack <= !i_reset && i_wb_stb;
  assign o_wb_stall = 1'b0;
  // }}}

  // rd_word, rd_sel, rd_byte
  // {{{
  always @(posedge i_clk) begin
    if (rd_stb) begin
      rd_word <= mem[rd_addr[(MEM_ADDR_BITS-1):2]];
      rd_sel  <= rd_addr[1:0];
    end

    if (LITTLE_ENDIAN)
      case (rd_sel)
        2'b11: rd_byte <= rd_word[31:24];
        2'b10: rd_byte <= rd_word[23:16];
        2'b01: rd_byte <= rd_word[15:8];
        2'b00: rd_byte <= rd_word[7:0];
      endcase
    else
      case (rd_sel)
        2'b00: rd_byte <= rd_word[31:24];
        2'b01: rd_byte <= rd_word[23:16];
        2'b10: rd_byte <= rd_word[15:8];
        2'b11: rd_byte <= rd_word[7:0];
      endcase
  end
  // }}}

  ////////////////////////////////////////////////////////////////////////
  //
  // The master state machine
  // {{{
  ////////////////////////////////////////////////////////////////////////
  //
  //
  assign w_byte_addr[(MEM_ADDR_BITS-1):0] = newadr;
  generate
    if (MEM_ADDR_BITS < 8) assign w_byte_addr[7:(MEM_ADDR_BITS)] = 0;
  endgenerate

  initial rd_inc = 1'b0;
  initial r_write_lock = 1'b0;
  initial mstate = I2MIDLE;
  initial r_busy = 1'b0;
  always @(posedge i_clk) begin
    if (i_reset) begin
      rd_inc <= 1'b0;
      r_write_lock <= 1'b0;
      mstate <= I2MIDLE;
      r_busy <= 1'b0;
    end else begin
      if (!ll_i2c_cyc) last_addr_flag <= 1'b0;
      else if (last_op) last_addr_flag <= 1'b1;
      rd_stb <= 1'b0;

      //If Comand Register access
      if ((!r_busy) && (i_wb_stb) && (i_wb_addr[1:0] == 2'b00) && (!i_wb_addr[(MEM_ADDR_BITS-2)]))
        last_err <= 1'b0;
      else if ((r_busy) && (ll_i2c_err)) last_err <= 1'b1;

      if (mstate == I2MIDLE) acks_pending <= 2'h0;
      else
        case ({
          (ll_i2c_stb) && (!ll_i2c_stall), ll_i2c_ack
        })
          2'b00: acks_pending <= acks_pending;
          2'b01: acks_pending <= (|acks_pending) ? (acks_pending - 1'b1) : 0;
          2'b10: acks_pending <= acks_pending + 1'b1;
          2'b11: acks_pending <= acks_pending;
        endcase

      last_ack <= (acks_pending[1] == 1'b0) && (!ll_i2c_stb);

      rd_inc   <= 1'b0;
      case (mstate)
        I2MIDLE: begin
          ll_i2c_cyc   <= 1'b0;
          ll_i2c_stb   <= 1'b0;
          r_write_lock <= 1'b0;
          if ((start_request) && (!ll_i2c_stall)) begin
            ll_i2c_cyc <= 1'b1;
            ll_i2c_stb <= 1'b1;
            ll_i2c_we <= 1'b1;
            // We start, always, by writing the address out
            ll_i2c_tx_data <= {newdev, 1'b0};
            rd_addr <= newadr;
            mstate <= I2MDEVADDR;
            rd_stb <= 1'b1;
            r_busy <= 1'b1;
          end else begin
            r_busy <= ll_i2c_stall;
          end
        end
        I2MDEVADDR: begin
          r_write_lock <= 1'b0;
          if (!ll_i2c_stall) begin
            ll_i2c_we <= 1'b1;  // Still writing
            ll_i2c_stb <= 1'b1;
            ll_i2c_tx_data <= w_byte_addr;
            if (newrx_txn) mstate <= I2MRDSTOP;
            else begin
              mstate <= I2MTXDATA;
            end
          end
          if (ll_i2c_err) begin
            mstate <= I2MCLEANUP;
            ll_i2c_stb <= 1'b0;
          end
        end
        I2MRDSTOP: begin  // going to read, need to send the dev addr
          // First thing we have to do is end our transaction
          r_write_lock <= 1'b0;
          if (!ll_i2c_stall) begin
            ll_i2c_stb <= 1'b0;
          end

          if ((!ll_i2c_stb) && (last_ack) && (ll_i2c_ack)) begin
            ll_i2c_cyc <= 1'b0;
            mstate <= I2MRDDEV;
          end
          if (ll_i2c_err) begin
            mstate <= I2MCLEANUP;
            ll_i2c_stb <= 1'b0;
          end
        end
        I2MRDDEV: begin
          ll_i2c_stb   <= 1'b0;
          r_write_lock <= 1'b0;
          if (!ll_i2c_stall) // Wait 'til its no longer busy
        begin // Fire us up again
            ll_i2c_cyc <= 1'b1;
            ll_i2c_stb <= 1'b1;
            ll_i2c_we <= 1'b1;
            ll_i2c_tx_data <= {newdev, 1'b1};
            mstate <= I2MRXDATA;
            r_write_pause <= 2'b01;
          end
          if (ll_i2c_err) begin
            mstate <= I2MCLEANUP;
            ll_i2c_stb <= 1'b0;
          end
        end
        I2MTXDATA: begin  // We are sending to the slave
          ll_i2c_stb   <= 1'b1;
          r_write_lock <= 1'b0;
          if (!ll_i2c_stall) begin
            rd_inc <= 1'b1;
            rd_addr <= rd_addr + 1'b1;
            ll_i2c_tx_data <= rd_byte;
            rd_stb <= 1'b1;
            if (last_addr_flag) begin
              ll_i2c_stb <= 1'b0;
              mstate <= I2MCLEANUP;
            end
          end
          if (ll_i2c_err) begin
            mstate <= I2MCLEANUP;
            ll_i2c_stb <= 1'b0;
          end
        end
        I2MRXDATA: begin
          ll_i2c_we <= 1'b0;
          if (!ll_i2c_stall) begin
            if (|r_write_pause) r_write_pause <= r_write_pause - 1'b1;
            r_write_lock   <= (r_write_pause == 2'b00);
            ll_i2c_tx_data <= rd_byte;
          end
          if (last_addr_flag) begin
            ll_i2c_stb <= 1'b0;
            mstate <= I2MCLEANUP;
          end
          if (ll_i2c_err) begin
            mstate <= I2MCLEANUP;
            ll_i2c_stb <= 1'b0;
          end
        end
        I2MCLEANUP: begin
          ll_i2c_cyc <= 1'b1;
          ll_i2c_stb <= 1'b0;
          if ((ll_i2c_we) && (ll_i2c_ack)) rd_inc <= 1'b1;
          if (last_ack) begin
            mstate <= I2MIDLE;
            ll_i2c_cyc <= 1'b1;
          end
        end
        default: mstate <= I2MIDLE;
      endcase
    end
  end
  // }}}

  assign o_int = isr & ien;

  ////////////////////////////////////////////////////////////////////////
  //
  // Debug data
  // {{{
  ////////////////////////////////////////////////////////////////////////
  //
  //
  assign o_dbg = {ll_dbg[31:29], last_adr[6:0], wr_inc, count_left[5:0], ll_dbg[14:0]};
  // }}}

  // Keep Verilator happy
  // {{{
  // Verilator lint_off UNUSED
  wire unused;
  assign unused = &{1'b0, i_wb_cyc, ll_dbg[28:15]};
  // Verilator lint_on  UNUSED
  // }}}
endmodule

