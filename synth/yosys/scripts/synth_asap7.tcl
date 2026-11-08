# ==============================================================================
# Project Micro-NVSwitch: Yosys synthesis mapped to ASAP7 RVT (TT corner)
# Run: yosys -c synth_asap7.tcl   (env from flow/asap7_env.sh)
# ==============================================================================
yosys -import

set top   $::env(DESIGN_NAME)
set rtl   /work/rtl
set libs  [split [string trim [regsub -all {\s+} $::env(LIB_FILES) " "]] " "]
set rpt   /work/synth/yosys/reports
file mkdir $rpt /work/synth/yosys/mapped

set lib_args ""
foreach l $libs { append lib_args " -liberty $l" }
set dont_use_args ""
foreach c $::env(DONT_USE_CELLS) { append dont_use_args " -dont_use $c" }

foreach l $libs { read_liberty -lib -overwrite $l }

foreach f [list include/router_pkg.v blocks/vc_buffer.v blocks/islip_arbiter.v \
               blocks/crossbar_8x8.v blocks/sharp_alu.v top/router_top.v] {
    read_verilog -defer -I$rtl/include $rtl/$f
}
hierarchy -check -top $top

synth -top $top -noshare
opt -purge

# Sequential mapping (async-reset flops -> DFFASRHQNx1, others -> DFFHQNx*)
eval dfflibmap $lib_args $dont_use_args
opt

# Combinational mapping, timing-driven to the 800 ps clock
set fh [open /work/build/abc.constr w]
puts $fh "set_driving_cell $::env(MIN_BUF_CELL)"
puts $fh "set_load 3.898"
close $fh
eval abc -D $::env(CLOCK_PERIOD_PS) -constr /work/build/abc.constr $lib_args $dont_use_args

# Flatten only after technology mapping (keeps peak memory low on 3 GB host)
flatten
opt_clean -purge
setundef -zero
splitnets
hilomap -singleton -hicell $::env(TIEHI_CELL) H -locell $::env(TIELO_CELL) L
insbuf -buf $::env(MIN_BUF_CELL) A Y
opt_clean -purge

eval tee -o $rpt/synth_asap7_stat.rpt stat $lib_args
tee -o $rpt/synth_asap7_check.rpt check
write_verilog -noattr -noexpr -nohex -nodec $::env(SYNTH_NETLIST)
