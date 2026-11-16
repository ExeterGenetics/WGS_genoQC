version 1.0

# Genotype QC and conversion of one chromosome of a sharded VCF to a plink2 pgen fileset.
#
# 1. batch_shards     groups the VCF shards into batches of about batch_size_gb each, leaving out batches
#                     whose output is already in <output_base_path>/unmerged/<out_name>/ (so a failed or
#                     interrupted run can be resubmitted and carries on where it stopped)
# 2. run_conversion   per batch: genotype QC and conversion of each shard, then one merged pgen per batch
# 3. merge_plink      merges the batch pgens into <output_base_path>/<out_name>_trimmed_merged.{pgen,pvar,psam}
#
# Uses the modified plink2 described in plink2/README.md in this repository, installed in the Docker image. Derived from as_run/plink_conversion_workflow_flexible.wdl and
# as_run/plink_conversion_unsplit_multiallelics.wdl.

workflow plink_conversion {

    input {
        # gs:// folder written by Hail export_vcf(parallel=...): VCF shards plus shard-manifest.txt
        String sharded_vcf_path
        # gs:// folder for the output
        String output_base_path
        # output name, e.g. chr21_genoqc
        String out_name
        # chromosome without 'chr', e.g. 21 or X
        String chr

        # Required for chromosome X: file with header '#FID IID SEX', FID = IID = research ID (1 = male, 2 = female)
        File? sex_psam
        # Reference FASTA (with .fai alongside), used to left-normalise indels; required if split_multiallelics
        String? reference_fasta

        # true: split multi-allelic sites into biallelic records and left-normalise
        # false: keep multi-allelic sites as they are, no normalisation
        Boolean split_multiallelics = true

        # Genotype filters; set all three to 0 for conversion without genotype QC
        Int min_gq = 20
        Int min_lad_diploid = 8
        Int min_lad_haploid = 4
        # Maximum per-variant missingness after the genotype filters
        Float max_missing = 0.1

        Boolean do_convert = true
        Boolean do_merge = true
        Int batch_size_gb = 10

        String docker = "us-central1-docker.pkg.dev/all-of-us-rw-prod/aou-rw-gar-remote-repo-docker-prod/hwright0/wgs_genoqc_aou:plink2-35073c2"
    }

    File manifest = sharded_vcf_path + "/shard-manifest.txt"

    if (do_convert) {
        call batch_shards {
            input:
                manifest = manifest,
                sharded_vcf_path = sharded_vcf_path,
                batch_size_gb = batch_size_gb,
                output_base_path = output_base_path,
                out_name = out_name,
                docker = docker
        }
        scatter (batch_file in batch_shards.batch_files) {
            call run_conversion {
                input:
                    batch_file = batch_file,
                    batch_size_gb = batch_size_gb,
                    output_base_path = output_base_path,
                    out_name = out_name,
                    chr = chr,
                    sex_psam = sex_psam,
                    reference_fasta = reference_fasta,
                    split_multiallelics = split_multiallelics,
                    min_gq = min_gq,
                    min_lad_diploid = min_lad_diploid,
                    min_lad_haploid = min_lad_haploid,
                    max_missing = max_missing,
                    docker = docker
            }
        }
    }

    if (do_merge) {
        Array[String] shards_done = select_first([run_conversion.shard_done, ["TRUE"]])
        call merge_plink {
            input:
                shards_done = shards_done,
                output_base_path = output_base_path,
                out_name = out_name,
                split_multiallelics = split_multiallelics,
                docker = docker
        }
    }

    output {
        String? merged_prefix = merge_plink.merged_prefix
    }
}

task batch_shards {

    input {
        File manifest
        String sharded_vcf_path
        Int batch_size_gb
        String output_base_path
        String out_name
        String docker
    }

    command <<<
        set -euxo pipefail
        sed 's|^|~{sharded_vcf_path}/|' ~{manifest} > uri_shard_manifest.txt
        # Batches whose pgen/pvar/psam (or .empty marker) are already in the output folder are not
        # written, so a partially completed run can be resubmitted without redoing finished batches.
        python3 /app/gcloud_batch_files_by_size.py \
            --input uri_shard_manifest.txt \
            --size-gb ~{batch_size_gb} \
            --skip-complete-dir "~{output_base_path}/unmerged/~{out_name}" \
            --skip-complete-prefix "~{out_name}_"
    >>>

    output {
        Array[File] batch_files = glob("batch_*")
    }

    runtime {
        docker: docker
        memory: "16 GiB"
        cpu: 4
        disks: "local-disk 40 SSD"
        zones: "us-central1-a us-central1-b us-central1-c us-central1-f"
        cpuPlatform: "Intel Cascade Lake"
        preemptible: 3
    }
}

task run_conversion {

    input {
        File batch_file
        Int batch_size_gb
        String output_base_path
        String out_name
        String chr
        File? sex_psam
        String? reference_fasta
        Boolean split_multiallelics
        Int min_gq
        Int min_lad_diploid
        Int min_lad_haploid
        Float max_missing
        String docker
    }

    Int disk_size = 2 * batch_size_gb + 20

    command <<<
    # exit on error or unset variable
    set -euxo pipefail

    plink2 --version

    gcloud config set storage/parallel_composite_upload_enabled False

    readarray -t batch_uris < ~{batch_file}
    gcloud storage cp "${batch_uris[@]}" .

    if [[ "~{split_multiallelics}" == "true" ]]; then
        if [[ -z "~{default="" reference_fasta}" ]]; then
            echo "Error: reference_fasta is required when split_multiallelics is true." >&2
            exit 1
        fi
        # FASTA and its .fai
        gcloud storage cp "~{reference_fasta}*" .
        REF=$(basename "~{reference_fasta}")
        MAKE_PGEN=(--make-pgen multiallelics=-)
        NORMALIZE=(--normalize --fa "${REF}")
        MERGE_MODE=(--merge-mode nm-nonref-match)
    else
        MAKE_PGEN=(--make-pgen)
        NORMALIZE=()
        MERGE_MODE=()
    fi

    # Genotype QC and conversion flags shared by all chromosomes
    QC_FLAGS=(
        --geno ~{max_missing}
        --vcf-min-gq ~{min_gq}
        # missing-pass: hom-ref calls filled in from VDS reference blocks have no LAD and are
        # filtered on GQ only (a missing LAD would otherwise count as 0)
        --vcf-min-lad diploid=~{min_lad_diploid} haploid=~{min_lad_haploid} missing-pass
        --vcf-gt-filter
        --import-max-alleles 255
        --set-all-var-ids "@:#:\$r:\$a"
        --new-id-max-allele-len 10000
        --vcf-allow-no-vars
        --memory 30000
        --double-id
    )

    if [[ "~{chr}" == "X" ]]; then
        if [[ -z "~{default="" sex_psam}" ]]; then
            echo "Error: sex_psam is required for chromosome X." >&2
            exit 1
        fi
        PSAM="~{default="" sex_psam}"
    fi

    # loop through shards in batch
    while IFS= read -r uri; do
        # set filenames
        VCF_IN=$(basename "${uri}")
        PLINK_OUT="~{out_name}_${VCF_IN%.bgz}"

        if [[ "~{chr}" == "X" ]]; then
            # On chrX ExcessHet-flagged variants are kept (ExcessHet is expected with haploid males).
            # --split-par errors straight away on shards with no variant in a PAR boundary region, in
            # which case the shard is converted without it.
            plink2 \
                --vcf "${VCF_IN}" \
                "${QC_FLAGS[@]}" \
                --var-filter ExcessHet \
                "${MAKE_PGEN[@]}" \
                --out "${PLINK_OUT}" \
                --split-par hg38 \
                --update-sex "${PSAM}" \
            || \
            plink2 \
                --vcf "${VCF_IN}" \
                "${QC_FLAGS[@]}" \
                --var-filter ExcessHet \
                "${MAKE_PGEN[@]}" \
                --out "${PLINK_OUT}" \
                --update-sex "${PSAM}"
            # A sex file whose IDs don't match (e.g. no FID column, while --double-id sets FID = IID)
            # updates no one without an error; stop rather than produce chrX with unknown sex
            if grep -q -- "--update-sex: 0 samples updated" "${PLINK_OUT}.log"; then
                echo "Error: no sample IDs in sex_psam match the VCF (it needs '#FID IID SEX' with FID = IID)." >&2
                exit 1
            fi
        else
            plink2 \
                --vcf "${VCF_IN}" \
                "${QC_FLAGS[@]}" \
                --var-filter \
                "${MAKE_PGEN[@]}" \
                --out "${PLINK_OUT}"
        fi

    done < "~{batch_file}"

    # Should be no temp pgens left, error if there are
    if ls -v ./*-temporary.* 1> /dev/null 2>&1; then
        echo "Error: Temporary pgen files found. Exiting."
        exit 1
    fi

    # prepare to merge batch
    batch_pfile_name="~{out_name}_$(basename ~{batch_file})"
    ls -v ./*.pgen | sed 's/\.pgen$//' > plink_list || true

    # if no passing vars in batch, write marker and exit; elif only one pgen, sort (and normalise) only;
    # else merge and sort (and normalise)
    has_var=$(wc -l < plink_list)
    if (( has_var == 0 )); then
        # Marker so a resubmitted run treats this batch as done rather than repeating it
        touch "${batch_pfile_name}.empty"
        gcloud storage cp "${batch_pfile_name}.empty" "~{output_base_path}/unmerged/~{out_name}/"
        exit 0
    elif (( has_var == 1 )); then
        plink2 \
            --pfile "$(<plink_list)" \
            --sort-vars \
            --mac 1 \
            "${NORMALIZE[@]}" \
            --make-pgen \
            --out "${batch_pfile_name}" \
            --memory 30000
    else
        plink2 \
            --pmerge-list plink_list \
            "${MERGE_MODE[@]}" \
            --sort-vars \
            --mac 1 \
            "${NORMALIZE[@]}" \
            --make-pgen \
            --out "${batch_pfile_name}" \
            --memory 30000
    fi

    # upload
    gcloud storage cp "${batch_pfile_name}."{pgen,pvar,psam,log} "~{output_base_path}/unmerged/~{out_name}/"
    >>>

    output {
        String shard_done = "TRUE"
    }

    runtime {
        docker: docker
        memory: "32 GiB"
        cpu: 4
        disks: "local-disk " + disk_size + " SSD"
        zones: "us-central1-a us-central1-b us-central1-c us-central1-f"
        cpuPlatform: "Intel Cascade Lake"
        preemptible: 3
    }
}


task merge_plink {

    input {
        Array[String] shards_done
        String output_base_path
        String out_name
        Boolean split_multiallelics
        String docker
    }

    command <<<
    set -euxo pipefail

    plink2 --version

    # download all batch pgens for this chromosome
    gcloud config set storage/parallel_composite_upload_enabled False
    gcloud storage cp "~{output_base_path}/unmerged/~{out_name}/*" .

    if [[ "~{split_multiallelics}" == "true" ]]; then
        MERGE_MODE=(--merge-mode nm-nonref-match)
    else
        MERGE_MODE=()
    fi

    # list file ids
    ls -v ./*.pgen | sed 's/\.pgen$//' > plink_list

    # merge
    plink2 \
        --pmerge-list plink_list \
        "${MERGE_MODE[@]}" \
        --sort-vars \
        --set-all-var-ids "@:#:\$r:\$a" \
        --new-id-max-allele-len 10000 \
        --make-pgen \
        --out "~{out_name}_trimmed_merged" \
        --memory 120000
    sed -i 's/chr//g' "~{out_name}_trimmed_merged.pvar"

    # upload
    gcloud storage cp "~{out_name}_trimmed_merged."* "~{output_base_path}/"
    >>>

    output {
        String merged_prefix = "~{output_base_path}/~{out_name}_trimmed_merged"
    }

    runtime {
        docker: docker
        memory: "128 GiB"
        cpu: 16
        disks: "local-disk 2000 SSD"
        zones: "us-central1-a"
        cpuPlatform: "Intel Cascade Lake"
    }
}
