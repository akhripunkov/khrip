FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

# Khrip emits Linux x86-64 ELF files and bootstraps from NASM. The database
# servers run in their own containers; PostgreSQL is only for the existing
# regression suite selected by run.sh --all.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nasm binutils python3 python3-cryptography curl ca-certificates \
      openssl postgresql \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash", "tests/databases/inside.sh"]
