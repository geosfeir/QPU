import qpu_pkg::*;

// ============================================================
// normalize_round.sv
// Arithmetic right-shift by shift_amt, then round-to-nearest-even down to MANT_WIDTH bits.
//
// Intended use:
//   normalize_round(in_val=WORK_WIDTH signed, shift_amt=shift_amt_q) -> mant_out(MANT_WIDTH signed)
//
// Notes:
// - Handles negative values correctly via >>>
// - Includes saturating clamp if rounding overflows mantissa range
// - If shift_amt is large, result collapses toward 0 (sign-extended)
// ============================================================

module normalize_round #(
    parameter int WORK_WIDTH = 32,
    parameter int MANT_WIDTH = 24
  )(
    input  logic signed [WORK_WIDTH-1:0]            in_val,
    input  logic        [$clog2(WORK_WIDTH):0]      shift_amt,
    output logic signed [MANT_WIDTH-1:0]            mant_out
  );
  
    localparam int DROP = WORK_WIDTH - MANT_WIDTH;
  
    // After shifting, we "drop" DROP LSBs and round based on guard/sticky.
    logic signed [WORK_WIDTH-1:0] shifted;
  
    logic signed [MANT_WIDTH-1:0] mant_trunc;
    logic                         guard;
    logic                         sticky;
    logic                         lsb;       // LSB of mant_trunc for ties-to-even
    logic                         round_up;
  
    // For saturation after rounding overflow
    localparam logic signed [MANT_WIDTH-1:0] MANT_MAX = {1'b0, {(MANT_WIDTH-1){1'b1}}};
    localparam logic signed [MANT_WIDTH-1:0] MANT_MIN = {1'b1, {(MANT_WIDTH-1){1'b0}}};
  
    // Shift first (arithmetic)
    always_comb begin
      // If shift_amt >= WORK_WIDTH, >>> in SV will sign-extend and yield all 0s or all 1s.
      shifted = in_val >>> shift_amt;
    end
  
    // Extract mantissa/trunc + rounding bits from shifted
    generate
      if (DROP == 0) begin : gen_no_drop
        always_comb begin
          mant_trunc = shifted[MANT_WIDTH-1:0];
          guard      = 1'b0;
          sticky     = 1'b0;
          lsb        = mant_trunc[0];
          round_up   = 1'b0;
        end
      end else begin : gen_drop
        always_comb begin
          // Take the top MANT_WIDTH bits (preserve sign) by slicing from MSB side.
          mant_trunc = shifted[WORK_WIDTH-1 -: MANT_WIDTH];
  
          // Guard bit is the next bit below the truncated mantissa
          guard = shifted[DROP-1];
  
          // Sticky is OR of all bits below guard (if any)
          if (DROP > 1)
            sticky = |shifted[DROP-2:0];
          else
            sticky = 1'b0;
  
          lsb      = mant_trunc[0];
          // Round to nearest even:
          // - if guard=0 => no round
          // - if guard=1 and (sticky=1 or lsb=1) => round up
          round_up = guard && (sticky || lsb);
        end
      end
    endgenerate
  
    // Apply rounding with saturation
    always_comb begin
      logic signed [MANT_WIDTH:0] sum; // one extra bit to detect overflow
      sum = {mant_trunc[MANT_WIDTH-1], mant_trunc} + (round_up ? {{MANT_WIDTH{1'b0}},1'b1} : '0);
  
      // Saturate if rounding overflowed beyond representable signed range
      // Overflow detection for signed add of +1:
      // If mant_trunc is positive and becomes negative => overflow high -> clamp to MAX
      // If mant_trunc is negative and becomes positive => overflow low (won't happen with +1 unless at MIN) -> clamp to MIN
      if (!mant_trunc[MANT_WIDTH-1] && sum[MANT_WIDTH-1]) begin
        mant_out = MANT_MAX;
      end else if (mant_trunc[MANT_WIDTH-1] && !sum[MANT_WIDTH-1] && (mant_trunc == MANT_MIN)) begin
        mant_out = MANT_MIN;
      end else begin
        mant_out = sum[MANT_WIDTH-1:0];
      end
    end
  
  endmodule