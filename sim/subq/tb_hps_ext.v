// Testbench for hps_ext CD_GET / CD_SET (real Subchannel Q protocol)
// Emulates hps_io EXT_BUS behavior: io_enable framing a transaction, io_strobe per 16-bit word,
// data returned by the core for word k is the io_dout set on the strobe of word k.
`timescale 1ns/1ps
module tb;
	reg clk = 0; always #5 clk = ~clk;
	wire [35:0] EXT_BUS;
	reg  [15:0] din = 0;
	reg         strobe = 0, enable = 0;
	assign EXT_BUS[31:16] = din;
	assign EXT_BUS[33] = strobe;
	assign EXT_BUS[34] = enable;
	wire [15:0] dout = EXT_BUS[15:0];
	wire heartbeat, subq_set;
	wire [23:0] subq_set_tag; wire [7:0] subq_set_status; wire [95:0] subq_set_data;
	reg  [7:0] phys_seq = 8'h05, getq_seq = 8'h02;
	reg [23:0] phys_tag = 24'h0371E3; reg [15:0] getq = 16'h01A2;
	integer errors = 0, pulses = 0;
	hps_ext dut(.clk_sys(clk), .EXT_BUS(EXT_BUS), .heartbeat(heartbeat),
		.subq_set(subq_set), .subq_set_tag(subq_set_tag), .subq_set_status(subq_set_status), .subq_set_data(subq_set_data),
		.subq_req_phys_seq(phys_seq), .subq_req_phys_tag(phys_tag), .subq_req_getq_seq(getq_seq), .subq_req_getq(getq));
	always @(posedge clk) if (subq_set) pulses = pulses + 1;

	reg [15:0] r;
	task word(input [15:0] w, output [15:0] rd);
		begin
			@(posedge clk) din <= w; strobe <= 1;
			@(posedge clk) strobe <= 0;
			@(posedge clk) rd = dout;   // sampled after the strobe, as hps_io does
		end
	endtask
	task start; begin @(posedge clk) enable <= 1; end endtask
	task stop;  begin @(posedge clk) enable <= 0; repeat(3) @(posedge clk); end endtask
	task check(input [95:0] got, input [95:0] exp, input [8*24-1:0] what);
		begin if (got !== exp) begin errors = errors + 1; $display("FAIL %0s: got %h expected %h", what, got, exp); end
		else $display("ok   %0s = %h", what, got); end
	endtask

	reg hb0;
	initial begin
		repeat(4) @(posedge clk);
		// ---- CD_GET ----
		hb0 = heartbeat;
		start; word(16'h34, r); check(r, {getq_seq, phys_seq}, "CD_GET seq word");
		word(0, r); check(r, phys_tag[15:0], "CD_GET phys tag lo");
		word(0, r); check(r, {8'h00, phys_tag[23:16]}, "CD_GET phys tag hi");
		word(0, r); check(r, getq, "CD_GET getq adr/point");
		stop; check(heartbeat ^ hb0, 1, "heartbeat toggled");
		// ---- CD_SET ----
		start; word(16'h35, r);
		word(16'h71E5, r); word(16'h0303, r);                        // tag 0x0371E5, status 0x03
		word(16'h0141, r); word(16'h0001, r); word(16'h0802, r);    // Q bytes 0..5
		word(16'h0002, r); word(16'h0a03, r); word(16'hC3B2, r);    // Q bytes 6..11
		stop;
		check(pulses, 1, "subq_set pulses");
		check(subq_set_tag, 24'h0371E5, "tag");
		check(subq_set_status, 8'h03, "status");
		check(subq_set_data, 96'hC3B20a030002080200010141, "Q data");
		// ---- truncated CD_SET must not pulse ----
		start; word(16'h35, r); word(16'h1111, r); word(16'h0303, r); stop;
		check(pulses, 1, "no pulse, short CD_SET");
		// ---- unrelated command must not pulse / drive bus ----
		start; word(16'h20, r); word(0, r); stop;
		check(pulses, 1, "no pulse on other cmd");
		if (errors == 0) $display("ALL TESTS PASSED"); else $display("%0d TESTS FAILED", errors);
		$finish;
	end
endmodule
