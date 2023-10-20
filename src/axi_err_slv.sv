// Copyright 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Authors:
// - Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
// - Andreas Kurth <akurth@iis.ee.ethz.ch>
// - Matheus Cavalcante <matheusd@iis.ee.ethz.ch>

// AXI Error Slave: This module always responds with an AXI error for transactions that are sent to
// it.  This module optionally supports ATOPs if the `ATOPs` parameter is set.

module axi_err_slv #(
  parameter int unsigned          AxiIdWidth  = 0,                    // AXI ID Width
  parameter type                  axi_req_t   = logic,                // AXI 4 request struct, with atop field
  parameter type                  axi_resp_t  = logic,                // AXI 4 response struct
  parameter axi_pkg::resp_t       Resp        = axi_pkg::RESP_DECERR, // Error generated by this slave.
  parameter int unsigned          RespWidth   = 32'd64,               // Data response width, gets zero extended or truncated to r.data.
  parameter logic [RespWidth-1:0] RespData    = 64'hCA11AB1EBADCAB1E, // Hexvalue for data return value
  parameter bit                   ATOPs       = 1'b1,                 // Activate support for ATOPs.  Set to 1 if this slave could ever get an atomic AXI transaction.
  parameter int unsigned          MaxTrans    = 1                     // Maximum # of accepted transactions before stalling
) (
  input  logic      clk_i,   // Clock
  input  logic      rst_ni,  // Asynchronous reset active low
  input  logic      test_i,  // Testmode enable
  // slave port
  input  axi_req_t  slv_req_i,
  output axi_resp_t slv_resp_o
);
  typedef logic [AxiIdWidth-1:0] id_t;
  typedef struct packed {
    id_t           id;
    axi_pkg::len_t len;
  } r_data_t;

  axi_req_t   err_req;
  axi_resp_t  err_resp;

  if (ATOPs) begin
    axi_atop_filter #(
      .AxiIdWidth       ( AxiIdWidth  ),
      .AxiMaxWriteTxns  ( MaxTrans    ),
      .axi_req_t        ( axi_req_t   ),
      .axi_resp_t       ( axi_resp_t  )
    ) i_atop_filter (
      .clk_i,
      .rst_ni,
      .slv_req_i  ( slv_req_i   ),
      .slv_resp_o ( slv_resp_o  ),
      .mst_req_o  ( err_req     ),
      .mst_resp_i ( err_resp    )
    );
  end else begin
    assign err_req    = slv_req_i;
    assign slv_resp_o = err_resp;
  end

  // w fifo
  logic    w_fifo_full, w_fifo_empty;
  logic    w_fifo_push, w_fifo_pop;
  id_t     w_fifo_data;
  // b fifo
  logic    b_fifo_full, b_fifo_empty;
  logic    b_fifo_push, b_fifo_pop;
  id_t     b_fifo_data;
  // r fifo
  r_data_t r_fifo_inp;
  logic    r_fifo_full, r_fifo_empty;
  logic    r_fifo_push, r_fifo_pop;
  r_data_t r_fifo_data;
  // r counter
  logic    r_cnt_clear, r_cnt_en, r_cnt_load;
  axi_pkg::len_t r_current_beat;
  // r status
  logic    r_busy_d, r_busy_q, r_busy_load;

  //--------------------------------------
  // Write Transactions
  //--------------------------------------
  // push, when there is room in the fifo
  assign w_fifo_push        = err_req.aw_valid & ~w_fifo_full;
  assign err_resp.aw_ready  = ~w_fifo_full;

  fifo_v3 #(
    .FALL_THROUGH ( 1'b1      ),
    .DEPTH        ( MaxTrans  ),
    .dtype        ( id_t      )
  ) i_w_fifo (
    .clk_i      ( clk_i             ),
    .rst_ni     ( rst_ni            ),
    .flush_i    ( 1'b0              ),
    .testmode_i ( test_i            ),
    .full_o     ( w_fifo_full       ),
    .empty_o    ( w_fifo_empty      ),
    .usage_o    (                   ),
    .data_i     ( err_req.aw.id     ),
    .push_i     ( w_fifo_push       ),
    .data_o     ( w_fifo_data       ),
    .pop_i      ( w_fifo_pop        )
  );

  always_comb begin : proc_w_channel
    err_resp.w_ready  = 1'b0;
    w_fifo_pop        = 1'b0;
    b_fifo_push       = 1'b0;
    if (!w_fifo_empty && !b_fifo_full) begin
      // eat the beats
      err_resp.w_ready = 1'b1;
      // on the last w transaction
      if (err_req.w_valid && err_req.w.last) begin
        w_fifo_pop    = 1'b1;
        b_fifo_push   = 1'b1;
      end
    end
  end

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0         ),
    .DEPTH        ( unsigned'(2) ), // two placed so that w can eat beats if b is not sent
    .dtype        ( id_t         )
  ) i_b_fifo (
    .clk_i      ( clk_i        ),
    .rst_ni     ( rst_ni       ),
    .flush_i    ( 1'b0         ),
    .testmode_i ( test_i       ),
    .full_o     ( b_fifo_full  ),
    .empty_o    ( b_fifo_empty ),
    .usage_o    (              ),
    .data_i     ( w_fifo_data  ),
    .push_i     ( b_fifo_push  ),
    .data_o     ( b_fifo_data  ),
    .pop_i      ( b_fifo_pop   )
  );

  always_comb begin : proc_b_channel
    b_fifo_pop        = 1'b0;
    err_resp.b        = '0;
    err_resp.b.id     = b_fifo_data;
    err_resp.b.resp   = Resp;
    err_resp.b_valid  = 1'b0;
    if (!b_fifo_empty) begin
      err_resp.b_valid = 1'b1;
      // b transaction
      b_fifo_pop = err_req.b_ready;
    end
  end

  //--------------------------------------
  // Read Transactions
  //--------------------------------------
  // push if there is room in the fifo
  assign r_fifo_push        = err_req.ar_valid & ~r_fifo_full;
  assign err_resp.ar_ready  = ~r_fifo_full;

  // fifo data assignment
  assign r_fifo_inp.id  = err_req.ar.id;
  assign r_fifo_inp.len = err_req.ar.len;

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0      ),
    .DEPTH        ( MaxTrans  ),
    .dtype        ( r_data_t  )
  ) i_r_fifo (
    .clk_i     ( clk_i        ),
    .rst_ni    ( rst_ni       ),
    .flush_i   ( 1'b0         ),
    .testmode_i( test_i       ),
    .full_o    ( r_fifo_full  ),
    .empty_o   ( r_fifo_empty ),
    .usage_o   (              ),
    .data_i    ( r_fifo_inp   ),
    .push_i    ( r_fifo_push  ),
    .data_o    ( r_fifo_data  ),
    .pop_i     ( r_fifo_pop   )
  );

  always_comb begin : proc_r_channel
    // default assignments
    r_busy_d    = r_busy_q;
    r_busy_load = 1'b0;
    // r fifo signals
    r_fifo_pop  = 1'b0;
    // r counter signals
    r_cnt_clear = 1'b0;
    r_cnt_en    = 1'b0;
    r_cnt_load  = 1'b0;
    // r_channel
    err_resp.r        = '0;
    err_resp.r.id     = r_fifo_data.id;
    err_resp.r.data   = RespData;
    err_resp.r.resp   = Resp;
    err_resp.r_valid  = 1'b0;
    // control
    if (r_busy_q) begin
      err_resp.r_valid = 1'b1;
      err_resp.r.last = (r_current_beat == '0);
      // r transaction
      if (err_req.r_ready) begin
        r_cnt_en = 1'b1;
        if (r_current_beat == '0) begin
          r_busy_d    = 1'b0;
          r_busy_load = 1'b1;
          r_cnt_clear = 1'b1;
          r_fifo_pop  = 1'b1;
        end
      end
    end else begin
      // when not busy and fifo not empty, start counter err gen
      if (!r_fifo_empty) begin
        r_busy_d    = 1'b1;
        r_busy_load = 1'b1;
        r_cnt_load  = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      r_busy_q <= '0;
    end else if (r_busy_load) begin
      r_busy_q <= r_busy_d;
    end
  end

  counter #(
    .WIDTH     ($bits(axi_pkg::len_t))
  ) i_r_counter (
    .clk_i     ( clk_i           ),
    .rst_ni    ( rst_ni          ),
    .clear_i   ( r_cnt_clear     ),
    .en_i      ( r_cnt_en        ),
    .load_i    ( r_cnt_load      ),
    .down_i    ( 1'b1            ),
    .d_i       ( r_fifo_data.len ),
    .q_o       ( r_current_beat  ),
    .overflow_o(                 )
  );

  // synopsys translate_off
  `ifndef VERILATOR
  `ifndef XSIM
  initial begin
    assert (Resp == axi_pkg::RESP_DECERR || Resp == axi_pkg::RESP_SLVERR) else
      $fatal(1, "This module may only generate RESP_DECERR or RESP_SLVERR responses!");
  end
  default disable iff (!rst_ni);
  if (!ATOPs) begin : gen_assert_atops_unsupported
    assume property( @(posedge clk_i) (slv_req_i.aw_valid |-> slv_req_i.aw.atop == '0)) else
     $fatal(1, "Got ATOP but not configured to support ATOPs!");
  end
  `endif
  `endif
  // synopsys translate_on

endmodule
