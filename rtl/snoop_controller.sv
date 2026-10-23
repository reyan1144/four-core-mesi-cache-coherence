module snoop_controller (
  input  logic                  clk,
  input  logic                  rst,

  input  logic                  snoop_valid,
  input  mesi_pkg::bus_cmd_t     snoop_cmd,
  input  mesi_pkg::addr_t        snoop_addr,

  output logic                  snoop_done,
  output logic                  snoop_has_copy,

  output mesi_pkg::index_t       array_index,
  input  mesi_pkg::tag_t         array_tag,
  input  mesi_pkg::line_t        array_data,
  input  mesi_pkg::mesi_state_t  array_state,

  output logic                  update_valid,
  input  logic                  update_ready,
  output mesi_pkg::index_t       update_index,
  output mesi_pkg::mesi_state_t  update_state,

  output logic                  dirty_valid,
  input  logic                  dirty_ready,
  output mesi_pkg::line_t        dirty_line,
  input  logic                  dirty_done
);

  import mesi_pkg::*;

  typedef enum logic [2:0] {
    IDLE,
    CHECK,
    DIRTY_REQ,
    DIRTY_WAIT,
    UPDATE,
    RESP
  } snoop_state_t;

  snoop_state_t state;

  addr_t saved_addr;
  bus_cmd_t saved_cmd;

  mesi_state_t saved_update_state;
  line_t saved_dirty_line;
  logic saved_has_copy;
  logic line_match;

  assign array_index = get_index(saved_addr);
  assign update_index = get_index(saved_addr);

  assign line_match =
    (array_state != MESI_I) &&
    (array_tag == get_tag(saved_addr));

  assign update_state = saved_update_state;

  assign update_valid =
    !rst && (state == UPDATE);

  assign dirty_valid =
    !rst && (state == DIRTY_REQ);

  assign dirty_line = saved_dirty_line;

  assign snoop_done =
    !rst && (state == RESP);

  assign snoop_has_copy =
    snoop_done && saved_has_copy;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;

      saved_addr <= '0;
      saved_cmd <= BUS_NONE;

      saved_has_copy <= 1'b0;
      saved_update_state <= MESI_I;
      saved_dirty_line <= '0;
    end else begin
      case (state)
        IDLE: begin
          if (snoop_valid) begin

            // Simulation-only snoop validation.
            // synthesis translate_off
            if (
              snoop_cmd !== BUS_RD &&
              snoop_cmd !== BUS_RDX &&
              snoop_cmd !== BUS_UPGR
            )
              $fatal(
                1,
                "Unsupported snoop command"
              );

            if ($isunknown(snoop_addr))
              $fatal(
                1,
                "Snoop address contains X/Z"
              );

            if (get_offset(snoop_addr) != '0)
              $fatal(
                1,
                "Snoop address must be line-aligned"
              );

            if (snoop_addr >= MEM_BYTES)
              $fatal(
                1,
                "Snoop address out of range"
              );
            // synthesis translate_on

            saved_addr <= snoop_addr;
            saved_cmd <= snoop_cmd;

            saved_has_copy <= 1'b0;
            saved_update_state <= MESI_I;

            state <= CHECK;
          end
        end

        CHECK: begin
          if (!line_match) begin
            saved_has_copy <= 1'b0;
            state <= RESP;
          end else begin
            saved_has_copy <= 1'b1;

            case (saved_cmd)
              BUS_RD: begin
                case (array_state)
                  MESI_S: begin
                    state <= RESP;
                  end

                  MESI_E: begin
                    saved_update_state <= MESI_S;
                    state <= UPDATE;
                  end

                  MESI_M: begin
                    saved_update_state <= MESI_S;
                    saved_dirty_line <= array_data;

                    state <= DIRTY_REQ;
                  end

                  default:
                    $fatal(
                      1,
                      "Unexpected state for BusRd"
                    );
                endcase
              end

              BUS_RDX: begin
                case (array_state)
                  MESI_S, MESI_E: begin
                    saved_update_state <= MESI_I;
                    state <= UPDATE;
                  end

                  MESI_M: begin
                    saved_update_state <= MESI_I;
                    saved_dirty_line <= array_data;

                    state <= DIRTY_REQ;
                  end

                  default:
                    $fatal(
                      1,
                      "Unexpected state for BusRdX"
                    );
                endcase
              end

              BUS_UPGR: begin
                case (array_state)
                  MESI_S: begin
                    saved_update_state <= MESI_I;
                    state <= UPDATE;
                  end

                  MESI_E, MESI_M:
                    $fatal(
                      1,
                      "BusUpgr conflicts with an E or M owner"
                    );

                  default:
                    $fatal(
                      1,
                      "Unexpected state for BusUpgr"
                    );
                endcase
              end

              default:
                $fatal(
                  1,
                  "Invalid captured snoop command"
                );
            endcase
          end
        end

        DIRTY_REQ: begin
          // Acceptance means the bus captured the dirty line.
          if (dirty_valid && dirty_ready)
            state <= DIRTY_WAIT;
        end

        DIRTY_WAIT: begin
          // Wait until the backing-memory write has completed.
          if (dirty_done)
            state <= UPDATE;
        end

        UPDATE: begin
          // Commit the downgrade/invalidation before acknowledging.
          if (update_valid && update_ready)
            state <= RESP;
        end

        RESP: begin
          state <= IDLE;
        end

        default:
          $fatal(
            1,
            "Invalid snoop-controller state"
          );
      endcase
    end
  end

endmodule