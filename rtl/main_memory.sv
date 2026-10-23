module main_memory #(
  parameter int unsigned MAX_REQ_DELAY = 0,
  parameter int unsigned MAX_RSP_DELAY = 0,
  parameter logic [31:0] DELAY_SEED = 32'h1BAD_F00D
)(
  input logic clk,
  input logic rst,

  input logic req_valid,
  output logic req_ready,
  input logic req_write,
  input mesi_pkg::addr_t req_addr,
  input mesi_pkg::line_t req_wline,

  output logic rsp_valid,
  input logic rsp_ready,
  output mesi_pkg::line_t rsp_rline
);

  import mesi_pkg::*;

  localparam int unsigned MEM_LINES =
    MEM_BYTES / LINE_BYTES;

  line_t memory [0:MEM_LINES-1];

  typedef enum logic [1:0] {
    IDLE,
    WAIT_RSP,
    RESP
  } mem_state_t;

  mem_state_t state;

  logic [31:0] rng;
  int unsigned req_delay;
  int unsigned rsp_delay;

  // Repeatable pseudo-random sequence for memory timing.
  function automatic logic [31:0] advance(
    input logic [31:0] x
  );
    return {
      x[30:0],
      x[31] ^ x[21] ^ x[1] ^ x[0]
    };
  endfunction

  assign req_ready =
    !rst &&
    (state == IDLE) &&
    (req_delay == 0);

  assign rsp_valid =
    !rst && (state == RESP);

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      rsp_rline <= '0;

      rng <=
        (DELAY_SEED == 0) ? 32'h1 : DELAY_SEED;

      req_delay <=
        ((DELAY_SEED == 0) ? 32'h1 : DELAY_SEED) %
        (MAX_REQ_DELAY + 1);

      rsp_delay <= 0;

      for (int i = 0; i < MEM_LINES; i++)
        memory[i] <= '0;
    end else begin
      case (state)
        IDLE: begin
          if (req_valid && req_delay != 0)
            req_delay <= req_delay - 1;

          if (req_valid && req_ready) begin

            // Simulation-only memory request validation.
            // synthesis translate_off
            if ($isunknown(req_addr))
              $fatal(
                1,
                "Unknown memory address"
              );

            if (get_offset(req_addr) != '0)
              $fatal(
                1,
                "Unaligned memory address"
              );

            if (req_addr >= MEM_BYTES)
              $fatal(
                1,
                "Address out of range"
              );

            if ($isunknown(req_write))
              $fatal(
                1,
                "Unknown memory operation"
              );
            // synthesis translate_on

            if (req_write) begin
              memory[req_addr >> OFFSET_W] <= req_wline;
              rsp_rline <= '0;
            end else begin
              rsp_rline <= memory[req_addr >> OFFSET_W];
            end

            rng <= advance(rng);
            rsp_delay <= rng % (MAX_RSP_DELAY + 1);

            if (rng % (MAX_RSP_DELAY + 1) == 0)
              state <= RESP;
            else
              state <= WAIT_RSP;
          end
        end

        WAIT_RSP: begin
          if (rsp_delay == 1) begin
            rsp_delay <= 0;
            state <= RESP;
          end else begin
            rsp_delay <= rsp_delay - 1;
          end
        end

        RESP: begin
          // Hold the response until it is accepted.
          if (rsp_valid && rsp_ready) begin
            req_delay <= rng % (MAX_REQ_DELAY + 1);
            rng <= advance(rng);

            state <= IDLE;
          end
        end

        default:
          $fatal(
            1,
            "Invalid memory state"
          );
      endcase
    end
  end

endmodule