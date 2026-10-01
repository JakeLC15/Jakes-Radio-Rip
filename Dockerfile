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

RUN git clone --branch sripper-1_64_6 --depth 1 \
    https://github.com/tdebaets/streamripper.git \
    /src/streamripper

WORKDIR /src/streamripper

RUN cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
    && cmake --build build --parallel \
    && cmake --install build --prefix /install


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

COPY --from=builder /install/usr/bin/streamripper /usr/bin/streamripper

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
