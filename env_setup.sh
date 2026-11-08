#!/bin/bash
# Environment setup for VLSI Flow

# Set EDA tool paths (Update these paths to match your server/WSL setup)
export CADENCE_HOME=/opt/cadence
export SYNOPSYS_HOME=/opt/synopsys
export OPENROAD_HOME=/opt/openroad

# Set PDK path (e.g., ASAP7)
export PDK_ROOT=/opt/pdk/asap7

# Add tools to PATH
export PATH=$CADENCE_HOME/INNOVUS211/bin:$PATH
export PATH=$CADENCE_HOME/GENUS211/bin:$PATH
export PATH=$CADENCE_HOME/XCELIUM2209/bin:$PATH

echo "Micro-NVSwitch EDA Environment Initialized."
