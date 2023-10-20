// Copyright 2022 ETH Zurich and University of Bologna.
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
// - Nicole Narr <narrn@ethz.ch>

/// Protocol adapter which translates memory requests to the AXI4-Lite protocol.
///
/// This module acts like an SRAM and makes AXI4-Lite requests downstream.
///
/// Supports multiple outstanding requests and will have responses for reads **and** writes.
/// Response latency is not fixed and for sure **not 1** and depends on the AXI4-Lite memory system.
/// The `mem_rsp_valid_o` can have multiple cycles of latency from the corresponding `mem_gnt_o`.
/// (Was called `mem_to_axi_lite` - originating from https://github.com/pulp-platform/snitch)
module axi_lite_from_mem #(
  /// Memory request address width.
  parameter int unsigned MemAddrWidth = 32'd0,
  /// AXI4-Lite address width.
  parameter int unsigned AxiAddrWidth = 32'd0,
  /// Data width in bit of the memory request data **and** the Axi4-Lite data channels.
  parameter int unsigned DataWidth = 32'd0,
  /// How many requests can be in flight at the same time. (Depth of the response mux FIFO).
  parameter int unsigned MaxRequests = 32'd0,
  /// Protection signal the module should emit on the AXI4-Lite transactions.
  parameter axi_pkg::prot_t AxiProt = 3'b000,
  /// AXI4-Lite request struct definition.
  parameter type axi_req_t = logic,
  /// AXI4-Lite response struct definition.
  parameter type axi_rsp_t = logic,
  /// Dependent parameter do **not** overwrite!
  ///
  /// Memory address type, derived from `MemAddrWidth`.
  parameter type mem_addr_t = logic[MemAddrWidth-1:0],
  /// Dependent parameter do **not** overwrite!
  ///
  /// AXI4-Lite address type, derived from `AxiAddrWidth`.
  parameter type axi_addr_t = logic[AxiAddrWidth-1:0],
  /// Dependent parameter do **not** overwrite!
  ///
  /// Data type for read and write data, derived from `DataWidth`.
  /// This is the same for the memory request side **and** the AXI4-Lite `W` and `R` channels.
  parameter type data_t = logic[DataWidth-1:0],
  /// Dependent parameter do **not** overwrite!
  ///
  /// Byte enable / AXI4-Lite strobe type, derived from `DataWidth`.
  parameter type strb_t = logic[DataWidth/8-1:0]
) (
  /// Clock input, positive edge triggered.
  input logic clk_i,
  /// Asynchronous reset, active low.
  input logic rst_ni,
  /// Memory slave port, request is active.
  input logic mem_req_i,
  /// Memory slave port, request address.
  ///
  /// Byte address, will be extended or truncated to match `AxiAddrWidth`.
  input mem_addr_t mem_addr_i,
  /// Memory slave port, request is a write.
  ///
  /// `0`: Read request.
  /// `1`: Write request.
  input logic mem_we_i,
  /// Memory salve port, write data for request.
  input data_t mem_wdata_i,
  /// Memory slave port, write byte enable for request.
  ///
  /// Active high.
  input strb_t mem_be_i,
  /// Memory request is granted.
  output logic mem_gnt_o,
  /// Memory slave port, response is valid. For each request, regardless if read or write,
  /// this will be active once for one cycle.
  output logic mem_rsp_valid_o,
  /// Memory slave port, response read data. This is forwarded directly from the AXI4-Lite
  /// `R` channel. Only valid for responses generated by a read request.
  output data_t mem_rsp_rdata_o,
  /// Memory request encountered an error. This is forwarded from the AXI4-Lite error response.
  output logic mem_rsp_error_o,
  /// AXI4-Lite master port, request output.
  output axi_req_t axi_req_o,
  /// AXI4-Lite master port, response input.
  input axi_rsp_t axi_rsp_i
);
  `include "common_cells/registers.svh"

  // Response FIFO control signals.
  logic fifo_full, fifo_empty;
  // Bookkeeping for sent write beats.
  logic aw_sent_q, aw_sent_d;
  logic w_sent_q,  w_sent_d;

  // Control for translating request to the AXI4-Lite `AW`, `W` and `AR` channels.
  always_comb begin
    // Default assignments.
    axi_req_o.aw       = '0;
    axi_req_o.aw.addr  = axi_addr_t'(mem_addr_i);
    axi_req_o.aw.prot  = AxiProt;
    axi_req_o.aw_valid = 1'b0;
    axi_req_o.w        = '0;
    axi_req_o.w.data   = mem_wdata_i;
    axi_req_o.w.strb   = mem_be_i;
    axi_req_o.w_valid  = 1'b0;
    axi_req_o.ar       = '0;
    axi_req_o.ar.addr  = axi_addr_t'(mem_addr_i);
    axi_req_o.ar.prot  = AxiProt;
    axi_req_o.ar_valid = 1'b0;
    // This is also the push signal for the response FIFO.
    mem_gnt_o          = 1'b0;
    // Bookkeeping about sent write channels.
    aw_sent_d          = aw_sent_q;
    w_sent_d           = w_sent_q;

    // Control for Request to AXI4-Lite translation.
    if (mem_req_i && !fifo_full) begin
      if (!mem_we_i) begin
        // It is a read request.
        axi_req_o.ar_valid = 1'b1;
        mem_gnt_o          = axi_rsp_i.ar_ready;
      end else begin
        // Is is a write request, decouple `AW` and `W` channels.
        unique case ({aw_sent_q, w_sent_q})
          2'b00 : begin
            // None of the AXI4-Lite writes have been sent jet.
            axi_req_o.aw_valid = 1'b1;
            axi_req_o.w_valid  = 1'b1;
            unique case ({axi_rsp_i.aw_ready, axi_rsp_i.w_ready})
              2'b01 : begin // W is sent, still needs AW.
                w_sent_d = 1'b1;
              end
              2'b10 : begin // AW is sent, still needs W.
                aw_sent_d = 1'b1;
              end
              2'b11 : begin // Both are transmitted, grant the write request.
                mem_gnt_o = 1'b1;
              end
              default : /* do nothing */;
            endcase
          end
          2'b10 : begin
            // W has to be sent.
            axi_req_o.w_valid = 1'b1;
            if (axi_rsp_i.w_ready) begin
              aw_sent_d = 1'b0;
              mem_gnt_o = 1'b1;
            end
          end
          2'b01 : begin
            // AW has to be sent.
            axi_req_o.aw_valid = 1'b1;
            if (axi_rsp_i.aw_ready) begin
              w_sent_d  = 1'b0;
              mem_gnt_o = 1'b1;
            end
          end
          default : begin
            // Failsafe go to IDLE.
            aw_sent_d = 1'b0;
            w_sent_d  = 1'b0;
          end
        endcase
      end
    end
  end

  `FFARN(aw_sent_q, aw_sent_d, 1'b0, clk_i, rst_ni)
  `FFARN(w_sent_q, w_sent_d, 1'b0, clk_i, rst_ni)

  // Select which response should be forwarded. `1` write response, `0` read response.
  logic rsp_sel;

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0        ), // No fallthrough for one cycle delay before ready on AXI.
    .DEPTH        ( MaxRequests ),
    .dtype        ( logic       )
  ) i_fifo_rsp_mux (
    .clk_i,
    .rst_ni,
    .flush_i    ( 1'b0            ),
    .testmode_i ( 1'b0            ),
    .full_o     ( fifo_full       ),
    .empty_o    ( fifo_empty      ),
    .usage_o    ( /*not used*/    ),
    .data_i     ( mem_we_i        ),
    .push_i     ( mem_gnt_o       ),
    .data_o     ( rsp_sel         ),
    .pop_i      ( mem_rsp_valid_o )
  );

  // Response selection control.
  // If something is in the FIFO, the corresponding channel is ready.
  assign axi_req_o.b_ready = !fifo_empty &&  rsp_sel;
  assign axi_req_o.r_ready = !fifo_empty && !rsp_sel;
  // Read data is directly forwarded.
  assign mem_rsp_rdata_o = axi_rsp_i.r.data;
  // Error is taken from the respective channel.
  assign mem_rsp_error_o = rsp_sel ?
      (axi_rsp_i.b.resp inside {axi_pkg::RESP_SLVERR, axi_pkg::RESP_DECERR}) :
      (axi_rsp_i.r.resp inside {axi_pkg::RESP_SLVERR, axi_pkg::RESP_DECERR});
  // Mem response is valid if the handshaking on the respective channel occurs.
  // Can not happen at the same time as ready is set from the FIFO.
  // This serves as the pop signal for the FIFO.
  assign mem_rsp_valid_o = (axi_rsp_i.b_valid && axi_req_o.b_ready) ||
                           (axi_rsp_i.r_valid && axi_req_o.r_ready);

  // synopsys translate_off
  `ifndef SYNTHESIS
  `ifndef VERILATOR
    initial begin : proc_assert
      assert (MemAddrWidth > 32'd0) else $fatal(1, "MemAddrWidth has to be greater than 0!");
      assert (AxiAddrWidth > 32'd0) else $fatal(1, "AxiAddrWidth has to be greater than 0!");
      assert (DataWidth inside {32'd32, 32'd64}) else
          $fatal(1, "DataWidth has to be either 32 or 64 bit!");
      assert (MaxRequests > 32'd0) else $fatal(1, "MaxRequests has to be greater than 0!");
      assert (AxiAddrWidth == $bits(axi_req_o.aw.addr)) else
          $fatal(1, "AxiAddrWidth has to match axi_req_o.aw.addr!");
      assert (AxiAddrWidth == $bits(axi_req_o.ar.addr)) else
          $fatal(1, "AxiAddrWidth has to match axi_req_o.ar.addr!");
      assert (DataWidth == $bits(axi_req_o.w.data)) else
          $fatal(1, "DataWidth has to match axi_req_o.w.data!");
      assert (DataWidth/8 == $bits(axi_req_o.w.strb)) else
          $fatal(1, "DataWidth / 8 has to match axi_req_o.w.strb!");
      assert (DataWidth == $bits(axi_rsp_i.r.data)) else
          $fatal(1, "DataWidth has to match axi_rsp_i.r.data!");
    end
    default disable iff (~rst_ni);
    assert property (@(posedge clk_i) (mem_req_i && !mem_gnt_o) |=> mem_req_i) else
        $fatal(1, "It is not allowed to deassert the request if it was not granted!");
    assert property (@(posedge clk_i) (mem_req_i && !mem_gnt_o) |=> $stable(mem_addr_i)) else
        $fatal(1, "mem_addr_i has to be stable if request is not granted!");
    assert property (@(posedge clk_i) (mem_req_i && !mem_gnt_o) |=> $stable(mem_we_i)) else
        $fatal(1, "mem_we_i has to be stable if request is not granted!");
    assert property (@(posedge clk_i) (mem_req_i && !mem_gnt_o) |=> $stable(mem_wdata_i)) else
        $fatal(1, "mem_wdata_i has to be stable if request is not granted!");
    assert property (@(posedge clk_i) (mem_req_i && !mem_gnt_o) |=> $stable(mem_be_i)) else
        $fatal(1, "mem_be_i has to be stable if request is not granted!");
  `endif
  `endif
  // synopsys translate_on
endmodule
