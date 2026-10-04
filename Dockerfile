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
    python3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 \
    https://github.com/qbus00/streamripper.git \
    /src/streamripper

WORKDIR /src/streamripper

RUN cat << 'EOF' > /tmp/dual_patch.py
import glob
import os

for path in glob.glob("**/*.c", recursive=True):
    if os.path.exists(path):
        with open(path, "r", errors="ignore") as f:
            text = f.read()
        
        old_target = "if (strchr(url, ':') != NULL) {"
        old_target_alt = "if (strchr (url, ':') != NULL) {"
        
        new_logic = """char *p_col = strchr(url, ':');
    char *p_slash = strchr(url, '/');
    if (p_col != NULL && (p_slash == NULL || p_col < p_slash)) {"""
        
        if old_target in text or old_target_alt in text:
            text = text.replace(old_target, new_logic).replace(old_target_alt, new_logic)
            with open(path, "w") as f:
                f.write(text)
            print(f"✅ Successfully patched URL handler in: {path}")
EOF

RUN python3 /tmp/dual_patch.py

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
