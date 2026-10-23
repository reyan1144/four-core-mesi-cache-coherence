module coherence_bus_ctrl (
  input logic clk,
  input logic rst,

  input logic owner_valid,
  input mesi_pkg::core_id_t owner_id,
  input mesi_pkg::bus_cmd_t owner_cmd,
  input mesi_pkg::addr_t owner_addr,
  input mesi_pkg::line_t owner_wline,

  output logic owner_accept,

  output logic [mesi_pkg::NUM_CORES-1:0] snoop_valid,
  output mesi_pkg::bus_cmd_t snoop_cmd,
  output mesi_pkg::addr_t snoop_addr,
  output mesi_pkg::core_id_t requester_id,

  input logic [mesi_pkg::NUM_CORES-1:0] snoop_done,
  input logic [mesi_pkg::NUM_CORES-1:0] snoop_has_copy,

  input logic [mesi_pkg::NUM_CORES-1:0] dirty_valid,
  output logic [mesi_pkg::NUM_CORES-1:0] dirty_ready,
  output logic [mesi_pkg::NUM_CORES-1:0] dirty_done,

  input logic
    [mesi_pkg::NUM_CORES-1:0][mesi_pkg::LINE_W-1:0] dirty_lines,

  output logic data_req_valid,
  input logic data_req_ready,

  output mesi_pkg::bus_cmd_t data_cmd,
  output mesi_pkg::addr_t data_addr,
  output mesi_pkg::line_t data_wline,

  input logic data_rsp_valid,
  output logic data_rsp_ready,
  input mesi_pkg::line_t data_rline,

  output logic completion_valid,
  input logic completion_ready,
  output mesi_pkg::line_t completion_line,

  output logic shared_seen,
  output logic release_bus
);

  import mesi_pkg::*;

  typedef enum logic [2:0] {
    IDLE,
    BROADCAST,
    COLLECT,
    DIRTY_WB_REQ,
    DIRTY_WB_WAIT,
    DATA_REQ,
    DATA_WAIT,
    COMPLETE
  } bus_state_t;

  bus_state_t state;

  core_id_t saved_owner;
  bus_cmd_t saved_cmd;
  addr_t saved_addr;
  line_t saved_wline;

  logic [NUM_CORES-1:0] initial_targets;
  logic [NUM_CORES-1:0] pending;
  logic [NUM_CORES-1:0] acknowledged;
  logic [NUM_CORES-1:0] remaining;
  logic [NUM_CORES-1:0] eligible_dirty;

  logic collecting;
  logic dirty_found;
  logic dirty_served;

  core_id_t dirty_choice;
  core_id_t saved_dirty_owner;
  line_t saved_dirty_line;

  always_comb begin
    initial_targets = '1;
    initial_targets[owner_id] = 1'b0;
  end

  assign acknowledged = pending & snoop_done;
  assign remaining = pending & ~snoop_done;
  assign eligible_dirty = pending & dirty_valid;

  always_comb begin
    dirty_found = 1'b0;
    dirty_choice = '0;

    for (int i = 0; i < NUM_CORES; i++) begin
      if (!dirty_found && eligible_dirty[i]) begin
        dirty_found = 1'b1;
        dirty_choice = core_id_t'(i);
      end
    end
  end

  assign collecting =
    (state == BROADCAST) ||
    (state == COLLECT) ||
    (state == DIRTY_WB_REQ) ||
    (state == DIRTY_WB_WAIT);

  assign owner_accept =
    !rst && (state == IDLE) && owner_valid;

  assign snoop_valid =
    (!rst && state == BROADCAST) ? pending : '0;

  assign snoop_cmd = saved_cmd;
  assign snoop_addr = saved_addr;
  assign requester_id = saved_owner;

  always_comb begin
    dirty_ready = '0;
    dirty_done = '0;

    if (!rst) begin
      if (
        state == COLLECT &&
        dirty_found &&
        !dirty_served
      )
        dirty_ready[dirty_choice] = 1'b1;

      if (
        state == DIRTY_WB_WAIT &&
        data_rsp_valid &&
        data_rsp_ready
      )
        dirty_done[saved_dirty_owner] = 1'b1;
    end
  end

  always_comb begin
    data_req_valid = 1'b0;
    data_rsp_ready = 1'b0;

    data_cmd = saved_cmd;
    data_addr = saved_addr;
    data_wline = saved_wline;

    if (!rst) begin
      case (state)
        DIRTY_WB_REQ: begin
          data_req_valid = 1'b1;
          data_cmd = BUS_WB;
          data_wline = saved_dirty_line;
        end

        DIRTY_WB_WAIT: begin
          data_cmd = BUS_WB;
          data_wline = saved_dirty_line;
          data_rsp_ready = 1'b1;
        end

        DATA_REQ: begin
          data_req_valid = 1'b1;
        end

        DATA_WAIT: begin
          data_rsp_ready = 1'b1;
        end

        default: begin end
      endcase
    end
  end

  assign completion_valid =
    !rst && (state == COMPLETE);

  assign release_bus =
    completion_valid && completion_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;

      saved_owner <= '0;
      saved_cmd <= BUS_NONE;
      saved_addr <= '0;
      saved_wline <= '0;

      pending <= '0;
      shared_seen <= 1'b0;
      completion_line <= '0;

      dirty_served <= 1'b0;
      saved_dirty_owner <= '0;
      saved_dirty_line <= '0;
    end else begin

      // Continue collecting acknowledgments during a dirty flush.
      if (collecting) begin
        pending <= remaining;

        shared_seen <=
          shared_seen |
          (|(acknowledged & snoop_has_copy));
      end

      case (state)
        IDLE: begin
          if (owner_accept) begin

            // Simulation-only bus request validation.
            // synthesis translate_off
            if (
              $isunknown(owner_id) ||
              $isunknown(owner_cmd) ||
              $isunknown(owner_addr)
            )
              $fatal(
                1,
                "Unknown bus owner, command, or address"
              );

            if (int'(owner_id) >= NUM_CORES)
              $fatal(
                1,
                "Invalid bus owner"
              );

            if (get_offset(owner_addr) != '0)
              $fatal(
                1,
                "Bus address must be line-aligned"
              );

            if (owner_addr >= MEM_BYTES)
              $fatal(
                1,
                "Bus address out of range"
              );
            // synthesis translate_on

            saved_owner <= owner_id;
            saved_cmd <= owner_cmd;
            saved_addr <= owner_addr;
            saved_wline <= owner_wline;

            shared_seen <= 1'b0;
            completion_line <= '0;
            dirty_served <= 1'b0;

            case (owner_cmd)
              BUS_RD, BUS_RDX, BUS_UPGR: begin
                pending <= initial_targets;
                state <= BROADCAST;
              end

              BUS_WB: begin
                pending <= '0;
                state <= DATA_REQ;
              end

              default:
                $fatal(
                  1,
                  "Unsupported bus command"
                );
            endcase
          end
        end

        BROADCAST: begin
          state <= COLLECT;
        end

        COLLECT: begin
          if (dirty_found) begin
            if (
              (eligible_dirty & (eligible_dirty - 1'b1)) != '0
            ) begin
              $fatal(
                1,
                "Multiple dirty owners for the same line"
              );
            end else if (dirty_served) begin
              $fatal(
                1,
                "Repeated dirty intervention in one transaction"
              );
            end else if (
              saved_cmd != BUS_RD &&
              saved_cmd != BUS_RDX
            ) begin
              $fatal(
                1,
                "Dirty intervention requires BusRd or BusRdX"
              );
            end else begin
              saved_dirty_owner <= dirty_choice;
              saved_dirty_line <= dirty_lines[dirty_choice];

              dirty_served <= 1'b1;
              state <= DIRTY_WB_REQ;
            end
          end else if (remaining == '0) begin
            if (saved_cmd == BUS_UPGR)
              state <= COMPLETE;
            else
              state <= DATA_REQ;
          end
        end

        DIRTY_WB_REQ: begin
          if (data_req_valid && data_req_ready)
            state <= DIRTY_WB_WAIT;
        end

        DIRTY_WB_WAIT: begin
          // dirty_done also notifies the supplying snoop controller.
          if (data_rsp_valid && data_rsp_ready)
            state <= COLLECT;
        end

        DATA_REQ: begin
          if (data_req_valid && data_req_ready)
            state <= DATA_WAIT;
        end

        DATA_WAIT: begin
          if (data_rsp_valid && data_rsp_ready) begin
            if (
              saved_cmd == BUS_RD ||
              saved_cmd == BUS_RDX
            )
              completion_line <= data_rline;

            state <= COMPLETE;
          end
        end

        COMPLETE: begin
          if (completion_valid && completion_ready)
            state <= IDLE;
        end

        default:
          $fatal(
            1,
            "Invalid bus-controller state"
          );
      endcase
    end
  end

endmodule