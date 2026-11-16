#!/usr/bin/env bash
# shellcheck disable=SC2218  # false positive in shellcheck 0.11: die() is defined before first use
# pvcf2pgen.sh -- genotype-level QC and conversion of one VCF/BCF to plink2 pgen.
#
# Runs the same plink2 command as the DNAnexus applet, on any machine
# (laptop, HPC node, cloud VM or container). Works on any multi-sample VCF/BCF
# whose genotypes carry GQ and a depth field (FORMAT/LAD or FORMAT/DP).
set -euo pipefail

die() { echo "pvcf2pgen.sh: error: $*" >&2; exit 1; }
warn() { echo "pvcf2pgen.sh: warning: $*" >&2; }

usage() {
  cat <<'USAGE'
Usage: pvcf2pgen.sh -i INPUT -o PREFIX -q MIN_GQ -d MIN_DEPTH -m MAX_MISS [options]

Required
  -i FILE    input .vcf, .vcf.gz or .bcf (one chunk, chromosome or genome)
  -o PREFIX  output prefix; writes PREFIX.pgen/.pvar/.psam/.log and PREFIX.done
  -q INT     minimum GQ: genotypes with GQ below this are set to missing
  -d INT     minimum depth: genotypes with depth below this are set to missing
  -m FLOAT   maximum missing-call rate per variant after genotype filtering

Depth
  -D MODE    depth field: auto | lad | dp | none                       [auto]
             auto uses FORMAT/LAD (summed) if the header defines it, else
             FORMAT/DP. lad needs a plink2 with --vcf-min-lad (see
             build_plink2.sh). With lad, missing LAD counts as 0 and haploid
             calls use ceil(MIN_DEPTH/2).

Chromosome X
  -x MODE    none | nonpar | par                                       [none]
             nonpar and par load the sex file; par also splits PAR1/PAR2.
  -s FILE    sex file, header "#IID SEX" (1 = male, 2 = female)
  -b BUILD   genome build for --split-par (hg38, hg19, chm13, ...)     [hg38]

Other
  -p PATH    plink2 binary                            [$PLINK2, else plink2]
  -t INT     threads                                                      [1]
  -M INT     memory for plink2, MiB                                    [4000]
  -f         keep variants that fail the VCF FILTER column (default: drop)
  -I         keep the input variant IDs (default: CHR:POS:REF:ALT)
  -n         dry run: print the plink2 command and exit
  -h         show this help
USAGE
}


IN="" OUT="" MINGQ="" MINDP="" MAXMISS=""
DEPTH=auto XMODE=none SEXFILE="" BUILD=hg38
PLINK2_BIN=${PLINK2:-plink2} THREADS=1 MEM=4000 KEEP_FILTER=0 KEEP_IDS=0 DRY=0
while getopts "i:o:q:d:m:D:x:s:b:p:t:M:fInh" opt; do
  case $opt in
    i) IN=$OPTARG ;; o) OUT=$OPTARG ;; q) MINGQ=$OPTARG ;; d) MINDP=$OPTARG ;;
    m) MAXMISS=$OPTARG ;; D) DEPTH=$OPTARG ;; x) XMODE=$OPTARG ;; s) SEXFILE=$OPTARG ;;
    b) BUILD=$OPTARG ;; p) PLINK2_BIN=$OPTARG ;; t) THREADS=$OPTARG ;; M) MEM=$OPTARG ;;
    f) KEEP_FILTER=1 ;; I) KEEP_IDS=1 ;; n) DRY=1 ;; h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n $IN && -n $OUT && -n $MINGQ && -n $MINDP && -n $MAXMISS ]] || { usage >&2; exit 2; }
[[ -r $IN ]] || die "cannot read input '$IN'"
[[ $MINGQ =~ ^[0-9]+$ && $MINDP =~ ^[0-9]+$ ]] || die "-q and -d must be non-negative integers"
[[ $MAXMISS =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "-m must be a number between 0 and 1"
command -v "$PLINK2_BIN" >/dev/null 2>&1 || die "plink2 binary '$PLINK2_BIN' not found (use -p or set PLINK2)"

# FORMAT fields declared in the header (works for .vcf, .vcf.gz and .bcf)
read_header() {
  local magic
  magic=$(head -c 2 "$1" | od -An -tx1 | tr -d ' \n')
  if [[ $magic == 1f8b ]]; then
    gzip -dc "$1" 2>/dev/null | LC_ALL=C awk '/#CHROM/ {exit} {print}'
  else
    LC_ALL=C awk '/#CHROM/ {exit} {print}' "$1"
  fi
}
HEADER=$(read_header "$IN" || true)
has_format() { grep -a -q "##FORMAT=<ID=$1," <<<"$HEADER"; }
plink_has_lad() { "$PLINK2_BIN" --help vcf-min-lad 2>&1 | grep -q 'FORMAT/LAD'; }

has_format GT || die "input header declares no FORMAT/GT field"
has_format GQ || warn "input header declares no FORMAT/GQ: the GQ filter will have no effect"
case $DEPTH in
  auto)
    if has_format LAD; then DEPTH=lad
    elif has_format DP; then DEPTH=dp
    else die "header declares neither FORMAT/LAD nor FORMAT/DP; use -D none to skip the depth filter"
    fi ;;
  lad|dp|none) ;;
  *) die "-D must be auto, lad, dp or none" ;;
esac
DEPTH_ARGS=()
case $DEPTH in
  lad) plink_has_lad || die "'$PLINK2_BIN' has no --vcf-min-lad; build one with standalone/build_plink2.sh, or use -D dp if FORMAT/DP exists"
       has_format LAD || warn "header declares no FORMAT/LAD: every called genotype will fail the depth filter"
       DEPTH_ARGS=(--vcf-min-lad "$MINDP") ;;
  dp)  has_format DP || warn "header declares no FORMAT/DP: the depth filter will have no effect"
       DEPTH_ARGS=(--vcf-min-dp "$MINDP") ;;
  none) ;;
esac

case $IN in
  *.bcf) INPUT_ARGS=(--bcf "$IN") ;;
  *)     INPUT_ARGS=(--vcf "$IN") ;;
esac
X_ARGS=()
case $XMODE in
  none) ;;
  nonpar|par)
    [[ -n $SEXFILE ]] || die "-x $XMODE needs a sex file (-s)"
    [[ -r $SEXFILE ]] || die "cannot read sex file '$SEXFILE'"
    X_ARGS=(--update-sex "$SEXFILE")
    [[ $XMODE == par ]] && X_ARGS+=(--split-par "$BUILD") ;;
  *) die "-x must be none, nonpar or par" ;;
esac
OTHER_ARGS=()
(( KEEP_FILTER )) || OTHER_ARGS+=(--var-filter)
(( KEEP_IDS )) || OTHER_ARGS+=(--set-all-var-ids '@:#:$r:$a' --new-id-max-allele-len 10000)

CMD=("$PLINK2_BIN" "${INPUT_ARGS[@]}" --memory "$MEM" --threads "$THREADS"
     --geno "$MAXMISS" --vcf-min-gq "$MINGQ" ${DEPTH_ARGS[@]+"${DEPTH_ARGS[@]}"}
     ${OTHER_ARGS[@]+"${OTHER_ARGS[@]}"} --import-max-alleles 255
     ${X_ARGS[@]+"${X_ARGS[@]}"} --make-pgen multiallelics=- --out "$OUT")

if (( DRY )); then printf '%q ' "${CMD[@]}"; echo; exit 0; fi
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT.done"
"${CMD[@]}"
printf 'input\t%s\ndepth\t%s\nmin_gq\t%s\nmin_depth\t%s\nmax_miss\t%s\nchrX\t%s\n' \
  "$IN" "$DEPTH" "$MINGQ" "$MINDP" "$MAXMISS" "$XMODE" > "$OUT.done"
