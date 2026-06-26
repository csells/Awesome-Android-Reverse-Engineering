# Image for round-tripping native .so files: ddisasm + gtirb-pprinter (binary printing)
# plus the aarch64 cross assembler/linker so an ARM64 Android .so can be reassembled.
# Build:  docker build --platform linux/amd64 -t ddisasm-aarch64 -f ddisasm.Dockerfile .
FROM grammatech/ddisasm:latest
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu && \
    rm -rf /var/lib/apt/lists/*
