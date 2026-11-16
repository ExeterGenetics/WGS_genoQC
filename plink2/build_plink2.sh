#!/usr/bin/env bash
# build_plink2.sh -- build the modified plink2 used by this repository, from source.
# Needs: a C/C++ compiler (gcc or clang), make, zlib headers (zlib1g-dev / zlib-devel), git.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=versions.env
. "$HERE/versions.env"

OUT=./plink2
REPO=$PLINK2_REPO
COMMIT=$PLINK2_COMMIT
MAKE_ARGS=$PLINK2_MAKE_ARGS
usage() {
  cat <<USAGE
Usage: build_plink2.sh [-o OUTPUT] [-a] [-c COMMIT] [-r OWNER/REPO]
  -o FILE   where to put the binary                                   [$OUT]
  -a        use AVX2 instructions (faster; needs an x86-64 CPU from 2013 or later)
  -c SHA    commit to build, overriding versions.env (for testing only)
  -r REPO   GitHub repository, overriding versions.env (for testing only)
Pinned in versions.env: $PLINK2_REPO@$PLINK2_COMMIT, make $PLINK2_MAKE_ARGS
USAGE
}
while getopts "o:ac:r:h" opt; do
  case $opt in
    o) OUT=$OPTARG ;; a) MAKE_ARGS="$MAKE_ARGS NO_AVX2= NO_SSE42=" ;;
    c) COMMIT=$OPTARG ;; r) REPO=$OPTARG ;;
    h) usage; exit 0 ;; *) usage >&2; exit 2 ;;
  esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/build_plink2.XXXXXX")   # set TMPDIR to build elsewhere
trap 'rm -rf "$WORK"' EXIT
echo "build_plink2.sh: fetching $REPO@$COMMIT"
git -c init.defaultBranch=main init -q "$WORK/src"
git -C "$WORK/src" fetch -q --depth 1 "https://github.com/$REPO.git" "$COMMIT"
git -C "$WORK/src" checkout -q FETCH_HEAD
# shellcheck disable=SC2086  # MAKE_ARGS is a list of make variable assignments
( cd "$WORK/src/2.0/build_dynamic" && make $MAKE_ARGS plink2 > "$WORK/build.log" 2>&1 ) \
  || { tail -n 40 "$WORK/build.log" >&2; echo "build_plink2.sh: build failed" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$WORK/src/2.0/build_dynamic/plink2" "$OUT"
chmod 755 "$OUT"
"$OUT" --version

# Check the binary has the genotype-QC flags the pipelines use
fail() { echo "build_plink2.sh: $OUT is missing $1" >&2; exit 1; }
"$OUT" --help vcf-min-lad | grep -q 'missing-pass' || fail "--vcf-min-lad 'missing-pass'"
"$OUT" --help vcf-gt-filter | grep -q 'FORMAT/FT' || fail "--vcf-gt-filter"
"$OUT" --help vcf-allow-no-vars | grep -q 'allow-no-vars' || fail "--vcf-allow-no-vars"
"$OUT" --help merge-mode | grep -q 'nm-nonref-match' || fail "--merge-mode nm-nonref-match"
echo "build_plink2.sh: built $OUT from $REPO@${COMMIT:0:7}"
