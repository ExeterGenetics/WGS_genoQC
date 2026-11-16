import gzip
import csv
import time
import os
import threading
import concurrent.futures
from google.cloud import storage
from loguru import logger

# Configuration
BUCKET_NAME = "vwb-aou-datasets-controlled"
MANIFEST_FILE = f"gs://{BUCKET_NAME}/v9/microarray/vcf/manifest.csv"
OUTPUT_TSV = "array_sex_calls.tsv"
MAX_RETRIES = 3  # per file
MAX_WORKERS = 64
GOOGLE_PROJECT = os.getenv("GOOGLE_PROJECT")

storage_client = storage.Client()
bucket = storage_client.bucket(BUCKET_NAME, user_project=GOOGLE_PROJECT)

# Configure logging
logger.add("extract_array_sex_calls_{time}.log")
logger.add("extract_array_sex_calls_ERRORS_{time}.log", level="ERROR", backtrace=True, diagnose=True)

lock = threading.Lock()


def get_vcf_list():
    "Read manifest file containing VCF paths"
    logger.info("Fetching manifest file from GCS...")
    blob = bucket.blob(MANIFEST_FILE.replace(f"gs://{BUCKET_NAME}/", ""))
    manifest_lines = [line.split(",") for line in blob.download_as_text().strip().split("\n")][1:]
    logger.info(f"Loaded {len(manifest_lines)} VCF files from manifest.")
    return manifest_lines


def process_vcf(manifest_line):
    "Extract sex calls from header of VCF files"
    id = manifest_line[0]
    vcf_path = manifest_line[1]
    blob = bucket.blob(vcf_path.replace(f"gs://{BUCKET_NAME}/", ""))

    retries = 0
    while retries <= MAX_RETRIES:
        try:
            # logger.info(f"Processing {vcf_path} (Attempt {retries + 1})...")
            with blob.open("rb", chunk_size=262_144) as f:
                with gzip.open(f, "rt") as vcf:
                    extracted_info = {"id": id, "vcf_path": vcf_path}
                    for line in vcf:
                        # Stop reading if reached end of header
                        if line.startswith("#CHROM"):
                            break
                        # Match only the relevant header lines
                        if line.startswith("##autocallGender="):
                            extracted_info["autocallGender"] = line.split("=")[1].strip()
                        elif line.startswith("##fingerprintGender="):
                            extracted_info["fingerprintGender"] = line.split("=")[1].strip()
                        # Stop reading if found both fields
                        if "autocallGender" in extracted_info and "fingerprintGender" in extracted_info:
                            break

                    save_result(
                        [
                            extracted_info.get("id", "NA"),
                            extracted_info.get("autocallGender", "NA"),
                            extracted_info.get("fingerprintGender", "NA"),
                            extracted_info.get("vcf_path", "NA"),
                        ]
                    )
                    # logger.success(f"Successfully processed {vcf_path}")
                    return extracted_info

        except Exception as e:
            retries += 1
            logger.warning(f"Error processing {vcf_path} (Attempt {retries}/{MAX_RETRIES}): {e}")
            time.sleep(2**retries)

    logger.error(f"Failed to process {vcf_path} after {MAX_RETRIES} retries.")
    return None


def save_result(row):
    "Save extracted information to TSV file (thread-safe)"
    with lock:
        with open(OUTPUT_TSV, "a", newline="") as tsvfile:
            writer = csv.writer(tsvfile, delimiter="\t")
            writer.writerow(row)


def process_all_vcfs():
    "Process all VCF files listed in the manifest"
    manifest_lines = get_vcf_list()

    # Create TSV file & write headers before processing starts
    with open(OUTPUT_TSV, "w", newline="") as tsvfile:
        writer = csv.writer(tsvfile, delimiter="\t")
        writer.writerow(["id", "autocallGender", "fingerprintGender", "vcf_path"])

    logger.info(f"Starting parallel processing with {MAX_WORKERS} workers...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        list(executor.map(process_vcf, manifest_lines))
    logger.success(f"Processing complete. Results saved to {OUTPUT_TSV}")


if __name__ == "__main__":
    process_all_vcfs()
