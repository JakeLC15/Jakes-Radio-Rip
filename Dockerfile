# ==========================================
# STAGE 1: Build the modern URL-patched Streamripper
# ==========================================
FROM debian:bookworm-slim AS builder

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

# Paste the line here and remove the spaces:
RUN git clone --depth 1 https://github.com/XelaRellum/streamripper.git /src/streamripper

WORKDIR /src/streamripper

# FIXED: Replaced standard autotools flags with the repository's native cmake building sequence
RUN cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
    && cmake --build build --parallel \
    && cmake --install build --prefix /install

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

# Copy the compiled binary from the cmake installation folder
COPY --from=builder /install/usr/bin/streamripper /usr/bin/streamripper

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
