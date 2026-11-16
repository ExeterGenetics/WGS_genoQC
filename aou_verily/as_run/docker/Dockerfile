# Docker for AoU VDS conversion

FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:581.0.0-slim AS builder

# 1.22 version used before should be updated to 1.22.2 for fixes
# https://github.com/samtools/bcftools/releases#release-1.22.2
ARG HTSLIB_VERSION=1.24
WORKDIR /src
ADD https://github.com/samtools/bcftools/releases/download/$HTSLIB_VERSION/bcftools-$HTSLIB_VERSION.tar.bz2 bcftools-$HTSLIB_VERSION.tar.bz2
ADD https://s3.amazonaws.com/plink2-assets/alpha6/plink2_linux_avx2_20260818.zip plink2_linux_avx2.zip 

RUN apt-get update && apt-get install -y --no-install-recommends \
            build-essential \
            zlib1g-dev \
            libbz2-dev \
            liblzma-dev \
            unzip \
            libcurl4-openssl-dev \
            libdeflate-dev \
      && unzip plink2_linux_avx2.zip \
      && tar -xf bcftools-$HTSLIB_VERSION.tar.bz2 \
      && cd bcftools-$HTSLIB_VERSION/ \
      && ./configure --prefix /src \
      && make \
      && make install \
      && make -C htslib-$HTSLIB_VERSION bgzip \
      && cp htslib-$HTSLIB_VERSION/bgzip /src/bin/
      

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
COPY --from=builder /src/plink2 /usr/local/bin/
COPY aou_conversion/gcloud_batch_files_by_size.py /app/gcloud_batch_files_by_size.py
