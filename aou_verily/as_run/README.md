# As-run AoU conversion code (record only)

These files are an unmodified copy of `wgs_conversion_qc/aou_conversion/` and `wgs_conversion_qc/docker/` from
[ExeterGenetics/biobank_workflows@5bf7289](https://github.com/ExeterGenetics/biobank_workflows/tree/5bf7289fccf7ce09522790f9cd95c595033eee51/wgs_conversion_qc).
They are kept as a record of the code that produced the All of Us v9 WGS pgens shared in the
[v9-wgs-pgens](https://workbench.verily.com/workspaces/v9-wgs-pgens) Verily workspace. They are not maintained and
contain paths to buckets in the original workspace, so they will not run elsewhere unchanged.

For the maintained version see [`../README.md`](../README.md).

| File | Role |
|---|---|
| `export_hail_vcf_v9.py` | Densifies the AoU v9 VDS one chromosome at a time and exports it as a sharded VCF (Hail), then launches the conversion workflow |
| `extract_array_sex_calls.py` | Reads the array-based sex calls (`##autocallGender`, `##fingerprintGender`) from the AoU v9 microarray VCF headers |
| `plink_conversion_workflow_flexible.wdl` | Genotype QC, conversion to pgen with multi-allelic splitting and left-normalisation, and per-chromosome merge |
| `plink_conversion_nogenoqc_template.json` | Input template for the same WDL with the genotype filters switched off (GQ and LAD thresholds set to 0) |
| `plink_conversion_unsplit_multiallelics.wdl` | As above but keeps multi-allelic sites unsplit and does not normalise; skips batches already present in the output |
| `gcloud_batch_files_by_size.py` | Groups VCF shards into batches of a given total size (run inside the Docker image by the WDLs) |
| `docker/Dockerfile` | `wgs_conversion_qc` image (bcftools, gcloud, batching script) used by the unsplit WDL's batching step |

**plink2.** Both WDLs copy a modified plink2 binary (`plink_binary`, `plink2_mod`) from a workspace bucket at run time rather
than using the plink2 in a Docker image. It was built from [hwright0/plink-ng](https://github.com/hwright0/plink-ng), branch
`wgs-qc-dev`, whose features have since been merged into the repository's single plink2 build (see
[`../../plink2/README.md`](../../plink2/README.md#earlier-builds)). The version line at the top of each plink2 `.log`
file records the exact build.

**Docker images.** The conversion and merge tasks ran in `hwright0/bcftools_plink_gcloud:1.22_6.24_531.0.0` and the
flexible WDL's batching step in `hwright0/cloud-sdk-google-cloud-storage:531.0.0-slim` (both on Docker Hub, pulled through
the AoU registry proxy). Those images were not built from this Dockerfile.
