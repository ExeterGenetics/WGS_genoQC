#!/usr/bin/env bash
# build_plink2.sh -- build the modified plink2 (--vcf-min-lad etc.) used by these scripts.
# Kept for existing instructions; the build itself is plink2/build_plink2.sh.
# Needs: a C/C++ compiler (gcc or clang), make, zlib headers (zlib1g-dev / zlib-devel), git.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../plink2/build_plink2.sh" "$@"
