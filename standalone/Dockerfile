# Container with the modified plink2 (--vcf-min-lad) and the standalone scripts.
#   docker build -t ukbb-pvcf2pgen standalone/      (from the repository root)
#   docker run --rm -v "$PWD":/data -w /data ukbb-pvcf2pgen \
#     pvcf2pgen.sh -i chunk.vcf.gz -o out/chunk -q 10 -d 8 -m 0.1
# plink2 is built from source, so the image builds on x86-64 and ARM hosts.

FROM ubuntu:24.04 AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential zlib1g-dev curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY build_plink2.sh /tmp/build_plink2.sh
RUN bash /tmp/build_plink2.sh -o /usr/local/bin/plink2

FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends zlib1g \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/plink2 /usr/local/bin/plink2
COPY pvcf2pgen.sh run_batch.sh merge_chunks.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/*.sh && plink2 --help vcf-min-lad | grep -q 'FORMAT/LAD'
ENV PLINK2=/usr/local/bin/plink2
CMD ["pvcf2pgen.sh", "-h"]
