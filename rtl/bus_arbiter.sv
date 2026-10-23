module bus_arbiter (
  input  logic                           clk,
  input  logic                           rst,

  input  logic [mesi_pkg::NUM_CORES-1:0]  requests,
  input  logic                           release_bus,

  output logic [mesi_pkg::NUM_CORES-1:0]  grants,
  output logic                           owner_valid,
  output mesi_pkg::core_id_t             owner_id
);

  import mesi_pkg::*;

  core_id_t next_priority;
  core_id_t selected_owner;

  logic found;
  int unsigned candidate;

  // Search from the core following the previous owner.
  always_comb begin
    found          = 1'b0;
    selected_owner = '0;
    candidate      = 0;

    for (int offset = 0; offset < NUM_CORES; offset++) begin
      candidate = (int'(next_priority) + offset) % NUM_CORES;

      if (!found && requests[candidate]) begin
        found          = 1'b1;
        selected_owner = core_id_t'(candidate);
      end
    end
  end

  // Decode the registered owner into a one-hot grant.
  always_comb begin
    grants = '0;

    if (!rst && owner_valid) begin
      grants[owner_id] = 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      owner_valid  <= 1'b0;
      owner_id     <= '0;
      next_priority <= '0;
    end else begin

      if (owner_valid) begin
        if (release_bus) begin
          owner_valid <= 1'b0;

          if (owner_id == core_id_t'(NUM_CORES - 1)) begin
            next_priority <= '0;
          end else begin
            next_priority <= owner_id + core_id_t'(1);
          end
        end
      end else begin
        if (found) begin
          owner_valid <= 1'b1;
          owner_id    <= selected_owner;
        end
      end

    end
  end

endmodule