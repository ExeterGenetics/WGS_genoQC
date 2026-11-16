# All of Us WGS → pgen on Verily Workbench

Genotype QC and conversion of the All of Us (AoU) short-read WGS data to plink2 pgen format, on the
[Verily Workbench](https://workbench.verily.com). It applies the same kind of genotype-level QC as the UK Biobank
[DNAnexus applet](../dnanexus_app/README.md), with the same [modified plink2](../plink2/README.md), but starts from
the AoU VDS.

> **You probably don't need to run this.** The AoU v9 pgens made with this code are already available to registered
> AoU researchers in the [v9-wgs-pgens](https://workbench.verily.com/workspaces/v9-wgs-pgens) workspace. Run it
> yourself only if you need different QC thresholds, a different data release, or unsplit multi-allelic sites.

| Folder | Contents |
|---|---|
| `wdl/plink_conversion.wdl` | The conversion workflow (one chromosome per run) |
| `inputs/plink_conversion.template.json` | Template of the workflow's inputs |
| `scripts/export_hail_vcf.py` | Step 1: exports the VDS to sharded VCFs with Hail |
| `scripts/make_inputs.sh` | Writes one input file per chromosome from the template |
| `scripts/submit_chromosomes.sh` | Submits the workflow for several chromosomes |
| `scripts/gcloud_batch_files_by_size.py` | Used inside the workflow to group VCF shards into batches |
| `docker/Dockerfile` | The image the workflow runs in (modified plink2, bcftools, gcloud) |
| `as_run/` | The unmodified code that produced the shared v9 pgens, kept as a record ([README](as_run/README.md)) |

**Status.** `as_run/` is exactly what was run. The other files are a cleaned-up version of it: the same plink2
commands, with workspace-specific paths turned into inputs, the two conversion workflows merged into one, and plink2
taken from the Docker image. That plink2 is the repository's single build, into which the features of the fork used
for the v9 pgens were merged (differences in [`plink2/README.md`](../plink2/README.md#earlier-builds)). This version
has not yet been run end to end.

---

## What it does

```
AoU VDS ──(1) Hail export──▶ sharded VCF per chromosome ──(2) plink_conversion.wdl──▶ chr<N>_genoqc_trimmed_merged.pgen/.pvar/.psam
```

The workflow handles one chromosome per run and has three steps:

1. **Batch.** Groups the chromosome's VCF shards into batches of about 10 GB.
2. **Convert.** One VM per batch converts each shard with the plink2 command below, then merges the batch.
3. **Merge.** One large VM merges all the batches into the final pgen.

The QC in the plink2 command, with the default thresholds:

| Step | plink2 flag | Effect |
|---|---|---|
| Site filter | `--var-filter` | Keeps sites whose `FILTER` is `PASS`. On chrX, `ExcessHet` sites are kept too (expected with haploid males) |
| Genotype filter | `--vcf-gt-filter` | Sets genotypes whose `FORMAT/FT` is not `PASS` to missing |
| Genotype quality | `--vcf-min-gq 20` | Sets genotypes with GQ < 20 to missing |
| Genotype depth | `--vcf-min-lad diploid=8 haploid=4 missing-pass` | Sets genotypes whose depth (the sum of `FORMAT/LAD`) is below 8, or 4 for haploid calls such as male chrX, to missing. Homozygous-reference calls from reference blocks have no LAD, and `missing-pass` leaves them to the GQ filter ([why](../plink2/README.md#flags-added-to-upstream-plink2)) |
| Variant missingness | `--geno 0.1` | Removes variants with > 10% missing calls after the genotype filters |
| Multi-allelic sites | `--make-pgen multiallelics=-` | Splits multi-allelic sites into biallelic records (turn off with `split_multiallelics: false`) |
| Normalisation | `--normalize --fa` | Left-aligns indels against the reference |
| Monomorphic | `--mac 1` | Drops variants with no alternate allele left after QC |
| Variant IDs | `--set-all-var-ids @:#:$r:$a` | IDs become `CHR:POS:REF:ALT` |
| chrX | `--split-par hg38`, `--update-sex` | Pseudo-autosomal regions become `PAR1`/`PAR2`; sex is taken from your sex file |

---

## Words you will meet

| Term | Meaning here |
|---|---|
| **WDL** | "Workflow Description Language". A text file (`.wdl`) describing steps (*tasks*), what each needs, and what machine and Docker image to run it on. You don't run it yourself; you hand it to a workflow engine. |
| **Cromwell** | The workflow engine Verily Workbench uses to run WDLs. It starts a cloud VM for each task, runs it, and shuts it down. |
| **Workflow / job** | You *add* a WDL to your workspace once (a *workflow*); each time you run it with a set of inputs is a *job*. |
| **Inputs JSON** | A small file of `"workflow.input_name": value` pairs: which chromosome, which bucket, and so on. One per chromosome here. |
| **Bucket / `gs://` path** | Google Cloud Storage. Your workspace has one or more buckets (shown as *resources*); all files the workflow reads or writes are `gs://bucket-name/path` addresses. |
| **Resource ID** | The short name a bucket has in your workspace (e.g. `pgen-bucket`), as opposed to its full `gs://` name. `wb resource list` shows both. |
| **Docker image** | A packaged set of software. The workflow names an image, and every VM runs inside it, so you install nothing. |
| **Preemptible VM** | A cheaper VM that Google can stop at any time. The convert step uses them and Cromwell retries up to 3 times; for you this only means a job can take longer. |
| **`wb`** | The Verily Workbench command-line tool, already installed in Workbench apps (JupyterLab, etc.). |

---

## Before you start

- **Access:** AoU *controlled tier* access, and a Verily Workbench workspace with the AoU controlled-tier data
  (`vwb-aou-datasets-controlled`) as a resource.
- **Buckets:** a workspace bucket for outputs. Note both its `gs://` name and its resource ID (`wb resource list`).
- **An app:** a JupyterLab app (any size) in the workspace for running the commands below; open *Terminal* from it.
- **For step 1:** a Dataproc (Hail) cluster, described in step 1.
- **Two reference files in your bucket:**
  - **GRCh38 FASTA with its `.fai` index** (the workflow copies `<path>*`, so keep them side by side). We used
    `GRCh38_full_analysis_set_plus_decoy_hla.fa`.
  - **A sex file (chrX only).** Tab-separated with header `#FID IID SEX`, FID and IID both the research ID, and SEX
    1 = male, 2 = female. The FID column is needed because the VCF sample IDs are read with FID = IID; a file with only
    an IID column matches no one, and the workflow then stops with an error. Samples not in the file get unknown sex. `as_run/extract_array_sex_calls.py` collects the array-based
    sex calls from the AoU microarray VCF headers, which is one source; the AoU auxiliary QC files are another.
- **This repository in the workspace:**
  ```bash
  git clone https://github.com/ExeterGenetics/WGS_genoQC.git
  ```

Everything runs in `us-central1`, where the AoU data is, so there are no egress charges. The merge step uses a
16-CPU, 128 GiB VM with a 2 TB disk for a few hours per chromosome, which is the largest single cost. Do one small
chromosome (21 or 22) first to see the time and cost in your workspace before running the rest.

---

## Step 1. Export the VDS to VCF (Hail)

AoU provides the WGS data as a Hail VariantDataset (VDS), which plink2 cannot read. This step writes each chromosome
as a folder of VCF shards: the *sharded VCF*.

1. **Create a Dataproc cluster** in the workspace (*Apps → New app → Dataproc*), with Hail. Chromosome 1 needs a
   large cluster (we used many preemptible workers and ran one chromosome at a time); small chromosomes are fine on a
   modest one. Stop the cluster when you are done, because it costs money while idle.
2. **Run the export** from the cluster's JupyterLab terminal:
   ```bash
   cd WGS_genoQC/aou_verily/scripts
   python3 export_hail_vcf.py --bucket gs://<your-bucket> --chromosomes 21
   ```
   This writes `gs://<your-bucket>/wgs_hail_vcfs/chr21_genoqc.vcf.bgz/`: a folder of shards and a `shard-manifest.txt`.
   `python3 export_hail_vcf.py -h` lists the options. `--vds` selects a different release; the default is v9.
   For v9 the script already knows the handful of sites with more than 10,000 alleles that break the export; for other
   releases add `--no-known-problem-positions` so it scans for them.
3. **Optional:** add `--launch` together with `--pgen-output`, `--reference-fasta`, `--sex-psam` and `--log-bucket-id`
   to submit step 2 for each chromosome as soon as its export finishes.

The script keeps a log (`hail_vds_export_<time>.log`) in the current folder.

## Step 2. Add the workflow to your workspace (once)

In the workspace, open the **Workflows** tab and add a workflow from a Git repository:

- **Repository:** `https://github.com/ExeterGenetics/WGS_genoQC`
- **Path to the WDL:** `aou_verily/wdl/plink_conversion.wdl`
- **Workflow ID:** e.g. `plink-conversion` (you type this into later commands)

Button labels change between Workbench releases. If you can't find this option, see Verily's help pages on
*workflows*. `wb workflow --help` lists the command-line equivalents.

## Step 3. Write the inputs

```bash
cd WGS_genoQC/aou_verily
scripts/make_inputs.sh -b gs://<your-bucket> -o my_inputs -u gs://<your-bucket>/wdl_inputs {1..22} X
```

This copies `inputs/plink_conversion.template.json` once per chromosome, replacing `<BUCKET>` and `<CHR>`, and
uploads the files to `gs://<your-bucket>/wdl_inputs/`. Open one and check the paths, especially `reference_fasta` and
`sex_psam`. If your files are elsewhere, edit the template (or pass your own with `-t`) and rerun.

The inputs:

| Input | Default | Meaning |
|---|---|---|
| `sharded_vcf_path` | (required) | Folder from step 1 (`…/chr21_genoqc.vcf.bgz`) |
| `output_base_path` | (required) | Folder for the output |
| `out_name` | (required) | Output name, e.g. `chr21_genoqc` |
| `chr` | (required) | Chromosome without `chr`: `1`–`22` or `X` |
| `reference_fasta` | — | FASTA path (needs `.fai` next to it); required unless `split_multiallelics` is false |
| `sex_psam` | — | Sex file (`#FID IID SEX`); required for `X` |
| `split_multiallelics` | `true` | `false` keeps multi-allelic sites and skips normalisation |
| `min_gq` | `20` | Minimum GQ |
| `min_lad_diploid` / `min_lad_haploid` | `8` / `4` | Minimum depth (sum of LAD) for diploid / haploid calls |
| `max_missing` | `0.1` | Maximum per-variant missingness after the genotype filters |
| `batch_size_gb` | `10` | VCF data per convert VM |
| `do_convert` / `do_merge` | `true` / `true` | Run only part of the workflow, e.g. `do_convert: false` to redo just the merge |
| `docker` | `…/wgs_genoqc_aou:plink2-35073c2` | Image to run in (see [Docker image](#docker-image)) |

For conversion **without** genotype QC, set `min_gq`, `min_lad_diploid` and `min_lad_haploid` to `0`.

## Step 4. Run

Run one chromosome first:

```bash
scripts/submit_chromosomes.sh -i gs://<your-bucket>/wdl_inputs -l <log-bucket-resource-id> 21
```

When that has finished and the output looks right, run the rest. The script waits 30 minutes between submissions
(`-s` changes this) so the jobs don't all compete for VMs at once:

```bash
scripts/submit_chromosomes.sh -i gs://<your-bucket>/wdl_inputs -l <log-bucket-resource-id> {1..20} 22 X
```

`-n` prints the `wb workflow job run` commands without running them. You can also start a job from the Workflows tab:
choose the workflow, then *Run*, and give it the inputs JSON.

## Step 5. Monitor, and what to do when something fails

- **Progress:** the Workflows tab lists jobs and their tasks. Cromwell logs go to `<log bucket>/cromwell_logs/`. Each
  task has `stdout`/`stderr`, and the plink2 `.log` of each batch is uploaded next to its pgen in
  `<output_base_path>/unmerged/<out_name>/`.
- **Resubmit after any failure.** Finished batches are kept in `unmerged/` and are not redone, so rerunning the same
  command carries on where the job stopped. If only the merge failed, resubmit with `do_convert: false`.
- **Common failures:**
  - *Out of disk on a convert VM:* lower `batch_size_gb`.
  - *Out of memory or disk in the merge:* the merge VM size is set in the WDL (`merge_plink` runtime). Increase it
    there.
  - *No VMs available / long queues:* the tasks request Intel Cascade Lake CPUs in `us-central1`. These are usually
    available, but busy periods slow things down.
  - *`reference_fasta is required` / `sex_psam is required`:* the input is missing from that chromosome's JSON.
  - *`no sample IDs in sex_psam match the VCF`:* the sex file needs an FID column equal to IID (see *Before you start*).
- **Batches with no passing variants** leave a `.empty` marker instead of a pgen. This is normal.

## Step 6. Output

```
<output_base_path>/
  chr21_genoqc_trimmed_merged.pgen / .pvar / .psam    ← use these
  unmerged/chr21_genoqc/                              ← per-batch pgens and logs (can be deleted once merged)
```

- Chromosome names in the `.pvar` have no `chr` prefix (`21`, `X`, `PAR1`, `PAR2`).
- Sample IDs are the AoU research IDs (FID = IID).
- `plink2 --pfile <prefix> …` reads them directly.

---

## Docker image

The workflow runs in `hwright0/wgs_genoqc_aou` from Docker Hub. AoU workspaces can't pull from Docker Hub directly,
so the WDL names it through the AoU registry proxy:
`us-central1-docker.pkg.dev/all-of-us-rw-prod/aou-rw-gar-remote-repo-docker-prod/hwright0/wgs_genoqc_aou:<tag>`.

The image is built by [`.github/workflows/aou-docker.yml`](../.github/workflows/aou-docker.yml) whenever the
Dockerfile, the batching script or the plink2 pin changes. Tags:

- `plink2-<commit>`: the latest image with that plink2 commit (the workflow default).
- `plink2-<commit>-<run>`: a fixed build. Set `docker` to this to pin a run exactly.

To build it yourself, from the repository root:

```bash
docker build -f aou_verily/docker/Dockerfile -t wgs_genoqc_aou .
```

## Which plink2?

The image contains the repository's modified plink2 ([`../plink2/README.md`](../plink2/README.md)). If you run the
plink2 command yourself, use that build and keep `missing-pass`: without it, hom-ref calls from reference blocks (which
have no LAD) count as depth 0 and are set to missing.

## Contact

Workflows: Harry Wright. Genotype QC: Kartik Chundru.
