import os
import time
import json
import subprocess
import hail as hl
from pathlib import Path
from loguru import logger
from datetime import datetime

CHROM_LENGTHS = {
    "1": 248_956_422,
    "2": 242_193_529,
    "3": 198_295_559,
    "4": 190_214_555,
    "5": 181_538_259,
    "6": 170_805_979,
    "7": 159_345_973,
    "8": 145_138_636,
    "9": 138_394_717,
    "10": 133_797_422,
    "11": 135_086_622,
    "12": 133_275_309,
    "13": 114_364_328,
    "14": 107_043_718,
    "15": 101_991_189,
    "16": 90_338_345,
    "17": 83_257_441,
    "18": 80_373_285,
    "19": 58_617_616,
    "20": 64_444_167,
    "21": 46_709_983,
    "22": 50_818_468,
    "X": 156_040_895,
    "Y": 57_227_415,
}

V8_KNOWN_PROBLEM_POSITIONS: dict[str, set[int] | None] = {
    **{chrom: None for chrom in CHROM_LENGTHS.keys()},
    "1": {6940912, 36210726, 47179107, 119389137},
    "6": {2694524, 34686896, 43738107, 43958652, 157238332},
    "8": {41900621},
}

V9_KNOWN_PROBLEM_POSITIONS: dict[str, set[int] | None] = {
    "21": None,
    "17": {80497981, 81336415, 38389863},
    "19": {8678091, 5787204, 29010245},
    "15": {26893414},
    "13": {78659312},
    "11": {3246566, 58006639},
    "9": {38735047},
    "7": {134929621},
    "5": {63205048, 156185850, 113333838, 55897015},
    "3": {46840285},
    "1": {47179107, 36210726, 5802854, 6940912, 119389137, 204195224, 9411293, 245798398},
    "22": {48605186},
    "20": {42883696},
    "18": {78299647},
    "16": {7683010, 79770131},
    "14": {65978192},
    "12": {124234976, 10293157, 30577015},
    "10": {119394232},
    "8": {41900621},
    "6": {6537568, 157238332, 34686896, 2694524, 43738107, 43958652},
    "4": {17580184, 12237652},
    "2": None,
    "X": None,
}


def export_chrom(
    chrom: str,
    bucket: str,
    run_downstream: bool = False,
    intervals: list[tuple[int, int]] | None = None,
    intervals_to_check: list[tuple[int, int]] | None = None,
    positions_to_remove: set[int] | None = None,
    extra_suffix: str = "",
) -> None:
    """Intervals should be a list of tuples of ints: [(inclusive_start, exclusive_end)]"""
    if intervals:
        out_name = f"chr{chrom}_intervals_" + "_".join([f"{x[0]}-{x[1]}" for x in intervals])
    else:
        out_name = f"chr{chrom}"
    out_name += extra_suffix

    logger.info(
        f"Beginning export with options:\n"
        f"\tchr={chrom}\n"
        f"\tbucket={bucket}\n"
        f"\trun_downstream={run_downstream}\n"
        f"\tintervals={intervals}\n"
        f"\tintervals_to_check={intervals_to_check}\n"
        f"\tpositions_to_remove={positions_to_remove}"
    )

    vds_srwgs_path = "gs://vwb-aou-datasets-controlled/v9/wgs/short_read/snpindel/vds/hail.vds"
    vds = hl.vds.read_vds(vds_srwgs_path)
    vds = hl.vds.filter_chromosomes(vds, keep=f"chr{chrom}")

    if intervals:
        vds = hl.vds.filter_intervals(
            vds, [hl.parse_locus_interval(f"chr{chrom}:{x[0]}-{x[1]}") for x in intervals]
        )

    if positions_to_remove is None:
        positions_to_remove = set()

    if intervals_to_check:
        for interval in intervals_to_check:
            subset_vds = hl.vds.filter_intervals(
                vds, [hl.parse_locus_interval(f"chr{chrom}:{interval[0]}-{interval[1]}")]
            )
            row_keys = subset_vds.variant_data.row_key.collect()
            positions_to_remove.update(
                row_key.locus.position for row_key in row_keys if len(row_key.alleles) > 10000
            )
        logger.info(f"Found {len(positions_to_remove)} positions to remove:\n\t{positions_to_remove}")

    if positions_to_remove:
        vds = hl.vds.filter_intervals(
            vds, [hl.parse_locus_interval(f"chr{chrom}:{x}-{x+1}") for x in positions_to_remove], keep=False
        )

    mt = vds.variant_data.annotate_entries(GT=hl.vds.lgt_to_gt(vds.variant_data.LGT, vds.variant_data.LA))
    mt = mt.transmute_entries(FT=hl.if_else(mt.FT, "PASS", "FAIL"))
    mt = hl.vds.to_dense_mt(hl.vds.VariantDataset(vds.reference_data, mt))
    mt = mt.drop(
        "LGT",
        "LA",
        "RGQ",
        "PS",
        "as_vets",
        "truth_sensitivity_snp_threshold",
        "truth_sensitivity_indel_threshold",
    )

    out_path = f"{bucket}/wgs_v9_hail_vcfs/{out_name}.vcf.bgz"
    logger.info(f"Exporting to: {out_path}")
    vcf_starttime = datetime.now()
    hl.export_vcf(mt, out_path, parallel="header_per_shard")
    vcf_endtime = datetime.now()
    logger.info(f"Export complete in: {vcf_endtime-vcf_starttime}")
    if run_downstream:
        try:
            # Launch plink conversion workflow
            workflow_input = {
                "plink_conversion.sharded_vcf_path": out_path,
                "plink_conversion.output_base_path": f"{bucket}/wgs_v9_pgens_genoqc",
                "plink_conversion.out_name": out_name,
                "plink_conversion.chr": chrom,
                "plink_conversion.plink_path": "gs://pgen-bucket-wb-cordial-banana-2765/wgs_conversion_code",
                "plink_conversion.plink_binary": "plink2_mod",
            }
            workflow_input_path = Path(f"wdl_input_plink_conversion_{out_name}.json")
            workflow_input_path.write_text(json.dumps(workflow_input, indent=4, ensure_ascii=False))
            time.sleep(5)  # give time for gcsfuse to definitely sync
            now_ns = time.time_ns()
            date_time_part = datetime.fromtimestamp(now_ns / 1e9).strftime("%Y-%m-%dT%H%M%S")
            nanos_fraction = now_ns % 1_000_000_000
            timestamp_string = f"{date_time_part}{nanos_fraction:09d}Z"
            subprocess.run(
                [
                    "wb",
                    "workflow",
                    "job",
                    "run",
                    "--workflow=plink-conversion",
                    "--write-to-cache",
                    "--read-from-cache",
                    "--output-bucket-id=pgen-bucket",
                    "--output-path=cromwell_logs",
                    f"--inputs-uri=gs://pgen-bucket-wb-cordial-banana-2765/wgs_conversion_logs/{workflow_input_path.name}",
                    f"--job-id=plink-conversion-chr{chrom}-{extra_suffix.lstrip('_')}-{timestamp_string}",
                ],
                check=True,
                encoding="utf-8",
            )
        except Exception as e:
            logger.error(
                f"Exception launching conversion workflow, continuing with Hail export...\n Exception: {e}"
            )


def generate_intervals(start: int, end: int, target_step: int) -> list[tuple[int, int]]:
    length = end - start
    n_intervals = length // target_step + 1
    step = length // n_intervals + 1
    intervals = []
    pos = start
    while pos <= end:
        intervals.append((pos, min(end, pos + step)))
        pos += step
    return intervals


if __name__ == "__main__":
    # Check working directory is correct for sync:
    if os.getcwd() != os.path.expanduser("~/workspace/pgen-bucket/wgs_conversion_logs"):
        raise RuntimeError("Working directory is not set to the expected location")

    logger.add("hail_vds_conversion_{time}.log")
    google_project_id = os.environ["GOOGLE_PROJECT"]
    bucket = "gs://pgen-bucket-wb-cordial-banana-2765"

    hl.init(
        spark_conf={
            "spark.task.maxFailures": "16",
        },
        gcs_requester_pays_configuration=google_project_id,
    )
    hl.default_reference(new_default_reference="GRCh38")

    # chromosomes = [str(i) for i in range(22, 0, -2)]
    # chromosomes = [str(i) for i in range(21, 0, -2)] + ["X"]
    chromosomes = ["1"]
    logger.info(f"Exporting chromosomes:\n\t{chromosomes}")
    for chrom in chromosomes:
        prob_pos_known = chrom in V9_KNOWN_PROBLEM_POSITIONS.keys()
        export_chrom(
            chrom=chrom,
            bucket=bucket,
            run_downstream=True,
            intervals_to_check=None if prob_pos_known else generate_intervals(1, CHROM_LENGTHS[chrom], 5_000_000),
            positions_to_remove=V9_KNOWN_PROBLEM_POSITIONS[chrom] if prob_pos_known else None,
            extra_suffix="_genoqc",
        )
        time.sleep(20)
