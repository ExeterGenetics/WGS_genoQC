#!/usr/bin/env bash
# run_batch.sh -- run pvcf2pgen.sh over many VCF/BCF chunks in parallel.
# Chunks with an existing <prefix>.done are skipped, so a failed batch can be rerun as is.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: run_batch.sh -l LIST -O OUTDIR [-j JOBS] -- [pvcf2pgen.sh options except -i/-o]

  -l FILE   text file with one input path (.vcf.gz or .bcf) per line
  -O DIR    output directory; chunk "x.vcf.gz" is written as DIR/x.pgen/.pvar/.psam
  -j INT    chunks converted at the same time                            [1]
  Everything after "--" is passed to pvcf2pgen.sh (-q, -d, -m, -t, -M, -x, -s, ...).
  Keep (jobs x pvcf2pgen -M) within the machine's memory.

Example
  run_batch.sh -l chr21_chunks.txt -O pgen/chr21 -j 8 -- -q 10 -d 8 -m 0.1 -t 1 -M 4000
USAGE
}

LIST="" OUTDIR="" JOBS=1
while getopts "l:O:j:h" opt; do
  case $opt in
    l) LIST=$OPTARG ;; O) OUTDIR=$OPTARG ;; j) JOBS=$OPTARG ;; h) usage; exit 0 ;; *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ ${1:-} == "--" ]] && shift
[[ -n $LIST && -n $OUTDIR ]] || { usage >&2; exit 2; }
[[ -r $LIST ]] || { echo "run_batch.sh: cannot read $LIST" >&2; exit 1; }
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$OUTDIR/logs"
export SCRIPT_DIR OUTDIR

n_total=$(grep -c -v -e '^[[:space:]]*$' -e '^#' "$LIST" || true)
echo "run_batch.sh: $n_total chunk(s), $JOBS at a time -> $OUTDIR"

# xargs appends the input path as the last argument of each bash -c call
set +e
grep -v -e '^[[:space:]]*$' -e '^#' "$LIST" | tr '\n' '\0' | xargs -0 -n 1 -P "$JOBS" bash -c '
  in="${@: -1}"; set -- "${@:1:$(($# - 1))}"
  name=$(basename "$in"); name=${name%.gz}; name=${name%.bcf}; name=${name%.vcf}
  out="$OUTDIR/$name"
  if [[ -f "$out.done" ]]; then echo "skip (done): $name"; exit 0; fi
  if bash "$SCRIPT_DIR/pvcf2pgen.sh" -i "$in" -o "$out" "$@" > "$OUTDIR/logs/$name.log" 2>&1; then
    echo "ok: $name"
  else
    echo "FAILED: $name (see $OUTDIR/logs/$name.log)" >&2; exit 1
  fi
' _ "$@"
rc=$?
set -e
n_done=$(find "$OUTDIR" -maxdepth 1 -name '*.done' | wc -l | tr -d ' ')
echo "run_batch.sh: $n_done of $n_total chunk(s) complete"
[[ $rc -eq 0 ]] || { echo "run_batch.sh: some chunks failed; rerun the same command to retry them" >&2; exit 1; }
