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
import os

files_to_patch = ["lib/http.c", "console/streamripper.c"]

for target in files_to_patch:
    if os.path.exists(target):
        with open(target, "r") as f:
            text = f.read()
        
        old_line = "char *col = strchr (url_no_proto, ':');"
        new_line = """char *col = strchr (url_no_proto, ':');
    char *first_slash = strchr(url_no_proto, '/');
    if (col && first_slash && col > first_slash) col = NULL;"""
        
        if old_line in text:
            text = text.replace(old_line, new_line)
            with open(target, "w") as f:
                f.write(text)
            print(f"✅ successfully patched: {target}")
        else:
            print(f"⚠️ Target signature line not found in: {target}")
    else:
        print(f"❌ Critical Error: {target} missing from workspace context!")
        exit(1)
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
