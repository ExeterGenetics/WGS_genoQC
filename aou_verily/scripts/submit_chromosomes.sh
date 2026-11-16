#!/usr/bin/env bash
# submit_chromosomes.sh -- submit plink_conversion.wdl for several chromosomes on Verily Workbench.
#
#   submit_chromosomes.sh -i gs://my-bucket/wdl_inputs -l LOG_BUCKET_ID [-w WORKFLOW_ID] [-s MINUTES] CHR [CHR ...]
#
#   -i  gs:// folder holding plink_conversion_chr<CHR>.json (from make_inputs.sh -u)
#   -l  workspace resource ID of the bucket for Cromwell logs (see `wb resource list`)
#   -w  workflow ID the WDL was added under in the workspace          [plink-conversion]
#   -s  minutes to wait between submissions, to spread the load      [30]
#   -n  print the commands without running them
set -euo pipefail

WORKFLOW=plink-conversion
SLEEP=30
INPUTS=
LOGBUCKET=
DRY=
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }
while getopts "i:l:w:s:nh" opt; do
  case $opt in
    i) INPUTS=${OPTARG%/} ;; l) LOGBUCKET=$OPTARG ;; w) WORKFLOW=$OPTARG ;; s) SLEEP=$OPTARG ;; n) DRY=echo ;;
    h) usage; exit 0 ;; *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ -n $INPUTS && -n $LOGBUCKET && $# -gt 0 ]] || { usage >&2; exit 2; }

n=0
for chr in "$@"; do
  chr=${chr#chr}
  if (( n > 0 )) && [[ -z $DRY ]]; then
    echo "waiting ${SLEEP} min before the next submission"
    sleep "${SLEEP}m"
  fi
  $DRY wb workflow job run \
    --workflow="$WORKFLOW" \
    --write-to-cache --read-from-cache \
    --output-bucket-id="$LOGBUCKET" \
    --output-path=cromwell_logs \
    --inputs-uri="$INPUTS/plink_conversion_chr${chr}.json" \
    --job-id="plink-conversion-chr${chr}-$(date -u +%Y-%m-%dT%H%M%S)"
  n=$((n + 1))
done
