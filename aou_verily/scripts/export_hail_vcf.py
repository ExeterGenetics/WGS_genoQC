"""Export one or more chromosomes of the All of Us VDS as sharded, densified VCFs with Hail.

Run on a Verily Workbench Dataproc (Hail) cluster from a notebook terminal or JupyterLab, e.g.

    python3 export_hail_vcf.py --bucket gs://my-bucket --chromosomes 21 22 X

Writes <bucket>/<vcf_folder>/chr<chrom><suffix>.vcf.bgz/ (a folder of VCF shards plus shard-manifest.txt), which
is the `sharded_vcf_path` input of ../wdl/plink_conversion.wdl. With --write-inputs it also writes one workflow
input JSON per chromosome next to the VCFs; with --launch it then submits the workflow with `wb workflow job run`.

Derived from ../as_run/export_hail_vcf_v9.py (the version used for the v9 pgens); the export itself is unchanged.
"""

import argparse
import json
import os
import subprocess
import tempfile
import time
from datetime import datetime

import hail as hl
from loguru import logger

DEFAULT_VDS = "gs://vwb-aou-datasets-controlled/v9/wgs/short_read/snpindel/vds/hail.vds"


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
    vds_path: str,
    out_prefix: str,
    intervals: list[tuple[int, int]] | None = None,
    intervals_to_check: list[tuple[int, int]] | None = None,
    positions_to_remove: set[int] | None = None,
    extra_suffix: str = "",
) -> tuple[str, str]:
    """Intervals should be a list of tuples of ints: [(inclusive_start, exclusive_end)].

    Returns (out_name, out_path)."""
    if intervals:
        out_name = f"chr{chrom}_intervals_" + "_".join([f"{x[0]}-{x[1]}" for x in intervals])
    else:
        out_name = f"chr{chrom}"
    out_name += extra_suffix

    logger.info(
        f"Beginning export with options:\n"
        f"\tchr={chrom}\n"
        f"\tvds={vds_path}\n"
        f"\tout_prefix={out_prefix}\n"
        f"\tintervals={intervals}\n"
        f"\tintervals_to_check={intervals_to_check}\n"
        f"\tpositions_to_remove={positions_to_remove}"
    )

    vds = hl.vds.read_vds(vds_path)
    vds = hl.vds.filter_chromosomes(vds, keep=f"chr{chrom}")

    if intervals:
        vds = hl.vds.filter_intervals(
            vds, [hl.parse_locus_interval(f"chr{chrom}:{x[0]}-{x[1]}") for x in intervals]
        )

    if positions_to_remove is None:
        positions_to_remove = set()

    # Sites with more than 10,000 alleles break the export; find and drop them
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
    # Genotypes filled in from reference blocks have GT and GQ but no LAD; the workflow's
    # --vcf-min-lad ... missing-pass filters these on GQ only (see plink2/README.md)
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

    out_path = f"{out_prefix}/{out_name}.vcf.bgz"
    logger.info(f"Exporting to: {out_path}")
    vcf_starttime = datetime.now()
    hl.export_vcf(mt, out_path, parallel="header_per_shard")
    vcf_endtime = datetime.now()
    logger.info(f"Export complete in: {vcf_endtime-vcf_starttime}")
    return out_name, out_path


def write_inputs(args: argparse.Namespace, chrom: str, out_name: str, vcf_path: str) -> str:
    """Write the plink_conversion.wdl input JSON for one chromosome next to the VCFs; returns its gs:// path."""
    inputs = {
        "plink_conversion.sharded_vcf_path": vcf_path,
        "plink_conversion.output_base_path": args.pgen_output,
        "plink_conversion.out_name": out_name,
        "plink_conversion.chr": chrom,
        "plink_conversion.reference_fasta": args.reference_fasta,
    }
    if chrom == "X":
        inputs["plink_conversion.sex_psam"] = args.sex_psam
    inputs_uri = f"{args.bucket.rstrip('/')}/{args.vcf_folder}/wdl_input_plink_conversion_{out_name}.json"
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(inputs, f, indent=4)
    subprocess.run(["gcloud", "storage", "cp", f.name, inputs_uri], check=True)
    os.unlink(f.name)
    logger.info(f"Wrote workflow inputs to {inputs_uri}")
    return inputs_uri


def launch(args: argparse.Namespace, chrom: str, out_name: str, inputs_uri: str) -> None:
    """Submit plink_conversion.wdl for one chromosome on Verily Workbench."""
    job_id = f"plink-conversion-chr{chrom}-{datetime.utcnow().strftime('%Y-%m-%dT%H%M%S')}"
    subprocess.run(
        [
            "wb", "workflow", "job", "run",
            f"--workflow={args.workflow_id}",
            "--write-to-cache", "--read-from-cache",
            f"--output-bucket-id={args.log_bucket_id}",
            "--output-path=cromwell_logs",
            f"--inputs-uri={inputs_uri}",
            f"--job-id={job_id}",
        ],
        check=True,
        encoding="utf-8",
    )
    logger.info(f"Submitted {job_id}")



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


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bucket", required=True, help="gs:// bucket (or folder) to write to, e.g. gs://my-bucket")
    p.add_argument("--chromosomes", nargs="+", required=True, help="chromosomes without 'chr', e.g. 21 22 X")
    p.add_argument("--vds", default=DEFAULT_VDS, help=f"VDS to export [{DEFAULT_VDS}]")
    p.add_argument("--vcf-folder", default="wgs_hail_vcfs", help="folder under --bucket for the VCFs [wgs_hail_vcfs]")
    p.add_argument("--suffix", default="_genoqc", help="added to the output name chr<chrom> [_genoqc]")
    p.add_argument(
        "--no-known-problem-positions",
        action="store_true",
        help="ignore the known v9 >10,000-allele sites and scan every chromosome for them (slower)",
    )
    w = p.add_argument_group("workflow inputs (for --write-inputs / --launch)")
    w.add_argument("--write-inputs", action="store_true", help="write a plink_conversion.wdl input JSON per chromosome")
    w.add_argument("--launch", action="store_true", help="also submit plink_conversion.wdl (implies --write-inputs)")
    w.add_argument("--pgen-output", help="gs:// folder for the pgens (workflow output_base_path)")
    w.add_argument("--reference-fasta", help="gs:// path of the GRCh38 FASTA (with .fai alongside)")
    w.add_argument("--sex-psam", help="gs:// path of the '#IID SEX' file (needed for X)")
    w.add_argument("--workflow-id", default="plink-conversion", help="workflow ID in your workspace [plink-conversion]")
    w.add_argument("--log-bucket-id", help="workspace resource ID of the bucket for Cromwell logs")
    args = p.parse_args()
    if args.launch:
        args.write_inputs = True
    if args.write_inputs:
        missing = [f"--{n.replace('_', '-')}" for n in ("pgen_output", "reference_fasta") if not getattr(args, n)]
        if "X" in args.chromosomes and not args.sex_psam:
            missing.append("--sex-psam")
        if args.launch and not args.log_bucket_id:
            missing.append("--log-bucket-id")
        if missing:
            p.error(f"--write-inputs/--launch need {' '.join(missing)}")
    return args


if __name__ == "__main__":
    args = parse_args()
    logger.add("hail_vds_export_{time}.log")

    hl.init(
        spark_conf={
            "spark.task.maxFailures": "16",
        },
        gcs_requester_pays_configuration=os.environ["GOOGLE_PROJECT"],
    )
    hl.default_reference(new_default_reference="GRCh38")

    out_prefix = f"{args.bucket.rstrip('/')}/{args.vcf_folder}"
    logger.info(f"Exporting chromosomes:\n\t{args.chromosomes}")
    for chrom in args.chromosomes:
        prob_pos_known = (not args.no_known_problem_positions) and chrom in V9_KNOWN_PROBLEM_POSITIONS
        out_name, out_path = export_chrom(
            chrom=chrom,
            vds_path=args.vds,
            out_prefix=out_prefix,
            intervals_to_check=None if prob_pos_known else generate_intervals(1, CHROM_LENGTHS[chrom], 5_000_000),
            positions_to_remove=set(V9_KNOWN_PROBLEM_POSITIONS[chrom] or ()) if prob_pos_known else None,
            extra_suffix=args.suffix,
        )
        if args.write_inputs:
            try:
                inputs_uri = write_inputs(args, chrom, out_name, out_path)
                if args.launch:
                    launch(args, chrom, out_name, inputs_uri)
            except Exception as e:
                logger.error(f"Could not write inputs or launch the workflow for chr{chrom}, continuing: {e}")
        time.sleep(20)

