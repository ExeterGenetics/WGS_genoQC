# WGS_genoQC
Efficient Genotype QC and conversion from (sharded) VCF or VDS to plink2 pgen format 

## Layout

| Folder | Contents |
|---|---|
| [`dnanexus_app/`](dnanexus_app/) | DNAnexus applet for the UK Biobank Research Analysis Platform: genotype-level QC and conversion of DRAGEN pVCF chunks to pgen (formerly [chundruv/ukbb_pvcf2pgen](https://github.com/chundruv/ukbb_pvcf2pgen)) |
| [`standalone/`](standalone/) | The same QC and conversion for any multi-sample VCF/BCF, as bash scripts and a `Dockerfile` (laptop, HPC, cloud VM or container) |
| [`aou_verily/`](aou_verily/) | All of Us: export of the WGS VDS to VCF (Hail) and a WDL workflow for the same QC and conversion on Verily Workbench, with a step-by-step guide. `aou_verily/as_run/` keeps the code that produced the shared [AoU v9 pgens](https://workbench.verily.com/workspaces/v9-wgs-pgens) |
| [`plink2/`](plink2/) | Build script and pinned commit of the modified plink2 used by all pipelines, and the flags it adds |
| [`trio_qc/`](trio_qc/) | Trio identification from KING kinship, and trio transmission statistics (bcftools `+trio-stats`, chrX script) for calibrating QC thresholds |

## plink2

The QC needs a modified plink2 (genotype filters on `FORMAT/LAD` and `FORMAT/FT`, and a few related flags). All
pipelines use the same build, pinned in [`plink2/versions.env`](plink2/versions.env), which the Docker images build;
the DNAnexus applet ships an earlier build from the same source. [`plink2/README.md`](plink2/README.md) lists the added flags and how to build it.

`dnanexus_app/` bundles a modified plink2 binary and carries its own GPL-3.0 `LICENSE`.
