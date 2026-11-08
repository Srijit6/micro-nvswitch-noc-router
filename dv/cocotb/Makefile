# ==============================================================================
# Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
# Makefile for Cocotb Verification Suite
# ==============================================================================

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

PWD = $(shell pwd)
REPO_ROOT = $(PWD)/../..

VERILOG_SOURCES = \
    $(REPO_ROOT)/rtl/include/router_pkg.v \
    $(REPO_ROOT)/rtl/blocks/vc_buffer.v \
    $(REPO_ROOT)/rtl/blocks/islip_arbiter.v \
    $(REPO_ROOT)/rtl/blocks/crossbar_8x8.v \
    $(REPO_ROOT)/rtl/blocks/sharp_alu.v \
    $(REPO_ROOT)/rtl/top/router_top.v

COMPILE_ARGS += -I$(REPO_ROOT)/rtl/include

TOPLEVEL = router_top
MODULE = test_router,test_router_fixes

PYTHONPATH := $(PWD)/tests:$(PYTHONPATH)
export PYTHONPATH

include $(shell cocotb-config --makefiles)/Makefile.sim
