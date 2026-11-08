#!/usr/bin/env python3
"""Rewrite inst/pin -> inst:pin in an OpenROAD-estimated SPEF.

OpenROAD's estimate_parasitics -spef_file writes '*DELIMITER :' in the header
but joins instance and pin with '/', so standalone OpenSTA cannot match pins
and silently drops wire parasitics. The flat netlist has no '/' in names, so
the last '/' in a pin token is always the inst/pin separator.
Usage: fix_spef_delimiter.py in.spef out.spef
"""
import re
import sys

PIN = re.compile(r'(?<=\s)([^\s:/*]+)/([A-Za-z0-9_\[\]]+)(?=\s)')

src, dst = sys.argv[1], sys.argv[2]
with open(src) as fi, open(dst, "w") as fo:
    in_header = True
    for line in fi:
        if in_header:
            if line.startswith("*D_NET") or line.startswith("*NAME_MAP") or line.startswith("*PORTS"):
                in_header = False
            else:
                fo.write(line)
                continue
        fo.write(PIN.sub(r"\1:\2", line))
