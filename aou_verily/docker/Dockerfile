# Image for aou_verily/wdl/plink_conversion.wdl: the modified plink2 (plink2/README.md), bcftools/bgzip,
# the Google Cloud CLI and the shard batching script.
# Build from the repository root (the build needs plink2/ and aou_verily/scripts/):
#   docker build -f aou_verily/docker/Dockerfile -t wgs_genoqc_aou .
# plink2 is built from the commit pinned in plink2/versions.env, with AVX2 (the workflow runs on Cascade Lake CPUs).

FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:581.0.0-slim AS builder

ARG HTSLIB_VERSION=1.24
WORKDIR /src
ADD https://github.com/samtools/bcftools/releases/download/$HTSLIB_VERSION/bcftools-$HTSLIB_VERSION.tar.bz2 bcftools-$HTSLIB_VERSION.tar.bz2

RUN apt-get update && apt-get install -y --no-install-recommends \
            build-essential \
            git \
            zlib1g-dev \
            libbz2-dev \
            liblzma-dev \
            libcurl4-openssl-dev \
            libdeflate-dev \
      && tar -xf bcftools-$HTSLIB_VERSION.tar.bz2 \
      && cd bcftools-$HTSLIB_VERSION/ \
      && ./configure --prefix /src \
      && make \
      && make install \
      && make -C htslib-$HTSLIB_VERSION bgzip \
      && cp htslib-$HTSLIB_VERSION/bgzip /src/bin/

COPY plink2/versions.env plink2/build_plink2.sh /src/plink2/
RUN bash /src/plink2/build_plink2.sh -a -o /src/bin/plink2


FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:581.0.0-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
            python3-venv \
            libdeflate0 \
      && python3 -m venv /opt/gcloud-batch-venv \
      && /opt/gcloud-batch-venv/bin/pip install --no-cache-dir google-cloud-storage \
      && rm -rf /var/lib/apt/lists/*
ENV PATH="/opt/gcloud-batch-venv/bin:${PATH}"
COPY --from=builder /src/bin/bcftools /src/bin/bgzip /usr/local/bin/
COPY --from=builder /src/libexec/bcftools /usr/libexec/bcftools/
ENV BCFTOOLS_PLUGINS="/usr/libexec/bcftools"
COPY --from=builder /src/bin/plink2 /usr/local/bin/plink2
RUN plink2 --help vcf-min-lad | grep -q 'missing-pass'
COPY plink2/versions.env /app/plink2_versions.env
COPY aou_verily/scripts/gcloud_batch_files_by_size.py /app/gcloud_batch_files_by_size.py
