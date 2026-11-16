# Standalone genotype QC and pgen conversion

Running outside UK Biobank and DNAnexus. Commands below are run from the repository root.

The scripts in this folder run the same plink2 command as the [DNAnexus applet](../dnanexus_app/README.md) (QC steps and the modified plink2 are described there) on a laptop, an HPC node, a cloud VM or in a container. They work on any multi-sample VCF/BCF whose genotypes carry GT, GQ and a depth field (`FORMAT/LAD` or `FORMAT/DP`), and need only bash, gzip, awk and plink2.

| Script | Purpose |
|---|---|
| `build_plink2.sh` | Builds the modified plink2 pinned in [`plink2/versions.env`](../plink2/versions.env) (shortcut for `plink2/build_plink2.sh`). Linux or macOS; needs a C/C++ compiler, make, zlib headers and git |
| `pvcf2pgen.sh` | Applies the genotype-level QC to one VCF/BCF and converts it to pgen |
| `run_batch.sh` | Converts a list of chunks in parallel; rerunning the same command skips completed chunks |
| `merge_chunks.sh` | Merges the converted chunks of one chromosome |

**plink2.** These scripts need the modified plink2 described in [`plink2/README.md`](../plink2/README.md). On Linux x86-64 you can use the bundled `dnanexus_app/resources/home/dnanexus/plink2_ukbb_vcftopgen`. Otherwise build it:

```
standalone/build_plink2.sh -o ~/bin/plink2      # set TMPDIR to build somewhere other than /tmp
export PLINK2=~/bin/plink2                      # or pass -p to each script
```

On macOS, if the build stops with `'algorithm' file not found`, run `export CXXFLAGS="-nostdinc++ -isystem $(xcrun --show-sdk-path)/usr/include/c++/v1"` first.

**Depth field.** `pvcf2pgen.sh` reads the VCF header. If `FORMAT/LAD` is declared it uses `--vcf-min-lad` (sum of LAD; missing LAD counts as 0; needs the modified plink2). Otherwise it uses `--vcf-min-dp` on `FORMAT/DP`, which the standard plink2 supports; there, a missing DP is not filtered. Use `-D lad|dp|none` to choose explicitly.

**Example**

```
# one file
standalone/pvcf2pgen.sh -i chunk.vcf.gz -o pgen/chr21/chunk -q 10 -d 8 -m 0.1 -t 4 -M 8000

# many chunks, 8 at a time, then merge
ls /data/vcf/chr21/*.vcf.gz > chr21_chunks.txt
standalone/run_batch.sh -l chr21_chunks.txt -O pgen/chr21 -j 8 -- -q 10 -d 8 -m 0.1 -t 1 -M 4000
standalone/merge_chunks.sh -d pgen/chr21 -o pgen/chr21_merged -t 8
```

Each converted chunk gets a `<prefix>.done` file recording its input and thresholds; `run_batch.sh` uses it to skip finished chunks and `merge_chunks.sh` merges only chunks that have one. For chromosome X add `-x nonpar -s sex.txt` or `-x par -s sex.txt` (with `-b` for builds other than hg38). `pvcf2pgen.sh -h` lists all options, and `-n` prints the plink2 command without running it.

**HPC (SLURM array)**

```
#SBATCH --array=1-200
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
f=$(sed -n "${SLURM_ARRAY_TASK_ID}p" chr21_chunks.txt)
standalone/pvcf2pgen.sh -i "$f" -o "pgen/chr21/$(basename "$f" .vcf.gz)" -q 10 -d 8 -m 0.1 -t 2 -M 7000
```

**Containers and other clouds.** The `Dockerfile` in this folder builds an image with the modified plink2 and the three scripts on the `PATH`, for platforms that run Docker images. Build it from the repository root, since it needs `plink2/`:

```
docker build -f standalone/Dockerfile -t ukbb-pvcf2pgen .
docker run --rm -v "$PWD":/data -w /data ukbb-pvcf2pgen \
  pvcf2pgen.sh -i chunk.vcf.gz -o out/chunk -q 10 -d 8 -m 0.1
```

**Choosing thresholds.** The example values (GQ 10, depth 8, missingness 0.1) are illustrative. GQ is not on a common scale across variant callers and joint-calling pipelines, so calibrate thresholds for each cohort, for example against Mendelian errors and singleton transmission in parent–offspring trios.
