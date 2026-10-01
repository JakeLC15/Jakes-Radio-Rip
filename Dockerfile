FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    libglib2.0-dev \
    libcurl4-openssl-dev \
    libmad0-dev \
    libogg-dev \
    libvorbis-dev \
    libfaad-dev \
    libflac-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --branch sripper-1_64_6 --depth 1 \
    https://github.com/tdebaets/streamripper.git \
    /src/streamripper

WORKDIR /src/streamripper

RUN ./configure \
        --prefix=/usr \
        --disable-shared \
    && make -j"$(nproc)" \
    && make install DESTDIR=/install


FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    curl \
    bash \
    ca-certificates \
    libglib2.0-0 \
    libcurl4 \
    libmad0 \
    libogg0 \
    libvorbis0a \
    libfaad2 \
    libflac12 \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /install/usr/bin/streamripper /usr/bin/streamripper

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
