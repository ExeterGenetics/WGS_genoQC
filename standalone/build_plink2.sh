#!/usr/bin/env bash
# build_plink2.sh -- build the plink2 with --vcf-min-lad used by this pipeline, from source.
# Needs: a C/C++ compiler (gcc or clang), make, zlib headers (zlib1g-dev / zlib-devel), curl, tar.
set -euo pipefail

COMMIT=41a32144b852da3d23053ed695df5063ef61f7b5   # chundruv/plink-ukbb-mod, branch vcf-lad-filter-pr
REPO=chundruv/plink-ukbb-mod
OUT=./plink2
usage() {
  cat <<USAGE
Usage: build_plink2.sh [-o OUTPUT] [-c COMMIT] [-r OWNER/REPO]
  -o FILE   where to put the binary                                  [$OUT]
  -c SHA    commit to build                                          [$COMMIT]
  -r REPO   GitHub repository                                        [$REPO]
Builds 2.0/build_dynamic with SFX= NO_LAPACK=1 (baseline x86-64 on Intel/AMD, NEON on ARM).
USAGE
}
while getopts "o:c:r:h" opt; do
  case $opt in o) OUT=$OPTARG ;; c) COMMIT=$OPTARG ;; r) REPO=$OPTARG ;; h) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/build_plink2.XXXXXX")   # set TMPDIR to build elsewhere
trap 'rm -rf "$WORK"' EXIT
echo "build_plink2.sh: fetching $REPO@$COMMIT"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$COMMIT" -o "$WORK/src.tar.gz"
mkdir "$WORK/src" && tar -xzf "$WORK/src.tar.gz" -C "$WORK/src" --strip-components=1
( cd "$WORK/src/2.0/build_dynamic" && make SFX= NO_LAPACK=1 plink2 > "$WORK/build.log" 2>&1 ) \
  || { tail -n 40 "$WORK/build.log" >&2; echo "build_plink2.sh: build failed" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$WORK/src/2.0/build_dynamic/plink2" "$OUT"
chmod 755 "$OUT"
"$OUT" --version
"$OUT" --help vcf-min-lad | grep -q 'FORMAT/LAD' && echo "build_plink2.sh: $OUT supports --vcf-min-lad"
