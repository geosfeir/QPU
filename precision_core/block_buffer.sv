import qpu_pkg::*;

// ============================================================
// block_buffer.sv
// Simple dual-port, synchronous-read memory suitable for inference as BRAM.
// - Write: synchronous on clk when we=1
// - Read:  synchronous on clk when re=1 (rdata updates on clk edge)
// ============================================================

module block_buffer #(
  parameter int BLOCK_SIZE = 256,
  parameter int DATA_WIDTH = 64
)(
  input  logic                          clk,

  input  logic                          we,
  input  logic [$clog2(BLOCK_SIZE)-1:0] waddr,
  input  logic [DATA_WIDTH-1:0]         wdata,

  input  logic                          re,
  input  logic [$clog2(BLOCK_SIZE)-1:0] raddr,
  output logic [DATA_WIDTH-1:0]         rdata
);

  // Memory array
  logic [DATA_WIDTH-1:0] mem [0:BLOCK_SIZE-1];

  // Synchronous write
  always_ff @(posedge clk) begin
    if (we) begin
      mem[waddr] <= wdata;
    end
  end

  // Synchronous read (registered output)
  always_ff @(posedge clk) begin
    if (re) begin
      rdata <= mem[raddr];
    end
  end

endmodule