//
// hps_ext
//
// Copyright (c) 2020 Alexey Melnikov
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
///////////////////////////////////////////////////////////////////////

module hps_ext
(
	input             clk_sys,
	inout      [35:0] EXT_BUS,

	output reg        heartbeat = 0,

	// real Subchannel Q (see doc/real_subq.md)
	output reg        subq_set = 0,     // 1 clock pulse when a complete CD_SET has been received
	output reg [23:0] subq_set_tag,
	output reg  [7:0] subq_set_status,
	output reg [95:0] subq_set_data,
	input       [7:0] subq_req_phys_seq,
	input      [23:0] subq_req_phys_tag,
	input       [7:0] subq_req_getq_seq,
	input      [15:0] subq_req_getq
);

reg [15:0] io_dout;
reg        dout_en = 0;

assign EXT_BUS[15:0] = io_dout;
wire [15:0] io_din = EXT_BUS[31:16];
assign EXT_BUS[32] = dout_en;
wire io_strobe = EXT_BUS[33];
wire io_enable = EXT_BUS[34];

// CD_GET (HPS polls, psx_poll):
//   word 0 -> {getq_seq, phys_seq}   (HPS detects new requests by sequence change)
//   word 1 -> phys_tag[15:0]
//   word 2 -> {8'h00, phys_tag[23:16]}
//   word 3 -> getq {adr, point}
// CD_SET (HPS sends a Q):
//   word 1 <- tag[15:0]
//   word 2 <- {status[7:0], tag[23:16]}
//   word 3..8 <- Q bytes 0..11, little endian (byte 0 in [7:0] of word 3)
localparam CD_GET = 'h34;
localparam CD_SET = 'h35;

localparam EXT_CMD_MIN = CD_GET;
localparam EXT_CMD_MAX = CD_SET;

reg  [9:0] byte_cnt;

always@(posedge clk_sys) begin
	reg [15:0] cmd;
	reg [23:0] phys_tag_l;
	reg [15:0] getq_l;
	reg [23:0] tag_r;
	reg  [7:0] status_r;
	reg [95:0] data_r;

	subq_set <= 0;

	if(~io_enable) begin
		dout_en <= 0;
		io_dout <= 0;
		byte_cnt <= 0;
		cmd <= 0;
		if(cmd == CD_GET) heartbeat <= ~heartbeat;
		if(cmd == CD_SET && byte_cnt >= 9) begin
			subq_set        <= 1;
			subq_set_tag    <= tag_r;
			subq_set_status <= status_r;
			subq_set_data   <= data_r;
		end
	end
	else if(io_strobe) begin
		io_dout <= 0;
		if(~&byte_cnt) byte_cnt <= byte_cnt + 1'd1;

		if(byte_cnt == 0) begin
			cmd <= io_din;
			dout_en <= (io_din >= EXT_CMD_MIN && io_din <= EXT_CMD_MAX);
			if(io_din == CD_GET) begin
				io_dout    <= {subq_req_getq_seq, subq_req_phys_seq};
				phys_tag_l <= subq_req_phys_tag;   // latch so seq and tag belong together
				getq_l     <= subq_req_getq;
			end
		end else begin
			case(cmd)
				CD_GET:
					case(byte_cnt)
						1: io_dout <= phys_tag_l[15:0];
						2: io_dout <= {8'h00, phys_tag_l[23:16]};
						3: io_dout <= getq_l;
						default: ;
					endcase

				CD_SET:
					case(byte_cnt)
						1: tag_r[15:0]  <= io_din;
						2: begin tag_r[23:16] <= io_din[7:0]; status_r <= io_din[15:8]; end
						3: data_r[15:0]  <= io_din;
						4: data_r[31:16] <= io_din;
						5: data_r[47:32] <= io_din;
						6: data_r[63:48] <= io_din;
						7: data_r[79:64] <= io_din;
						8: data_r[95:80] <= io_din;
						default: ;
					endcase
				default: ;
			endcase
		end
	end
end

endmodule
