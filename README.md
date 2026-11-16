# WGS_genoQC
Efficient Genotype QC and conversion from (sharded) VCF or VDS to plink2 pgen format 

## Layout

| Folder | Contents |
|---|---|
| [`dnanexus_app/`](dnanexus_app/) | DNAnexus applet for the UK Biobank Research Analysis Platform: genotype-level QC and conversion of DRAGEN pVCF chunks to pgen (formerly [chundruv/ukbb_pvcf2pgen](https://github.com/chundruv/ukbb_pvcf2pgen)) |
| [`standalone/`](standalone/) | The same QC and conversion for any multi-sample VCF/BCF, as bash scripts and a `Dockerfile` (laptop, HPC, cloud VM or container) |

`dnanexus_app/` bundles a modified plink2 binary and carries its own GPL-3.0 `LICENSE`.
