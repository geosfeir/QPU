import qpu_pkg::*;

// ============================================================
// leading_zero_counter.sv
// Counts leading zeros in an unsigned vector.
// For in == 0, count = W.
// Example (W=8):
//   in=8'b0001_0100 -> count=3
//   in=8'b1000_0000 -> count=0
//   in=0            -> count=8
// ============================================================

module leading_zero_counter #(
    parameter int W = 32
  )(
    input  logic [W-1:0]             in,
    output logic [$clog2(W):0]       count
  );
  
    integer i;
    always_comb begin
      count = W[$clog2(W):0];
      for (i = W-1; i >= 0; i--) begin
        if (in[i]) begin
          count = (W-1 - i)[$clog2(W):0];
          break;
        end
      end
    end
  
  endmodule