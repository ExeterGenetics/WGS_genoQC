# DNAnexus applet (ukbb_pvcf2pgen)

Genotype-level quality control and conversion of UK Biobank DRAGEN pVCF chunks to plink2 pgen format, as a DNAnexus applet for the UK Biobank Research Analysis Platform (RAP).

The same QC runs outside DNAnexus, on any multi-sample VCF/BCF, with the scripts and `Dockerfile` in [`../standalone/`](../standalone/).

For each pVCF chunk the applet runs one `plink2` command that:

| Step | plink2 flag | Effect |
|---|---|---|
| Site filter | `--var-filter` | Keeps variants whose `FILTER` is `PASS` (or `.`) |
| Genotype quality | `--vcf-min-gq <mingq>` | Sets genotypes with GQ below `mingq` to missing |
| Genotype depth | `--vcf-min-lad <mindp>` | Sets genotypes whose depth, the sum of `FORMAT/LAD`, is below `mindp` to missing (details below) |
| Variant missingness | `--geno <maxmiss>` | Removes variants whose missing-call rate, after the genotype filters, exceeds `maxmiss` |
| Multi-allelic sites | `--make-pgen multiallelics=-` | Splits multi-allelic sites into biallelic records |
| Variant IDs | `--set-all-var-ids @:#:$r:$a` | Sets IDs to `CHR:POS:REF:ALT` |

Genotype filters are applied while the VCF is read, so `--geno` sees the missingness they create.

## The modified plink2 binary

The UK Biobank DRAGEN pVCFs provide local allele depths (`FORMAT/LAD`) rather than a total depth, so the standard `--vcf-min-dp` (which reads `FORMAT/DP`) cannot be used. `resources/home/dnanexus/plink2_ukbb_vcftopgen` is plink2 with an added `--vcf-min-lad` / `--vcf-max-lad` filter:

- depth is the sum of the comma-separated `FORMAT/LAD` values for the genotype;
- a missing LAD value (`.`) counts as 0, so a called genotype with no LAD fails `--vcf-min-lad`;
- haploid calls (a GT with a single allele, e.g. `0` or `1`) are compared with ceil(min/2); this is decided from the GT field, not from the sex file;
- `--vcf-min-dp` keeps its standard meaning (`FORMAT/DP`), and combining the DP and LAD flags is an error.

**Provenance of the current binary**

| | |
|---|---|
| Source | https://github.com/chundruv/plink-ukbb-mod, branch `vcf-lad-filter-pr`, commit `41a32144b852da3d23053ed695df5063ef61f7b5` (proposed upstream as chrchang/plink-ng PR #709) |
| Version | `PLINK v2.0.0-b.1.5-devNL 64-bit (8 Nov 2026)` |
| Build | `cd 2.0/build_dynamic && make SFX= NO_LAPACK=1 plink2` (baseline x86-64, no LAPACK, bundled zstd) with gcc 11.4.1 on Rocky/RHEL 9 (glibc 2.34) |
| Runtime requirements | Linux x86-64, glibc ≥ 2.34, `libstdc++.so.6`, `libz.so.1` (all present on the RAP Ubuntu 24.04 image) |
| sha256 | `500b2ca7debc5696c2e97cb8084304ecad843ef4a6d3b7a9908a4f8110aa201c` |
| Tests | The branch's `2.0/Tests/TEST_VCF_LAD_FILTER` passes with this binary |

To rebuild elsewhere, check out that commit and run the build command above; drop `NO_LAPACK=1` if you need plink2's LAPACK-dependent commands.

## Building the applet

```
git clone https://github.com/ExeterGenetics/WGS_genoQC.git
cd WGS_genoQC/dnanexus_app
dx build -f -d ${PROJECT_ID}:${PATH}
```

## Running the applet

**Inputs**

| Input | Description |
|---|---|
| `vcf_list` | Text file of pVCF chunk file names (one per line, names only), all from one chromosome |
| `processes` | Number of chunks converted in parallel within the job |
| `mem` | Memory per plink2 process, in MiB (`processes` × `mem` must fit the instance) |
| `mingq` | Minimum GQ (genotypes with GQ below this are set to missing) |
| `mindp` | Minimum depth as the sum of LAD (genotypes below this are set to missing) |
| `maxmiss` | Maximum per-variant missingness after genotype filtering |
| `outdir` | Project folder for the output; files are written to `<outdir>/<chrom>/` |
| `sex_file` | Required for chromosome X: tab- or space-separated with header `#IID SEX` (1 = male, 2 = female) |
| `PAR` | `true` if the list contains pseudo-autosomal chunks; keep PAR and non-PAR chunks in separate lists |

The chromosome is read from the second `_`-separated field of the first file name in the list (e.g. `c21` → `chr21`), and chunks are downloaded from `/Bulk/DRAGEN WGS/DRAGEN population level WGS variants, pVCF format [500k release]/<chrom>/`.

**Example**

```
# lists of ~200 chunks for chromosome 21
dx ls "/Bulk/DRAGEN WGS/DRAGEN population level WGS variants, pVCF format [500k release]/chr21/" \
  | grep 'vcf.gz$' | split -l 200 - chr21_list_
dx upload chr21_list_* --path /vcf_lists/

dx run ${PROJECT_ID}:${PATH}/plink_conv \
  -ivcf_list=/vcf_lists/chr21_list_aa -iprocesses=8 -imem=6000 \
  -imingq=10 -imindp=8 -imaxmiss=0.1 -ioutdir=/pgen_genotypeqc
```

Chunks whose `.pgen` already exists in the output folder are skipped, so a failed job can be rerun with the same list. Files left in the `open` state by an interrupted upload are removed at the start of each job.

**Chromosome X.** Run non-PAR and PAR chunks as separate lists, both with `sex_file`; PAR lists also need `-iPAR=true`, which adds `--split-par hg38` (PAR1 ≤ chrX:2,781,479; PAR2 ≥ chrX:155,701,383). The halved depth threshold applies to haploid-coded calls (see above), so check how male non-PAR genotypes are coded in your pVCFs before relying on it.

## Merging chunks

After all chunks of a chromosome are converted, merge them with plink2 in a separate job:

```
ls *.pgen | sed 's/\.pgen$//' > merge_list.txt
plink2 --pmerge-list merge_list.txt pfile --make-pgen --out chr21_merged
```

## Licence

GPL-3.0, as for plink2 (see `LICENSE` in this folder). Source for the bundled binary is at the commit given above.
