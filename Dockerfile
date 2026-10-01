# ==========================================
# STAGE 1: Compile the stable streamripper fork
# ==========================================
FROM debian:bookworm-slim AS builder

# Install all explicit build dependencies required for compiling the source code
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    build-essential \
    pkg-config \
    libglib2.0-dev \
    libmad0-dev \
    libogg-dev \
    libvorbis-dev \
    libtre-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Clone the custom stable branch directly
RUN git clone --branch sripper-1_64_6 --depth 1 \
    https://github.com/tdebaets/streamripper.git \
    /src/streamripper

WORKDIR /src/streamripper

# Compile and stage the installation inside an absolute staging root
RUN cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
    && cmake --build build --parallel \
    && cmake --install build --prefix /install

# ==========================================
# STAGE 2: Lightweight Production Runtime Image
# ==========================================
FROM debian:bookworm-slim

# Install system runtime libraries required by the compiled binary, plus utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    curl \
    bash \
    ca-certificates \
    libglib2.0-0 \
    libmad0 \
    libogg0 \
    libvorbis0a \
    libtre5 \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Corrected build-copy pathway alignment
COPY --from=builder /install/usr/bin/streamripper /usr/bin/streamripper

# Mount execution entry script hooks
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
