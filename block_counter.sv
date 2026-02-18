import qpu_pkg::*;

// ============================================================
// block_counter.sv
// This module is a simple counter for writing to memory when input is valid
// and keeping track of the current block
// ============================================================

module block_counter 
#(
    parameter int BLOCK_SIZE = 256
)
(
    input logic clk,
    input logic rst,
    input logic start_block,
    input logic valid_in,
    output logic block_done
);

logic [$clog2(BLOCK_SIZE)-1:0] wr_ptr;
logic done;

always_ff @(posedge clk) begin
    if (rst) begin
        wr_ptr <= 0;
        done <= 0;

    end else begin
        done <= 0;

        if (start_block) begin
            wr_ptr <= 0;
        end else if (valid_in) begin
            wr_ptr <= wr_ptr + 1;
            if (wr_ptr == BLOCK_SIZE-1) done <= 1;
        end
    end
end

assign block_done = done;

endmodule