import argparse
import sys
import time
from google.cloud import storage
from google.api_core import exceptions


def get_blob_size(bucket, blob_name, max_retries=3):
    """Fetch blob size with retries on transient errors; fatal on NotFound."""
    backoff = 1.0
    for attempt in range(1, max_retries + 1):
        try:
            blob = bucket.get_blob(blob_name)
            if blob is None:
                print(f"Error: gs://{bucket.name}/{blob_name} not found.", file=sys.stderr)
                sys.exit(1)
            return blob.size
        except exceptions.GoogleAPIError as e:
            if attempt == max_retries:
                print(
                    f"Error: failed to fetch gs://{bucket.name}/{blob_name} after {max_retries} attempts: {e}",
                    file=sys.stderr,
                )
                sys.exit(1)
            time.sleep(backoff)
            backoff *= 2


def list_blob_names(client, dir_uri, max_retries=3):
    """Return the set of object basenames directly under a gs:// directory.

    A missing/empty directory yields an empty set rather than an error, so a
    first run behaves the same as a re-run with nothing completed yet.
    """
    _, _, path = dir_uri.partition("://")
    bucket_name, _, prefix = path.partition("/")
    prefix = prefix.rstrip("/") + "/" if prefix else ""

    backoff = 1.0
    for attempt in range(1, max_retries + 1):
        try:
            names = set()
            for blob in client.list_blobs(bucket_name, prefix=prefix):
                names.add(blob.name[len(prefix) :])
            return names
        except exceptions.GoogleAPIError as e:
            if attempt == max_retries:
                print(
                    f"Error: failed to list {dir_uri} after {max_retries} attempts: {e}",
                    file=sys.stderr,
                )
                sys.exit(1)
            time.sleep(backoff)
            backoff *= 2


def batch_is_complete(existing, stem, suffixes, empty_marker):
    """True if a batch's outputs are already in place (or it produced nothing)."""
    if empty_marker and stem + empty_marker in existing:
        return True
    return all(stem + suffix in existing for suffix in suffixes)


def shard_output_name(uri, strip_suffix, output_suffix):
    """Expected output object name for a single input shard."""
    name = uri.rsplit("/", 1)[-1]
    if strip_suffix and name.endswith(strip_suffix):
        name = name[: -len(strip_suffix)]
    return name + output_suffix


def batch_by_size(uri_sizes, size_limit, similar_sized):
    if similar_sized:
        uri_sizes = sorted(uri_sizes, key=lambda item: item[1], reverse=True)

    batches = []
    cur_batch = []
    cur_sum = 0
    for uri, size in uri_sizes:
        if cur_batch and cur_sum + size > size_limit:
            batches.append(cur_batch)
            cur_batch = []
            cur_sum = 0
        cur_batch.append((uri, size))
        cur_sum += size
    if cur_batch:
        batches.append(cur_batch)
    return batches


def main():
    p = argparse.ArgumentParser(description="Batch GCS URIs by cumulative size")
    p.add_argument("--input", required=True, help="File with one gs:// URI per line")
    p.add_argument("--size-gb", required=True, type=int, help="Max cumulative size per batch (GiB)")
    p.add_argument("--prefix", default="batch_", help="Filename prefix for each batch")
    p.add_argument(
        "--similar-sized",
        action="store_true",
        help="Sort shards by descending size before batching (THIS WILL BREAK SHARD ORDERING)",
    )
    p.add_argument(
        "--skip-complete-dir",
        help="gs:// directory holding batch outputs; batches already present there are not written",
    )
    p.add_argument(
        "--skip-complete-prefix",
        default="",
        help="Prefix prepended to the batch filename to form the output stem (e.g. 'chr1_')",
    )
    p.add_argument(
        "--skip-complete-suffixes",
        default=".pgen,.pvar,.psam",
        help="Comma-separated suffixes that must all exist for a batch to count as complete",
    )
    p.add_argument(
        "--skip-complete-shards",
        action="store_true",
        help="Check completeness per input shard instead of per batch, and re-batch only "
        "the shards still to do (for workflows that write one output per shard)",
    )
    p.add_argument(
        "--shard-strip-suffix",
        default=".bgz",
        help="Suffix stripped from the input basename to form the shard output name",
    )
    p.add_argument(
        "--shard-output-suffix",
        default=".bcf",
        help="Suffix appended to the stripped input basename to form the shard output name",
    )
    p.add_argument(
        "--empty-marker-suffix",
        default=".empty",
        help="Suffix marking output that legitimately produced nothing; counts as complete",
    )
    args = p.parse_args()

    size_limit = args.size_gb * 1024**3
    client = storage.Client()

    # Read URIs
    uris = []
    with open(args.input) as f:
        for line in f:
            uri = line.strip()
            if not uri.startswith("gs://"):
                print(f"Error: invalid URI {uri}", file=sys.stderr)
                sys.exit(1)
            uris.append(uri)

    if not uris:
        print("Error: No files to batch.", file=sys.stderr)
        sys.exit(1)

    # Optionally look up what has already been produced, so a partially
    # completed run can be resumed without redoing finished work.
    existing = set()
    if args.skip_complete_dir:
        if not args.skip_complete_dir.startswith("gs://"):
            print(
                f"Error: invalid --skip-complete-dir {args.skip_complete_dir}",
                file=sys.stderr,
            )
            sys.exit(1)
        existing = list_blob_names(client, args.skip_complete_dir)
    check_suffixes = [s for s in args.skip_complete_suffixes.split(",") if s]

    # Per-shard mode: drop finished shards before batching, so the shards still
    # to do are re-packed into full-sized batches.
    if args.skip_complete_dir and args.skip_complete_shards:
        n_input = len(uris)
        remaining = []
        for uri in uris:
            name = shard_output_name(uri, args.shard_strip_suffix, args.shard_output_suffix)
            # A single expected object per shard, hence the empty suffix list
            if batch_is_complete(existing, name, [""], args.empty_marker_suffix):
                continue
            remaining.append(uri)
        n_done = n_input - len(remaining)
        print(f"{n_done}/{n_input} shards already complete in {args.skip_complete_dir}")
        if not remaining:
            print("Done: 0 batches, all shards already complete")
            return
        uris = remaining

    # Fetch sizes for the shards still to do
    uri_sizes = []
    for uri in uris:
        _, _, path = uri.partition("://")
        bucket_name, _, blob_name = path.partition("/")
        bucket = client.bucket(bucket_name)
        uri_sizes.append((uri, get_blob_size(bucket, blob_name)))

    batches = batch_by_size(uri_sizes, size_limit, args.similar_sized)
    n_batches = len(batches)

    # Per-batch mode: batch numbering is unchanged, every batch is still
    # enumerated and completed ones are simply not written out.
    # Write out batches with zero-padded numeric suffix
    width = len(str(n_batches - 1))
    n_skipped = 0
    for idx, batch in enumerate(batches):
        name = f"{args.prefix}{str(idx).zfill(width)}"
        stem = f"{args.skip_complete_prefix}{name}"
        if (
            args.skip_complete_dir
            and not args.skip_complete_shards
            and batch_is_complete(existing, stem, check_suffixes, args.empty_marker_suffix)
        ):
            print(f"Skipping {name}: {stem} already complete in {args.skip_complete_dir}")
            n_skipped += 1
            continue
        with open(name, "w") as out:
            for uri, sz in batch:
                out.write(f"{uri}\n")

    print(f"Done: {n_batches} batches, {n_skipped} already complete, {n_batches - n_skipped} to run")


if __name__ == "__main__":
    main()
