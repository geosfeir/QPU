import qpu_pkg::*;

// ============================================================
// block_precision_core.sv
// - ACCUM: accept BLOCK_SIZE complex_work_t samples, store to BRAM, track block_max
// - SHIFT: compute shift_amt + exp_out
// - NORM : BRAM read (1-cycle latency) -> normalize_round -> stream out with backpressure
// Notes:
// * Assumes block_buffer read port is synchronous (rdata valid 1 cycle after re asserted).
// * Output stream is held stable while valid_out=1 until ready_out handshake.
// ============================================================

module block_precision_core
(
input  logic          clk,
input  logic          rst,

input  logic          start_block,
output logic          block_done,
output logic          norm_done,

input  logic          valid_in,
output logic          ready_in,
input  complex_work_t data_in,

input  exp_t          exp_in,

output logic          valid_out,
input  logic          ready_out,
output complex_mant_t data_out,
output exp_t          exp_out
);

// State machine
typedef enum logic [2:0] {S_IDLE, S_ACCUM, S_SHIFT, S_NORM, S_DRAIN} state_t;
state_t state, state_n;

// Write-side address pointer (for BRAM write)
// We keep this local because block_counter doesn't expose wr_ptr.
// IMPORTANT: valid_in for counter must match the actual accepted write.
logic [BLOCK_ADDR_WIDTH-1:0] wr_ptr;

// block_counter instance (write completion pulse)
// Feed it "accepted input" validity, not raw valid_in.
logic bc_block_done;

block_counter #(
  .BLOCK_SIZE(BLOCK_SIZE)
) u_bc (
  .clk        (clk),
  .rst        (rst),
  .start_block(start_block),
  .valid_in   (valid_in && ready_in), // accepted sample
  .block_done (bc_block_done)
);

assign block_done = bc_block_done;

// Block buffer (dual-port BRAM)
logic                        buf_we;
logic [BLOCK_ADDR_WIDTH-1:0] buf_waddr;
logic [COMPLEX_WIDTH-1:0]    buf_wdata;

logic                        buf_re;
logic [BLOCK_ADDR_WIDTH-1:0] buf_raddr;
logic [COMPLEX_WIDTH-1:0]    buf_rdata; // registered output

block_buffer #(
  .BLOCK_SIZE(BLOCK_SIZE),
  .DATA_WIDTH(COMPLEX_WIDTH)
) u_buf (
  .clk   (clk),
  .we    (buf_we),
  .waddr (buf_waddr),
  .wdata (buf_wdata),
  .re    (buf_re),
  .raddr (buf_raddr),
  .rdata (buf_rdata)
);

// Unpack buffer read data into complex_work_t
complex_work_t buf_rdata_c;
always_comb begin
  buf_rdata_c.real_num = buf_rdata[COMPLEX_WIDTH-1 -: WORK_WIDTH];
  buf_rdata_c.imaginary = buf_rdata[WORK_WIDTH-1:0];
end

// Max tracker over accepted inputs during ACCUM
logic [WORK_WIDTH-1:0] block_max;

max_tracker #(.W(WORK_WIDTH)) u_max (
  .clk     (clk),
  .rst     (rst),
  .valid   (valid_in && ready_in),
  .in_real (data_in.real_num),
  .in_imag (data_in.imaginary),
  .clear   (start_block),
  .max_out (block_max)
);

// Shift calculation
logic [$clog2(WORK_WIDTH):0] lzc_cnt;

leading_zero_counter #(.W(WORK_WIDTH)) u_lzc (
  .in    (block_max),
  .count (lzc_cnt)
);

logic [$clog2(WORK_WIDTH):0] shift_amt_q;
exp_t exp_out_q;
assign exp_out = exp_out_q;

// Normalize + round (real and imag)
// These are combinational in our earlier version; we will
// register outputs via output holding regs for backpressure.
mant_t norm_real_w, norm_imag_w;

normalize_round #(
  .WORK_WIDTH(WORK_WIDTH),
  .MANT_WIDTH(MANT_WIDTH)
) u_norm_r (
  .in_val(buf_rdata_c.real_num),
  .shift_amt(shift_amt_q),
  .mant_out(norm_real_w)
);

normalize_round #(
  .WORK_WIDTH(WORK_WIDTH),
  .MANT_WIDTH(MANT_WIDTH)
) u_norm_i (
  .in_val(buf_rdata_c.imaginary),
  .shift_amt(shift_amt_q),
  .mant_out(norm_imag_w)
);

// NORM read pipeline with backpressure
//
// We treat the BRAM read port like a 1-stage prefetch:
//   - Issue read when we have space in output register (or output will be consumed)
//   - Next cycle BRAM provides buf_rdata; we compute norm_*_w and capture into out regs
//   - valid_out stays high until ready_out handshake
//
// Internal signals:
//   rd_issue   : we asserted buf_re this cycle
//   rd_issue_d : delayed one cycle => "buf_rdata corresponds to issued read"
//   rd_ptr     : next BRAM address to request
//   sent_count : number of outputs successfully handshaken (valid_out&&ready_out)
logic [BLOCK_ADDR_WIDTH:0] rd_ptr;
logic [BLOCK_ADDR_WIDTH:0] sent_count;   // counts 0..BLOCK_SIZE
logic rd_issue;
logic rd_issue_d;

complex_mant_t out_reg;
logic          out_valid;

assign data_out  = out_reg;
assign valid_out = out_valid;

// Space to accept next BRAM word into output register next cycle?
// We can issue a BRAM read if, next cycle, we'll have room to latch it.
// Condition for "room":
//   - output reg currently empty, OR
//   - output reg will be consumed this cycle (ready_out && out_valid)
logic out_will_pop;
logic have_room_for_next;

assign out_will_pop       = out_valid && ready_out;
assign have_room_for_next = (!out_valid) || out_will_pop;

// We only issue reads in S_NORM, and only until we've issued BLOCK_SIZE reads.
// Since capture happens 1 cycle later, we track rd_ptr as "next to issue".
assign rd_issue = (state == S_NORM) && have_room_for_next && (rd_ptr < BLOCK_SIZE);

assign buf_re    = rd_issue;
assign buf_raddr = rd_ptr[BLOCK_ADDR_WIDTH-1:0];

// Delay rd_issue to mark next-cycle data valid
always_ff @(posedge clk) begin
  if (rst) rd_issue_d <= 1'b0;
  else if (state != S_NORM && state_n != S_NORM) rd_issue_d <= 1'b0;
  else     rd_issue_d <= rd_issue;
end

// Advance rd_ptr when we issue a read
always_ff @(posedge clk) begin
  if (rst) begin
    rd_ptr <= '0;
  end else begin
    if (state == S_IDLE) begin
      rd_ptr <= '0;
    end else if (state == S_NORM && rd_issue) begin
      rd_ptr <= rd_ptr + 1'b1;
    end
  end
end

// Capture normalized output when BRAM data returns (rd_issue_d)
// Also maintain out_valid under backpressure.
always_ff @(posedge clk) begin
  if (rst) begin
    out_valid     <= 1'b0;
    out_reg       <= '0;
  end else begin
    // Pop (consume) if downstream ready
    if (out_will_pop) begin
      out_valid <= 1'b0;
    end

    // Push (capture) if BRAM data valid this cycle
    // If both pop and push happen same cycle, out_valid stays asserted and data updates.
    if (rd_issue_d && ((state == S_NORM) || (state == S_DRAIN))) begin
      out_reg.real_num <= norm_real_w;
      out_reg.imaginary <= norm_imag_w;
      out_valid    <= 1'b1;
    end
  end
end

// Count successful handshakes for completion
always_ff @(posedge clk) begin
  if (rst) begin
    sent_count <= '0;
  end else begin
    if (state == S_IDLE) begin
      sent_count <= '0;
    end else if ((state == S_NORM || state == S_DRAIN) && out_will_pop) begin
      sent_count <= sent_count + 1'b1;
    end
  end
end

// norm_done pulse when last word is successfully transferred
always_ff @(posedge clk) begin
  if (rst) norm_done <= 1'b0;
  else begin
    norm_done <= 1'b0;
    if (state == S_NORM && out_will_pop && (sent_count == BLOCK_SIZE-1))
      norm_done <= 1'b1;
  end
end

// ready_in control + write pointer + BRAM write wiring
always_comb begin
  // Only accept inputs during accumulate
  ready_in = (state == S_ACCUM);

  buf_we    = (state == S_ACCUM) && (valid_in && ready_in);
  buf_waddr = wr_ptr;
  buf_wdata = {data_in.real_num, data_in.imaginary};
end

always_ff @(posedge clk) begin
  if (rst) begin
    wr_ptr <= '0;
  end else begin
    if (start_block) begin
      wr_ptr <= '0;
    end else if (state == S_ACCUM && (valid_in && ready_in)) begin
      wr_ptr <= wr_ptr + 1'b1;
    end
  end
end

// FSM next-state
always_comb begin
  state_n = state;
  unique case (state)
    S_IDLE: if (start_block) state_n = S_ACCUM;
    S_ACCUM: if (bc_block_done) state_n = S_SHIFT;
    S_SHIFT: state_n = S_NORM;
    S_NORM: if (norm_done) state_n = S_DRAIN;
    S_DRAIN: if (!valid_out) state_n = S_IDLE;
    default: state_n = S_IDLE;
  endcase
end

always_ff @(posedge clk) begin
  if (rst) state <= S_IDLE;
  else     state <= state_n;
end

localparam int TARGET_MAG_MSB = (MANT_WIDTH - 2 - GUARD_BITS);

logic [$clog2(WORK_WIDTH):0] msb_pos;
logic [$clog2(WORK_WIDTH):0] shift_amt_next;

always_comb begin
  if (block_max == '0) begin
    msb_pos        = '0;
    shift_amt_next = '0;
  end else begin
    msb_pos = (WORK_WIDTH-1) - lzc_cnt;
    shift_amt_next = (msb_pos > TARGET_MAG_MSB) ? (msb_pos - TARGET_MAG_MSB) : '0;
  end
end

always_ff @(posedge clk) begin
  if (rst) begin
    shift_amt_q <= '0;
    exp_out_q   <= '0;
  end else if (state == S_SHIFT) begin
    shift_amt_q <= shift_amt_next;

    if (exp_in > exp_t'({EXP_WIDTH{1'b1}}) - exp_t'(shift_amt_next))
      exp_out_q <= exp_t'({EXP_WIDTH{1'b1}});
    else
      exp_out_q <= exp_in + exp_t'(shift_amt_next);
  end
end

endmodule