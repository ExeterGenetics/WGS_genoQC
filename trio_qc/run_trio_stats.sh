#!/usr/bin/env bash
# run_trio_stats.sh IN.vcf.gz|IN.bcf TRIOS.ped OUT.txt [extra bcftools +trio-stats options, e.g. -i 'GQ>={10,20,30}']
bcftools +trio-stats -p "$2" "${@:4}" "$1" > "$3"
