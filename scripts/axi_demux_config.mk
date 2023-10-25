DESIGN_CONFIG_PATH ?= .
RTL_SV_SRC ?=
RTL_SV_INCDIRS ?=

RTL_ROOT := $(PULP_COMMON_PATH)/src

RTL_SV_SRC += $(RTL_ROOT)/cf_math_pkg.sv
RTL_SV_SRC += $(RTL_ROOT)/spill_register.sv
RTL_SV_SRC += $(RTL_ROOT)/spill_register_flushable.sv
RTL_SV_SRC += $(RTL_ROOT)/counter.sv
RTL_SV_SRC += $(RTL_ROOT)/delta_counter.sv
RTL_SV_SRC += $(RTL_ROOT)/rr_arb_tree.sv
RTL_SV_SRC += $(RTL_ROOT)/addr_decode_dync.sv
RTL_SV_SRC += $(RTL_ROOT)/addr_decode.sv
RTL_SV_SRC += $(RTL_ROOT)/lzc.sv

RTL_ROOT := $(DESIGN_CONFIG_PATH)/../src

RTL_SV_SRC += $(RTL_ROOT)/axi_pkg.sv
RTL_SV_SRC += $(RTL_ROOT)/axi_err_slv.sv
RTL_SV_SRC += $(RTL_ROOT)/axi_demux_simple.sv
RTL_SV_SRC += $(RTL_ROOT)/axi_demux.sv

RTL_SV_DEFINES +=

RTL_SV_INCDIRS += $(DESIGN_CONFIG_PATH)/../include
RTL_SV_INCDIRS += $(PULP_COMMON_PATH)/include

RTL_TOP := axi_demux