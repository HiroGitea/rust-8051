#!/usr/bin/env python3
"""Rewrites llvm-cbe output for SDCC.

SDCC 4.6.0 miscompiles *(T*)(&((T*)p)[i]) through a generic pointer (see
sdcc-bug/repro.c); llvm-cbe emits exactly that for every load, so turn it
into the equivalent ((T*)p)[i].
Usage: cbe_fix.py in.c out.c
"""
import re
import sys

src = open(sys.argv[1]).read()
pat = re.compile(r'\*\((\w+)\*\)\(\(\(&\(\((\w+)\*\)(\w+)\)\[(\(\(int16_t\)\w+\))\]\)\)\)')
out, n = pat.subn(r'((\2*)\3)[\4]', src)
open(sys.argv[2], 'w').write(out)
print(f"{n} loads rewritten", file=sys.stderr)
