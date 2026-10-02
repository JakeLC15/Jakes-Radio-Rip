# ==========================================
# STAGE 1: Build the modern URL-patched Streamripper
# ==========================================
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    pkg-config \
    autoconf \
    automake \
    libglib2.0-dev \
    libmad0-dev \
    libogg-dev \
    libvorbis-dev \
    libtre-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pull the precise semicolon path fix branch from the source tree
RUN git clone --branch fix_colon_in_path --depth 1 https://github.com/XelaRellum/streamripper.git /src/streamripper

WORKDIR /src/streamripper

# Generate configuration script templates and compile natively
RUN autoreconf -i \
    && ./configure --prefix=/install \
    && make -j$(nproc) \
    && make install

# ==========================================
# STAGE 2: Lightweight Production Runtime Image
# ==========================================
FROM debian:bookworm-slim

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

# Extract the newly compiled binary directly into production staging
COPY --from=builder /install/bin/streamripper /usr/bin/streamripper

# Mount execution entry script hooks
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
