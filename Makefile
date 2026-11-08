# ==============================================================================
# Master Makefile for Project Micro-NVSwitch RTL-to-GDSII Flow
# ==============================================================================

PROJECT   ?= router_top
TOOL      ?= yosys     # synth: yosys | genus | dc; pnr: openroad | innovus
SIM       ?= icarus

RTL_DIR   = rtl
DV_DIR    = dv
SYNTH_DIR = synth
PNR_DIR   = pnr

.PHONY: all lint sim cocotb test synth pnr clean help

all: lint test synth

help:
	@echo "Project Micro-NVSwitch Build System"
	@echo "  make lint        - Run Verilator lint checks on RTL"
	@echo "  make sim         - Run standalone Verilog regression testbench"
	@echo "  make cocotb      - Run Cocotb test suite"
	@echo "  make test        - Run both standalone and Cocotb test suites"
	@echo "  make synth       - Run synthesis (TOOL=yosys | genus | dc)"
	@echo "  make pnr         - Run PnR flow (TOOL=openroad | innovus)"
	@echo "  make asap7-flow  - Yosys(ASAP7) -> OpenROAD PnR -> OpenSTA -> GUI"
	@echo "  make clean       - Clean temporary build artifacts"

lint:
	@echo "=== Linting RTL with Verilator ==="
	verilator --lint-only -Wall -I$(RTL_DIR)/include \
		$(RTL_DIR)/include/router_pkg.v \
		$(RTL_DIR)/blocks/vc_buffer.v \
		$(RTL_DIR)/blocks/islip_arbiter.v \
		$(RTL_DIR)/blocks/crossbar_8x8.v \
		$(RTL_DIR)/blocks/sharp_alu.v \
		$(RTL_DIR)/top/router_top.v \
		--top-module $(PROJECT)
	@echo "Lint check passed successfully!"

sim:
	@echo "=== Running Standalone Verilog Testbench ==="
	iverilog -Wall -I$(RTL_DIR)/include -o /tmp/router_tb.vvp \
		$(RTL_DIR)/include/router_pkg.v \
		$(RTL_DIR)/blocks/vc_buffer.v \
		$(RTL_DIR)/blocks/islip_arbiter.v \
		$(RTL_DIR)/blocks/crossbar_8x8.v \
		$(RTL_DIR)/blocks/sharp_alu.v \
		$(RTL_DIR)/top/router_top.v \
		$(DV_DIR)/common/tb_router_top.v
	vvp /tmp/router_tb.vvp

cocotb:
	@echo "=== Running Cocotb Test Suite ==="
	cd $(DV_DIR)/cocotb && make

test: sim cocotb

synth:
	@echo "=== Running Synthesis using $(TOOL) ==="
	@if [ "$(TOOL)" = "genus" ]; then \
		cd $(SYNTH_DIR)/genus && genus -f scripts/genus.tcl; \
	elif [ "$(TOOL)" = "dc" ]; then \
		cd $(SYNTH_DIR)/dc && dc_shell-t -f scripts/dc.tcl; \
	elif [ "$(TOOL)" = "yosys" ]; then \
		cd $(SYNTH_DIR)/yosys && yosys scripts/synth.ys; \
	else \
		echo "Unknown synthesis tool: $(TOOL)"; exit 1; \
	fi

pnr:
	@echo "=== Running PnR using $(TOOL) ==="
	@if [ "$(TOOL)" = "innovus" ]; then \
		cd $(PNR_DIR)/innovus && innovus -init scripts/innovus.tcl; \
	elif [ "$(TOOL)" = "openroad" ]; then \
		cd $(PNR_DIR)/openroad && openroad scripts/flow.tcl; \
	else \
		echo "Unknown PnR tool: $(TOOL)"; exit 1; \
	fi

# ------------------------------------------------------------------------------
# Open-source ASAP7 flow (Yosys -> OpenROAD -> OpenSTA) via OpenLane2 container
# ------------------------------------------------------------------------------
.PHONY: asap7-synth asap7-pnr asap7-sta asap7-gui asap7-flow
asap7-synth:
	flow/run_flow.sh synth
asap7-pnr:
	flow/run_flow.sh floorplan place cts route finish
asap7-sta:
	flow/run_flow.sh sta
asap7-gui:
	flow/run_flow.sh gui
asap7-flow:
	flow/run_flow.sh synth floorplan place cts route finish sta gui

clean:
	@echo "=== Cleaning Build Artifacts ==="
	rm -rf /tmp/router_tb.vvp /tmp/router_tb.vcd /tmp/router_synth.vvp
	rm -rf $(DV_DIR)/cocotb/sim_build $(DV_DIR)/cocotb/results.xml $(DV_DIR)/cocotb/__pycache__
	rm -rf $(SYNTH_DIR)/yosys/mapped/* $(SYNTH_DIR)/yosys/reports/*
	rm -rf $(SYNTH_DIR)/genus/mapped/* $(SYNTH_DIR)/genus/reports/*
	rm -rf $(PNR_DIR)/innovus/db/* $(PNR_DIR)/innovus/outputs/* $(PNR_DIR)/innovus/reports/*
	@echo "Clean complete."
