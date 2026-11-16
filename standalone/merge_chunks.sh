#!/usr/bin/env bash
# merge_chunks.sh -- merge converted chunks (pgen/pvar/psam) of one chromosome into one fileset.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: merge_chunks.sh -d DIR -o PREFIX [-p PLINK2] [-t THREADS] [-M MEM_MIB]

  -d DIR     directory holding the chunk filesets (only chunks with a .done marker are used)
  -o PREFIX  output prefix for the merged fileset
  -p PATH    plink2 binary                                   [$PLINK2, else plink2]
  -t INT     threads [1];  -M INT memory in MiB [8000]
All chunks must hold the same samples; variants present in two chunks are merged by ID and position.
USAGE
}
DIR="" OUT="" PLINK2_BIN=${PLINK2:-plink2} THREADS=1 MEM=8000
while getopts "d:o:p:t:M:h" opt; do
  case $opt in
    d) DIR=$OPTARG ;; o) OUT=$OPTARG ;; p) PLINK2_BIN=$OPTARG ;; t) THREADS=$OPTARG ;; M) MEM=$OPTARG ;;
    h) usage; exit 0 ;; *) usage >&2; exit 2 ;;
  esac
done
[[ -n $DIR && -n $OUT ]] || { usage >&2; exit 2; }
LIST="$OUT.merge_list.txt"
mkdir -p "$(dirname "$OUT")"
find "$DIR" -maxdepth 1 -name '*.done' | sed 's/\.done$//' | LC_ALL=C sort > "$LIST"
n=$(wc -l < "$LIST" | tr -d ' ')
[[ $n -gt 0 ]] || { echo "merge_chunks.sh: no completed chunks (*.done) in $DIR" >&2; exit 1; }
if [[ $n -eq 1 ]]; then
  "$PLINK2_BIN" --pfile "$(cat "$LIST")" --threads "$THREADS" --memory "$MEM" --make-pgen --out "$OUT"
else
  "$PLINK2_BIN" --pmerge-list "$LIST" pfile --threads "$THREADS" --memory "$MEM" --out "$OUT"
fi
echo "merge_chunks.sh: merged $n chunk(s) into $OUT"
