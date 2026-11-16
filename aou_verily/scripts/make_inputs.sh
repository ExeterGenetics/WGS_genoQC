#!/usr/bin/env bash
# make_inputs.sh -- write one plink_conversion.wdl input JSON per chromosome from a template.
#
#   make_inputs.sh -b gs://my-bucket [-t TEMPLATE] [-o OUTDIR] [-u gs://my-bucket/wdl_inputs] CHR [CHR ...]
#
# In the template, <BUCKET> is replaced by -b and <CHR> by each chromosome (no 'chr', e.g. 21 or X).
# sex_psam is dropped from the JSON for chromosomes other than X.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE=$HERE/../inputs/plink_conversion.template.json
OUTDIR=.
BUCKET=
UPLOAD=
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
while getopts "b:t:o:u:h" opt; do
  case $opt in
    b) BUCKET=${OPTARG%/} ;; t) TEMPLATE=$OPTARG ;; o) OUTDIR=$OPTARG ;; u) UPLOAD=${OPTARG%/} ;;
    h) usage; exit 0 ;; *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ -n $BUCKET && $# -gt 0 ]] || { usage >&2; exit 2; }
[[ $BUCKET == gs://* ]] || { echo "make_inputs.sh: -b must start with gs://" >&2; exit 2; }

mkdir -p "$OUTDIR"
for chr in "$@"; do
  chr=${chr#chr}
  out="$OUTDIR/plink_conversion_chr${chr}.json"
  sed -e "s|<BUCKET>|$BUCKET|g" -e "s|<CHR>|$chr|g" "$TEMPLATE" > "$out"
  if [[ $chr != X ]]; then
    # sex_psam is only used for X
    python3 - "$out" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d.pop("plink_conversion.sex_psam", None)
json.dump(d, open(path, "w"), indent=4)
open(path, "a").write("\n")
PY
  fi
  echo "wrote $out"
  if [[ -n $UPLOAD ]]; then
    gcloud storage cp "$out" "$UPLOAD/"
  fi
done
