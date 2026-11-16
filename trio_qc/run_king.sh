#!/usr/bin/env bash
# run_king.sh PFILE_PREFIX OUT_PREFIX
# KING-robust kinship for every sample pair related to 2nd degree or closer -> OUT_PREFIX.kin0
plink2 --pfile "$1" --make-king-table --king-table-filter 0.0884 --out "$2"
