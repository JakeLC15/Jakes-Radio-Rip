# ==========================================
# STAGE 1: Build the modern URL-patched Streamripper
# ==========================================
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    pkg-config \
    libglib2.0-dev \
    libmad0-dev \
    libogg-dev \
    libvorbis-dev \
    libtre-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Clone the repository containing the specific SR_ERROR_PARSE_FAILURE bugfix
RUN git clone --depth 1 https://github.com/src/streamripper

WORKDIR /src/streamripper

# Configure and compile using standard autotools flags optimized for modern systems
RUN ./configure --prefix=/install \
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

# Copy the modern patched binary from the build staging container
COPY --from=builder /install/bin/streamripper /usr/bin/streamripper

# Mount execution entry script hooks
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
