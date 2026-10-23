`timescale 1ns / 1ps

module tb_random_mesi;
  import mesi_pkg::*;

  localparam int OPS_PER_CORE = 250;
  localparam int MAX_TRANSACTION_CYCLES = 2000;

  logic clk, rst;

  logic [NUM_CORES-1:0] req_valid, req_ready, req_write;
  logic [NUM_CORES-1:0][ADDR_W-1:0] req_addr;
  logic [NUM_CORES-1:0][WORD_W-1:0] req_wdata;

  logic [NUM_CORES-1:0] rsp_valid, rsp_ready;
  logic [NUM_CORES-1:0][WORD_W-1:0] rsp_rdata;

  bit [NUM_CORES-1:0] done;

  int unsigned accepted [0:NUM_CORES-1];
  int unsigned completed [0:NUM_CORES-1];

  int unsigned core_stall_cycles;
  int unsigned memory_stall_cycles;
  int unsigned delayed_response_cycles;
  int unsigned contention_cycles;

  int unsigned bus_transactions;
  int unsigned memory_writes;
  int unsigned dirty_flushes;
  int unsigned seed;

  logic memory_pending;

  logic [NUM_CORES-1:0] sampled_req;
  logic [NUM_CORES-1:0] sampled_rsp;

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

  // Apply variable memory timing only to this test.
  defparam dut.memory.MAX_REQ_DELAY = 5;
  defparam dut.memory.MAX_RSP_DELAY = 9;
  defparam dut.memory.DELAY_SEED = 32'h1357_9BDF;

  mesi_random_monitor monitor (
    .clk(clk),
    .rst(rst)
  );

  // Each core has an independent, repeatable random sequence.
  function automatic logic [31:0] next_random(
    input logic [31:0] value
  );
    logic [31:0] x;

    x = value;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);

    return x;
  endfunction

  // Capture handshakes at the actual sampling edge.
  always @(posedge clk) begin
    if (rst) begin
      sampled_req = '0;
      sampled_rsp = '0;

      core_stall_cycles = 0;
      memory_stall_cycles = 0;
      delayed_response_cycles = 0;
      contention_cycles = 0;

      bus_transactions = 0;
      memory_writes = 0;
      dirty_flushes = 0;
      memory_pending = 0;

      for (int c = 0; c < NUM_CORES; c++) begin
        accepted[c] = 0;
        completed[c] = 0;
      end
    end else begin
      sampled_req = req_valid & req_ready;
      sampled_rsp = rsp_valid & rsp_ready;

      for (int c = 0; c < NUM_CORES; c++) begin
        if (sampled_req[c])
          accepted[c]++;

        if (sampled_rsp[c])
          completed[c]++;

        if (rsp_valid[c] && !rsp_ready[c])
          core_stall_cycles++;
      end

      if ($countones(dut.requests) > 1)
        contention_cycles++;

      if (dut.owner_accept)
        bus_transactions++;

      if (|dut.dirty_done)
        dirty_flushes++;

      if (dut.data_req_valid && !dut.data_req_ready)
        memory_stall_cycles++;

      if (memory_pending && !dut.data_rsp_valid)
        delayed_response_cycles++;

      if (dut.data_req_valid && dut.data_req_ready) begin
        if (memory_pending)
          $fatal(1, "Overlapping memory transactions");

        memory_pending = 1;

        if (dut.data_cmd == BUS_WB)
          memory_writes++;
      end

      if (dut.data_rsp_valid && dut.data_rsp_ready)
        memory_pending = 0;
    end
  end

  task automatic tick;
    @(negedge clk);
    #1;
  endtask

  task automatic drive_core(input int id);
    logic [31:0] random_state;
    addr_t address;

    int idle_cycles;
    int hold_cycles;
    int age;
    int mode;
    int line_number;
    int word_number;

    random_state = seed ^ (32'h9E37_79B9 * (id + 1));

    if (random_state == 0)
      random_state = 1;

    for (int op = 0; op < OPS_PER_CORE; op++) begin
      random_state = next_random(random_state);
      idle_cycles = int'(random_state % 5);

      repeat (idle_cycles) tick();

      random_state = next_random(random_state);
      mode = int'(random_state % 4);

      random_state = next_random(random_state);
      word_number = int'(random_state % WORDS_PER_LINE);

      random_state = next_random(random_state);

      case (mode)
        0: begin
          // All cores contend for the same word.
          address = 32'h0000_0120;
        end

        1: begin
          // Different words in the same line create false sharing.
          address =
            32'h0000_0120 +
            addr_t'(word_number * WORD_BYTES);
        end

        2: begin
          // Different tags map to the same direct-mapped index.
          line_number = int'(random_state % 4);

          address =
            32'h0000_0020 +
            addr_t'(line_number * NUM_LINES * LINE_BYTES) +
            addr_t'(word_number * WORD_BYTES);
        end

        default: begin
          // Exercise addresses throughout backing memory.
          line_number = int'(
            random_state % (MEM_BYTES / LINE_BYTES)
          );

          address = addr_t'(
            line_number * LINE_BYTES +
            word_number * WORD_BYTES
          );
        end
      endcase

      tick();

      req_addr[id] = address;

      random_state = next_random(random_state);
      req_write[id] = (random_state % 100) < 55;

      random_state = next_random(random_state);

      req_wdata[id] =
        random_state ^
        word_t'(op) ^
        word_t'(id << 28);

      req_valid[id] = 1'b1;
      rsp_ready[id] = 1'b0;

      // Keep the request stable until an actual handshake.
      age = 0;

      do begin
        tick();
        age++;

        if (age > MAX_TRANSACTION_CYCLES)
          $fatal(
            1,
            "Request timeout seed=%0d C%0d op=%0d",
            seed, id, op
          );
      end while (!sampled_req[id]);

      req_valid[id] = 1'b0;
      req_write[id] = 1'b0;

      while (rsp_valid[id] !== 1'b1) begin
        tick();
        age++;

        if (age > MAX_TRANSACTION_CYCLES)
          $fatal(
            1,
            "Response timeout seed=%0d C%0d op=%0d",
            seed, id, op
          );
      end

      // Randomly delay acceptance after the response becomes valid.
      random_state = next_random(random_state);
      hold_cycles = int'(random_state % 8);

      repeat (hold_cycles) tick();

      rsp_ready[id] = 1'b1;

      do begin
        tick();
      end while (!sampled_rsp[id]);

      rsp_ready[id] = 1'b0;
    end

    done[id] = 1'b1;
  endtask

  // Four independent drivers execute concurrently.
  generate
    for (genvar c = 0; c < NUM_CORES; c++) begin : drivers
      initial begin
        wait (rst === 1'b0);
        drive_core(c);
      end
    end
  endgenerate

  initial begin
    rst = 1'b1;

    req_valid = '0;
    req_write = '0;
    req_addr = '0;
    req_wdata = '0;
    rsp_ready = '0;
    done = '0;

    seed = 32'd12345;

    if ($value$plusargs("SEED=%d", seed)) begin end

    $display(
      "RANDOM TEST: seed=%0d operations/core=%0d",
      seed, OPS_PER_CORE
    );

    repeat (4) tick();

    rst = 1'b0;

    wait (&done);

    // Allow all outstanding protocol activity to drain.
    repeat (5) tick();

    for (int c = 0; c < NUM_CORES; c++) begin
      if (
        accepted[c] != OPS_PER_CORE ||
        completed[c] != OPS_PER_CORE
      )
        $fatal(
          1,
          "Operation count mismatch C%0d accepted=%0d completed=%0d",
          c, accepted[c], completed[c]
        );
    end

    if (
      req_valid !== '0 ||
      rsp_valid !== '0 ||
      dut.requests !== '0 ||
      dut.owner_valid !== 1'b0 ||
      memory_pending
    )
      $fatal(1, "Test did not drain");

    if (
      core_stall_cycles == 0 ||
      memory_stall_cycles == 0 ||
      delayed_response_cycles == 0 ||
      contention_cycles == 0 ||
      dirty_flushes == 0 ||
      memory_writes == 0
    )
      $fatal(
        1, "Required stress condition was not exercised"
      );

    monitor.report();

    $display(
      "STRESS: core_stalls=%0d memory_req_stalls=%0d memory_rsp_wait=%0d contention=%0d",
      core_stall_cycles,
      memory_stall_cycles,
      delayed_response_cycles,
      contention_cycles
    );

    $display(
      "TRAFFIC: bus=%0d memory_writes=%0d dirty_flushes=%0d",
      bus_transactions,
      memory_writes,
      dirty_flushes
    );

    $display(
      "PASS: seed=%0d all %0d concurrent core operations completed",
      seed, NUM_CORES * OPS_PER_CORE
    );

    $finish;
  end

  initial begin
    #2000000;

    $fatal(
      1,
      "Global random-test timeout seed=%0d",
      seed
    );
  end

endmodule