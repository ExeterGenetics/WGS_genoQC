# Trio QC

Identify parent-offspring trios from kinship and compute per-trio transmission and Mendelian-error statistics, for calibrating the genotype QC thresholds.

Needs plink2, bcftools, and Python with pandas, numpy, cyvcf2 and tqdm.

| Step | Script | Command |
|---|---|---|
| 1. Kinship | `run_king.sh` | `run_king.sh PFILE_PREFIX OUT_PREFIX` |
| 2. Trios | `extract_trios.py` | `extract_trios.py OUT_PREFIX.kin0 SEX_FILE trios.ped` |
| 3. Autosomal trio statistics | `run_trio_stats.sh` | `run_trio_stats.sh IN.vcf.gz trios.ped trio_stats.txt [bcftools +trio-stats options]` |
| 4. chrX transmission | `trio_stats_chrX.py` | `python trio_stats_chrX.py IN_chrX.vcf.gz OUT.csv trios.ped snv\|indel` |

**1. Kinship.** `plink2 --make-king-table` (KING-robust) on a pgen fileset, keeping pairs with kinship >= 0.0884 (2nd degree or closer). Only autosomes are used. The IBS0 cut-off in step 2 was set on common array SNPs, so give it common, QC'd autosomal variants.

**2. Trios.** Parent-offspring pairs are those with kinship 0.177-0.354 and IBS0 < 0.0012 (Bycroft et al. 2018). A trio is a sample with two parent-offspring relatives of opposite sex whose kinship to each other is below 0.0884. `SEX_FILE` needs columns `IID` and `SEX` (1 = male, 2 = female), e.g. the `#IID SEX` file used for chrX conversion or a `.psam`. KING's own `.kin0` (columns `ID1`, `ID2`, `Kinship`, `IBS0`) is also accepted. Output is space-separated without a header: `child child father mother child_sex`.

**3. Autosomal trio statistics.** `bcftools +trio-stats -p trios.ped`; extra options are passed through, e.g. `-i 'GQ>={10,20,30}'` to scan thresholds.

**4. chrX transmission.** For `PASS` variants without a `BCSQ` annotation that are carried by exactly one trio mother (heterozygous), counts per trio whether the allele was transmitted to the child. Writes the trio table with `Ngenos`, `Ntransmitted` and `Nuntransmitted` columns.
