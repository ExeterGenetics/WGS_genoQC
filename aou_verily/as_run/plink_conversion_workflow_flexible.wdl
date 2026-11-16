
version 1.0

workflow plink_conversion {

    input {
        String sharded_vcf_path
        String output_base_path
        String out_name
        String chr
        String plink_path
        String plink_binary
        Int min_gq = 20
        Int min_lad_diploid = 8
        Int min_lad_haploid = 4
        Boolean do_convert = true
        Boolean do_merge = true
        Int batch_size_gb = 10
    }

    File manifest = sharded_vcf_path + "/shard-manifest.txt"

    if (do_convert) {
        call batch_shards {
            input:
                manifest = manifest,
                sharded_vcf_path = sharded_vcf_path,
                batch_size_gb = batch_size_gb
        }
        scatter(batch_file in batch_shards.batch_files){
            call run_conversion {
                input:
                    batch_file = batch_file,
                    batch_size_gb  = batch_size_gb,
                    output_base_path = output_base_path,
                    out_name = out_name,
                    chr = chr,
                    plink_path = plink_path,
                    plink_binary = plink_binary,
                    min_gq = min_gq,
                    min_lad_diploid = min_lad_diploid,
                    min_lad_haploid = min_lad_haploid
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
                chr = chr,
                plink_path = plink_path,
                plink_binary = plink_binary
        }
    }
}

task batch_shards {

    input{
        File manifest
        String sharded_vcf_path
        Int batch_size_gb
    }

    command <<<
        set -euxo pipefail
        sed 's|^|~{sharded_vcf_path}/|' ~{manifest} > uri_shard_manifest.txt
        python3 /app/gcloud_batch_files_by_size.py --input uri_shard_manifest.txt --size-gb ~{batch_size_gb}
    >>>

    output{
        Array[File] batch_files = glob("batch_*")
    }
    
    runtime {
        docker: "us-central1-docker.pkg.dev/all-of-us-rw-prod/aou-rw-gar-remote-repo-docker-prod/hwright0/cloud-sdk-google-cloud-storage:531.0.0-slim"
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
        String plink_path
        String plink_binary
        Int min_gq
        Int min_lad_diploid
        Int min_lad_haploid
    }

    Int disk_size = 2 * batch_size_gb + 20
    
    command <<<
    # exit on error or unset variable
    set -euxo pipefail

    gcloud config set storage/parallel_composite_upload_enabled False

    PSAM_PATH="gs://pgen-bucket-wb-cordial-banana-2765/auxiliary_data"
    PSAM="v9_wgs_sex.psam"
    REF_PATH="gs://pgen-bucket-wb-cordial-banana-2765/alignment_ref"
    REF="GRCh38_full_analysis_set_plus_decoy_hla.fa"
    readarray -t batch_uris < ~{batch_file}

    gcloud storage cp \
        "${batch_uris[@]}" \
        "${REF_PATH}/${REF}*" .

    gsutil cp ~{plink_path}/~{plink_binary} .
    chmod +x ~{plink_binary}

    # loop through shards in batch
    while IFS= read -r uri; do
        # set filenames
        VCF_IN=$(basename "${uri}")
        PLINK_OUT="~{out_name}_${VCF_IN%.bgz}"

        # qc and left-alignment
        if [[ ~{chr} == "X" ]]; then
            gcloud storage cp "${PSAM_PATH}/${PSAM}" .
            # try plink with --split-par, if it fails then don't split par
            ./~{plink_binary} \
                --vcf "${VCF_IN}" \
                --geno 0.1 \
                --vcf-min-gq ~{min_gq} \
                --vcf-min-lad diploid=~{min_lad_diploid} haploid=~{min_lad_haploid} \
                --vcf-gt-filter \
                --var-filter ExcessHet \
                --import-max-alleles 255 \
                --set-all-var-ids "@:#:\$r:\$a" \
                --new-id-max-allele-len 10000 \
                --vcf-allow-no-vars \
                --make-pgen multiallelics=- \
                --out "${PLINK_OUT}" \
                --memory 30000 \
                --double-id \
                --split-par hg38 \
                --update-sex "${PSAM}" \
            || \
            ./~{plink_binary} \
                --vcf "${VCF_IN}" \
                --geno 0.1 \
                --vcf-min-gq ~{min_gq} \
                --vcf-min-lad diploid=~{min_lad_diploid} haploid=~{min_lad_haploid} \
                --vcf-gt-filter \
                --var-filter ExcessHet \
                --import-max-alleles 255 \
                --set-all-var-ids "@:#:\$r:\$a" \
                --new-id-max-allele-len 10000 \
                --vcf-allow-no-vars \
                --make-pgen multiallelics=- \
                --out "${PLINK_OUT}" \
                --memory 30000 \
                --double-id \
                --update-sex "${PSAM}"
        else
            ./~{plink_binary} \
                --vcf "${VCF_IN}" \
                --geno 0.1 \
                --vcf-min-gq ~{min_gq} \
                --vcf-min-lad diploid=~{min_lad_diploid} haploid=~{min_lad_haploid} \
                --vcf-gt-filter \
                --var-filter \
                --import-max-alleles 255 \
                --set-all-var-ids "@:#:\$r:\$a" \
                --new-id-max-allele-len 10000 \
                --vcf-allow-no-vars \
                --make-pgen multiallelics=- \
                --out "${PLINK_OUT}" \
                --memory 30000 \
                --double-id
        fi

    done < "~{batch_file}"

    # Should be no temp pgens left, error if there are
    if ls -v ${PLINK_OUT}-temporary.* 1> /dev/null 2>&1; then
        echo "Error: Temporary pgen files found. Exiting."
        exit 1
    fi
    
    # prepare to merge batch
    batch_pfile_name="~{out_name}_$(basename ~{batch_file})"
    ls -v ./*.pgen | sed 's/\.pgen$//' > plink_list || true

    # if no passing vars in batch, exit; elif only one pgen, norm only; else merge and norm
    has_var=$(wc -l < plink_list)
    if (( has_var == 0 )); then
        exit 0
    elif (( has_var == 1 )); then
        base_pfile=$(<plink_list)
        ./~{plink_binary} \
            --pfile "${base_pfile}" \
            --sort-vars \
            --mac 1 \
            --normalize \
            --fa "${REF}" \
            --make-pgen \
            --out "${batch_pfile_name}" \
            --memory 30000
    else
        ./~{plink_binary} \
            --pmerge-list plink_list \
            --merge-mode nm-nonref-match \
            --sort-vars \
            --mac 1 \
            --normalize \
            --fa "${REF}" \
            --make-pgen \
            --out "${batch_pfile_name}" \
            --memory 30000
    fi

    # upload
    gcloud storage cp "${batch_pfile_name}."* "~{output_base_path}/unmerged/~{out_name}/"
    >>>

    output{
        String shard_done = "TRUE"
    }

    runtime {
        docker: "us-central1-docker.pkg.dev/all-of-us-rw-prod/aou-rw-gar-remote-repo-docker-prod/hwright0/bcftools_plink_gcloud:1.22_6.24_531.0.0"
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
        String chr
        String plink_path
        String plink_binary
    }

    command <<<
    set -euxo pipefail

    # download all in unmerged out_name folder
    gcloud config set storage/parallel_composite_upload_enabled False
    gcloud storage cp "~{output_base_path}/unmerged/~{out_name}/*" .

    gsutil cp ~{plink_path}/~{plink_binary} .
    chmod +x ~{plink_binary}
    
    # list file ids
    ls -v ./*.pgen | sed 's/\.pgen$//' > plink_list
    
    # merge
    ./~{plink_binary} \
        --pmerge-list plink_list \
        --merge-mode nm-nonref-match \
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

    runtime {
        docker: "us-central1-docker.pkg.dev/all-of-us-rw-prod/aou-rw-gar-remote-repo-docker-prod/hwright0/bcftools_plink_gcloud:1.22_6.24_531.0.0"
        memory: "128 GiB"
        cpu: 16
        disks: "local-disk 2000 SSD"
        zones: "us-central1-a"
        cpuPlatform: "Intel Cascade Lake"
    }
}
