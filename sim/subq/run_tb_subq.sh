#!/bin/sh
# Runs the real-subq testbenches. Needs GHDL (VHDL-2008) and Icarus Verilog in PATH.
set -e
cd "$(dirname "$0")"
R=../../rtl
M=../system/src/mem
mkdir -p work/mem work/psx && cd work
rm -rf *.cf mem/* psx/*
ghdl -a --std=08 -frelaxed --work=mem --workdir=mem ../$R/SyncFifo.vhd ../$R/SyncFifoFallThrough.vhd ../$M/dpram.vhd
ghdl -a --std=08 -frelaxed --work=psx --workdir=psx -Pmem ../$M/dpram.vhd ../$R/cd_xa_zigzag.vhd ../$R/cd_xa.vhd ../$R/cd_top.vhd
ghdl -a --std=08 -frelaxed --work=work -Pmem -Ppsx ../tb_subq.vhd
ghdl -e --std=08 -frelaxed --work=work -Pmem -Ppsx tb_subq
ghdl -r --std=08 -frelaxed --work=work -Pmem -Ppsx tb_subq --ieee-asserts=disable > ../tb_subq.log 2>&1 || true
sed "s/.*(report note): //" ../tb_subq.log | grep -v "^$"
cd ..
iverilog -g2012 -o work/tb_hps_ext.vvp tb_hps_ext.v $R/hps_ext.v
vvp -n work/tb_hps_ext.vvp
