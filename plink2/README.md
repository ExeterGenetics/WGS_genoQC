# plink2 build

All pipelines in this repository use one modified plink2. It is upstream plink2 plus the
genotype-QC flags below, built from [chundruv/plink-ukbb-mod](https://github.com/chundruv/plink-ukbb-mod)
at the commit pinned in [`versions.env`](versions.env).

```bash
plink2/build_plink2.sh -o ~/bin/plink2
```

The build needs a C/C++ compiler, make, zlib headers and git, and takes a few minutes. Add `-a` for an AVX2 build, which
is faster and runs on any x86-64 CPU from 2013 on. The script checks that the binary has the flags listed below.
The Docker images (`standalone/Dockerfile`, `aou_verily/docker/Dockerfile`) build it the same way. To move to a new
commit, edit `versions.env` only.

## Flags added to upstream plink2

| Flag | Effect |
|---|---|
| `--vcf-min-lad <n>` / `--vcf-max-lad <n>` | Depth filter on the sum of `FORMAT/LAD` (local allele depths). A missing LAD counts as 0. With a single value, haploid calls (single-allele GT, e.g. male chrX) use ceil(n/2) for the minimum |
| `--vcf-min-lad diploid=8 haploid=4` | Separate thresholds for diploid and haploid calls (also for `--vcf-max-lad`, and for `--vcf-min-dp`/`--vcf-max-dp` with `--vcf`) |
| `--vcf-min-lad ... missing-pass` | A genotype whose LAD is entirely missing (`.` or absent) is not depth-filtered, instead of counting as 0. A partly missing LAD such as `4,.` still counts the `.` as 0 |
| `--vcf-gt-filter [values]` | Sets genotypes whose `FORMAT/FT` is not `PASS` or `.` to missing; listed values are also kept. `--vcf` only |
| `--vcf-allow-no-vars` | If no variant is imported or none remains after the main filters, print a warning and exit successfully without output (for converting many small chunks in parallel) |
| `--merge-mode nm-nonref-match` | Like `nm-match`, but a hom-ref vs non-ref conflict keeps the non-ref call; for merging records that become duplicates after left-normalisation |

The genotype filters are applied while the VCF is read, so `--geno` sees the missingness they create. The branch also
fixes a bug in upstream `--make-pgen multiallelics=-`: when a split multiallelic variant straddled a write-block
boundary (every 65,536 output records), plink2 crashed or wrote wrong genotypes for the last split record.

**Which LAD behaviour to use.** In UK Biobank DRAGEN pVCFs every called genotype has a LAD, so a missing LAD means a call
with no reads, and counting it as 0 (the default) is right. In All of Us the genotypes are densified from a Hail VDS,
and calls filled in from reference blocks (most hom-ref calls) have no LAD, so the AoU workflow uses `missing-pass`
to filter them on GQ only.

## Earlier builds

- **UK Biobank applet:** `dnanexus_app/` ships the binary built before this merge, from the same repository at
  `41a3214` (see the [applet README](../dnanexus_app/README.md#the-modified-plink2-binary)). Its `--vcf-min-lad <n>`
  behaviour is unchanged in the current build.
- **All of Us v9 pgens:** these were made with a separate fork, [hwright0/plink-ng](https://github.com/hwright0/plink-ng)
  branch `wgs-qc-dev` (see [`../aou_verily/as_run/`](../aou_verily/as_run/)). Its features were ported into the current
  build. Two differences remain. That fork let a partly missing LAD pass, where the current build counts its `.` entries
  as 0. And with a single `--vcf-min-lad` value it did not halve the threshold for haploid calls; the AoU workflow
  always passes `diploid=`/`haploid=`, so this one doesn't affect it.
