FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    pkg-config \
    build-essential \
    libglib2.0-dev \
    libssl-dev \
    libfaad-dev \
    libogg-dev \
    libvorbis-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 \
    https://github.com/qbus00/streamripper.git \
    /src/streamripper

WORKDIR /src/streamripper

RUN cat << 'EOF' > /tmp/http_c_fix.patch
--- lib/http.c
+++ lib/http.c
@@ -34,3 +34,5 @@
-    if (strchr(url, ':') != NULL) {
+    char *port_colon = strchr(url, ':');
+    char *first_slash = strchr(url, '/');
+    if (port_colon != NULL && (first_slash == NULL || port_colon < first_slash)) {
 	debug_printf ("Branch 1 (%s)\n", url);
EOF

RUN patch -p1 < /tmp/http_c_fix.patch || true

RUN cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_SSL=ON \
    && cmake --build build -j"$(nproc)" \
    && strip build/streamripper
    
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    curl \
    bash \
    ca-certificates \
    libglib2.0-0 \
    libssl3 \
    libfaad2 \
    libogg0 \
    libvorbis0a \
    python3 \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/streamripper/build/streamripper /usr/local/bin/streamripper

COPY run.sh /run.sh
RUN chmod +x /run.sh

RUN echo "========================================" && \
    echo "STREAMRIPPER BUILD:" && \
    /usr/local/bin/streamripper --version || true && \
    echo "========================================"

CMD ["/run.sh"]
