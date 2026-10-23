`timescale 1ns / 1ps

module tb_directed_mesi;
  import mesi_pkg::*;

  logic clk, rst;

  logic [NUM_CORES-1:0] req_valid, req_ready, req_write;
  logic [NUM_CORES-1:0][ADDR_W-1:0] req_addr;
  logic [NUM_CORES-1:0][WORD_W-1:0] req_wdata;

  logic [NUM_CORES-1:0] rsp_valid, rsp_ready;
  logic [NUM_CORES-1:0][WORD_W-1:0] rsp_rdata;

  addr_t inspect_addr;

  wire [NUM_CORES-1:0][1:0] raw_state, line_state;
  wire [NUM_CORES-1:0][TAG_W-1:0] raw_tag;

  int unsigned core_requests, core_responses, bus_transactions;
  int unsigned memory_reads, memory_writes, dirty_flushes, releases;

  int unsigned accepted_upgrades [0:NUM_CORES-1];
  int unsigned accepted_rdx [0:NUM_CORES-1];
  int unsigned accepted_wb [0:NUM_CORES-1];
  int unsigned requests_per_core [0:NUM_CORES-1];
  int unsigned responses_per_core [0:NUM_CORES-1];

  int unsigned cases_passed, total_operations;
  logic pending_upgrade1_seen;

  localparam addr_t A = 32'h0000_0120;
  localparam addr_t B = 32'h0000_0220;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  four_core_top dut (
    .clk(clk),
    .rst(rst),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_write(req_write),
    .req_addr(req_addr),
    .req_wdata(req_wdata),
    .rsp_valid(rsp_valid),
    .rsp_ready(rsp_ready),
    .rsp_rdata(rsp_rdata)
  );

  // Day 12 scoreboard, assertions, and FSM coverage.
  mesi_monitor monitor (
    .clk(clk),
    .rst(rst)
  );

  // A different tag at the same index is not a copy of this line.
  function automatic logic [1:0] visible_state(
    input logic [1:0] state_value,
    input tag_t tag_value,
    input addr_t address
  );
    if ($isunknown(state_value)) return 2'bxx;
    if (state_value == MESI_I) return MESI_I;
    if ($isunknown(tag_value)) return 2'bxx;
    if (tag_value != get_tag(address)) return MESI_I;

    return state_value;
  endfunction

  generate
    for (genvar g = 0; g < NUM_CORES; g++) begin : observations
      assign raw_state[g] =
        dut.caches[g].cache_inst.arrays.state_array[
          get_index(inspect_addr)
        ];

      assign raw_tag[g] =
        dut.caches[g].cache_inst.arrays.tag_array[
          get_index(inspect_addr)
        ];

      assign line_state[g] =
        visible_state(raw_state[g], raw_tag[g], inspect_addr);
    end
  endgenerate

  // Count accepted requests, responses, and bus/memory activity.
  always @(posedge clk) begin
    if (rst) begin
      core_requests = 0;
      core_responses = 0;
      bus_transactions = 0;
      memory_reads = 0;
      memory_writes = 0;
      dirty_flushes = 0;
      releases = 0;
      pending_upgrade1_seen = 1'b0;

      for (int i = 0; i < NUM_CORES; i++) begin
        accepted_upgrades[i] = 0;
        accepted_rdx[i] = 0;
        accepted_wb[i] = 0;
        requests_per_core[i] = 0;
        responses_per_core[i] = 0;
      end
    end else begin
      for (int i = 0; i < NUM_CORES; i++) begin
        if (req_valid[i] && req_ready[i]) begin
          core_requests++;
          requests_per_core[i]++;
        end

        if (rsp_valid[i] && rsp_ready[i]) begin
          core_responses++;
          responses_per_core[i]++;
        end
      end

      if (dut.owner_accept) begin
        bus_transactions++;

        case (dut.owner_cmd)
          BUS_UPGR: accepted_upgrades[dut.owner_id]++;
          BUS_RDX:  accepted_rdx[dut.owner_id]++;
          BUS_WB:   accepted_wb[dut.owner_id]++;
          default: begin end
        endcase
      end

      if (dut.data_req_valid && dut.data_req_ready) begin
        case (dut.data_cmd)
          BUS_RD, BUS_RDX: memory_reads++;
          BUS_WB: memory_writes++;

          default:
            $fatal(1, "Unexpected data-phase command");
        endcase
      end

      if (|dut.dirty_done)
        dirty_flushes++;

      if (dut.release_bus)
        releases++;

      if (dut.requests[1] && dut.cache_cmd[1] == BUS_UPGR)
        pending_upgrade1_seen = 1'b1;
    end
  end

  task automatic tick;
    @(negedge clk);
    #1;
  endtask

  task automatic check(
    input logic condition,
    input string message
  );
    if (condition !== 1'b1)
      $fatal(1, "FAIL: %s", message);
  endtask

  // Start each test with invalid caches and zeroed backing memory.
  task automatic reset_case;
    tick();

    rst = 1'b1;
    req_valid = '0;
    req_write = '0;
    req_addr = '0;
    req_wdata = '0;
    rsp_ready = '0;
    inspect_addr = A;

    repeat (3) tick();

    rst = 1'b0;
    tick();
  endtask

  task automatic start_request(
    input int unsigned id,
    input logic write_en,
    input addr_t address,
    input word_t value
  );
    tick();

    req_addr[id] = address;
    req_wdata[id] = value;
    req_write[id] = write_en;
    req_valid[id] = 1'b1;
    rsp_ready[id] = 1'b0;

    do begin
      @(posedge clk);
    end while (req_ready[id] !== 1'b1);

    tick();

    req_valid[id] = 1'b0;
    req_write[id] = 1'b0;
  endtask

  task automatic finish_response(
    input int unsigned id,
    input word_t expected
  );
    while (rsp_valid[id] !== 1'b1)
      tick();

    check(
      rsp_rdata[id] === expected,
      $sformatf(
        "C%0d expected %h, received %h",
        id, expected, rsp_rdata[id]
      )
    );

    // Stall response acceptance to check stability.
    tick();

    check(
      rsp_valid[id] === 1'b1 &&
      rsp_rdata[id] === expected,
      "Response did not remain stable under backpressure"
    );

    rsp_ready[id] = 1'b1;
    tick();
    rsp_ready[id] = 1'b0;

    check(
      rsp_valid[id] === 1'b0,
      "Response did not clear after acceptance"
    );
  endtask

  task automatic read_word(
    input int unsigned id,
    input addr_t address,
    input word_t expected
  );
    start_request(id, 1'b0, address, '0);
    finish_response(id, expected);
  endtask

  task automatic write_word(
    input int unsigned id,
    input addr_t address,
    input word_t value
  );
    start_request(id, 1'b1, address, value);
    finish_response(id, '0);
  endtask

  task automatic expect_states(
    input addr_t address,
    input mesi_state_t s0, s1, s2, s3
  );
    inspect_addr = address;
    #1;

    check(
      line_state[0] === s0 &&
      line_state[1] === s1 &&
      line_state[2] === s2 &&
      line_state[3] === s3,
      $sformatf(
        "Wrong states for line %h: %b %b %b %b",
        address,
        line_state[0], line_state[1],
        line_state[2], line_state[3]
      )
    );
  endtask

  task automatic expect_owner(
    input int unsigned id,
    input addr_t address
  );
    inspect_addr = address;
    #1;

    for (int i = 0; i < NUM_CORES; i++) begin
      if (i == id) begin
        check(
          line_state[i] === MESI_M,
          "Writer did not obtain M"
        );
      end else begin
        check(
          line_state[i] === MESI_I,
          "Another cache retained a valid copy"
        );
      end
    end
  endtask

  task automatic finish_case(input string label_text);
    tick();

    check(
      core_requests == core_responses,
      "Lost or duplicated response"
    );

    for (int i = 0; i < NUM_CORES; i++) begin
      check(
        requests_per_core[i] == responses_per_core[i],
        "Per-core request/response mismatch"
      );
    end

    check(
      req_valid === '0 && rsp_valid === '0,
      "Unfinished core transaction"
    );

    check(
      dut.owner_valid === 1'b0 && dut.requests === '0,
      "Bus not idle after completed test"
    );

    check(
      bus_transactions == releases,
      "Missing or duplicate bus release"
    );

    total_operations += core_requests;
    cases_passed++;

    $display(
      "PASS %0d/11: %s (%0d core operations)",
      cases_passed, label_text, core_requests
    );
  endtask

  task automatic test_read_fill_and_hits;
    reset_case();

    read_word(0, A, '0);
    expect_states(A, MESI_E, MESI_I, MESI_I, MESI_I);

    check(
      bus_transactions == 1 && memory_reads == 1,
      "First read must miss"
    );

    read_word(0, A, '0);
    read_word(0, A + 4, '0);
    read_word(0, A + 8, '0);
    read_word(0, A + 12, '0);

    check(
      bus_transactions == 1 && memory_reads == 1,
      "Read hits used the bus"
    );

    finish_case(
      "Read miss fills E; repeated and same-line reads hit"
    );
  endtask

  task automatic test_silent_writes;
    reset_case();

    read_word(0, A, '0);

    write_word(0, A, 32'h1111_0000);
    expect_owner(0, A);

    write_word(0, A + 4, 32'h1111_0001);

    read_word(0, A, 32'h1111_0000);
    read_word(0, A + 4, 32'h1111_0001);

    check(
      bus_transactions == 1 && memory_writes == 0,
      "E/M write hits must not use the bus or write memory"
    );

    finish_case(
      "E-to-M and M write hits are silent"
    );
  endtask

  task automatic test_shared_readers;
    reset_case();

    read_word(0, A, '0);
    read_word(1, A, '0);

    expect_states(
      A, MESI_S, MESI_S, MESI_I, MESI_I
    );

    read_word(2, A, '0);
    read_word(3, A, '0);

    expect_states(
      A, MESI_S, MESI_S, MESI_S, MESI_S
    );

    finish_case(
      "Two and four readers obtain shared copies"
    );
  endtask

  task automatic test_shared_writer;
    reset_case();

    for (int i = 0; i < NUM_CORES; i++)
      read_word(i, A, '0);

    write_word(0, A, 32'h2222_0000);
    expect_owner(0, A);

    read_word(0, A, 32'h2222_0000);

    check(
      accepted_upgrades[0] == 1 &&
      memory_reads == 4,
      "Shared writer must upgrade without fetching data"
    );

    finish_case(
      "Shared writer invalidates every other sharer"
    );
  endtask

  task automatic test_dirty_read;
    reset_case();

    write_word(0, A, 32'h3333_0000);
    write_word(0, A + 4, 32'h3333_0001);

    check(
      dut.memory.memory[A >> OFFSET_W][0 +: WORD_W] === '0,
      "Memory should still be stale while line is M"
    );

    read_word(1, A, 32'h3333_0000);
    read_word(1, A + 4, 32'h3333_0001);

    expect_states(
      A, MESI_S, MESI_S, MESI_I, MESI_I
    );

    check(
      dirty_flushes == 1 && memory_writes == 1,
      "Remote dirty read must perform one intervention flush"
    );

    finish_case(
      "Remote read receives the latest modified line"
    );
  endtask

  task automatic test_dirty_ownership_transfer;
    reset_case();

    write_word(0, A, 32'h4444_0000);
    write_word(0, A + 4, 32'h4444_0001);
    write_word(2, A + 8, 32'h4444_0002);

    expect_owner(2, A);

    read_word(2, A, 32'h4444_0000);
    read_word(2, A + 4, 32'h4444_0001);
    read_word(2, A + 8, 32'h4444_0002);
    read_word(2, A + 12, '0);

    check(
      accepted_rdx[2] == 1 && dirty_flushes == 1,
      "Dirty ownership transfer did not use BusRdX and flush"
    );

    finish_case(
      "BusRdX transfers dirty ownership and preserves other words"
    );
  endtask

  task automatic test_dirty_eviction;
    reset_case();

    write_word(0, A, 32'h5555_0000);
    write_word(0, A + 4, 32'h5555_0001);

    read_word(0, B, '0);
    read_word(0, A, 32'h5555_0000);
    read_word(0, A + 4, 32'h5555_0001);

    check(
      accepted_wb[0] == 1 &&
      memory_writes == 1 &&
      dirty_flushes == 0,
      "Dirty eviction must use one normal writeback"
    );

    finish_case(
      "Dirty eviction followed by reload preserves data"
    );
  endtask

  task automatic test_write_ping_pong;
    word_t latest;

    reset_case();
    latest = '0;

    for (int round_id = 0; round_id < 3; round_id++) begin
      for (int i = 0; i < NUM_CORES; i++) begin
        latest = word_t'(
          32'h1000_0000 + round_id * NUM_CORES + i
        );

        write_word(i, A, latest);
        expect_owner(i, A);
        read_word(i, A, latest);
      end
    end

    for (int i = 0; i < NUM_CORES; i++)
      read_word(i, A, latest);

    expect_states(
      A, MESI_S, MESI_S, MESI_S, MESI_S
    );

    finish_case(
      "Four-core write ping-pong preserves the latest value"
    );
  endtask

  task automatic test_false_sharing;
    reset_case();

    // Each core writes a different word within the same cache line.
    for (int i = 0; i < NUM_CORES; i++) begin
      write_word(
        i,
        A + addr_t'(i * WORD_BYTES),
        word_t'(32'h2000_0000 + i)
      );
    end

    for (int i = 0; i < NUM_CORES; i++) begin
      for (int w = 0; w < WORDS_PER_LINE; w++) begin
        read_word(
          i,
          A + addr_t'(w * WORD_BYTES),
          word_t'(32'h2000_0000 + w)
        );
      end
    end

    expect_states(
      A, MESI_S, MESI_S, MESI_S, MESI_S
    );

    check(
      dirty_flushes == 4,
      "Unexpected false-sharing intervention count"
    );

    finish_case(
      "Different-word writes in one line preserve every word"
    );
  endtask

  task automatic test_conflict_addresses;
    reset_case();

    check(
      get_index(A) == get_index(B) &&
      get_tag(A) != get_tag(B),
      "Test addresses must conflict"
    );

    write_word(0, A, 32'hAAAA_0000);
    write_word(0, B, 32'hBBBB_0000);

    read_word(0, A, 32'hAAAA_0000);
    read_word(0, B, 32'hBBBB_0000);

    check(
      accepted_wb[0] == 2 && memory_writes == 2,
      "Conflict replacements lost a dirty writeback"
    );

    finish_case(
      "Same-index different-tag replacements preserve both lines"
    );
  endtask

  task automatic test_pending_upgrade;
    reset_case();

    read_word(0, A, '0);
    read_word(1, A, '0);

    expect_states(
      A, MESI_S, MESI_S, MESI_I, MESI_I
    );

    // Both writes enter the upgrade path together.
    // Round-robin priority selects Core 0 first after Core 1's read.
    tick();

    req_addr[0] = A;
    req_addr[1] = A + 4;

    req_wdata[0] = 32'hBEEF_0000;
    req_wdata[1] = 32'hCAFE_0001;

    req_write = 4'b0011;
    req_valid = 4'b0011;
    rsp_ready = '0;

    @(posedge clk);

    check(
      req_ready[1:0] === 2'b11,
      "Concurrent writes were not accepted"
    );

    tick();

    req_valid = '0;
    req_write = '0;

    finish_response(0, '0);
    finish_response(1, '0);

    check(
      pending_upgrade1_seen === 1'b1,
      "Pending-upgrade race did not occur"
    );

    check(
      accepted_upgrades[0] == 1 &&
      accepted_upgrades[1] == 0 &&
      accepted_rdx[1] == 1,
      "Invalidated pending upgrade did not retry as BusRdX"
    );

    expect_owner(1, A);

    read_word(1, A, 32'hBEEF_0000);
    read_word(1, A + 4, 32'hCAFE_0001);

    read_word(2, A, 32'hBEEF_0000);
    read_word(2, A + 4, 32'hCAFE_0001);

    finish_case(
      "Pending upgrade invalidated before grant retries safely"
    );
  endtask

  initial begin
    rst = 1'b1;

    req_valid = '0;
    req_write = '0;
    req_addr = '0;
    req_wdata = '0;
    rsp_ready = '0;

    inspect_addr = A;

    cases_passed = 0;
    total_operations = 0;

    test_read_fill_and_hits();
    test_silent_writes();
    test_shared_readers();
    test_shared_writer();
    test_dirty_read();
    test_dirty_ownership_transfer();
    test_dirty_eviction();
    test_write_ping_pong();
    test_false_sharing();
    test_conflict_addresses();
    test_pending_upgrade();

    check(
      cases_passed == 11,
      "Not all directed cases ran"
    );

    $display(
      "PASS: All %0d directed MESI tests passed.",
      cases_passed
    );

    $display(
      "Total completed core operations=%0d",
      total_operations
    );

    monitor.report();
    $finish;
  end

  initial begin
    #1000000;
    $fatal(
      1, "TIMEOUT: directed MESI suite did not complete"
    );
  end

endmodule