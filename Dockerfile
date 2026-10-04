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

RUN cat << 'EOF' > /tmp/patch.py
import glob
import os

# Dynamic lookup finds findopt.c anywhere inside the /src/streamripper directory tree
matches = glob.glob("/src/streamripper/**/findopt.c", recursive=True)

if not matches:
    print("❌ Critical Error: findopt.c could not be found anywhere on disk!")
    exit(1)

TARGET_FILE = matches[0]
print(f"🎯 Found streamripper file path target at: {TARGET_FILE}")

with open(TARGET_FILE, "r") as f:
    text = f.read()

old_line = "char *col = strchr (url_no_proto, ':');"
new_line = """char *col = strchr (url_no_proto, ':');
    char *first_slash = strchr(url_no_proto, '/');
    if (col && first_slash && col > first_slash) col = NULL;"""

if old_line in text:
    text = text.replace(old_line, new_line)
    with open(TARGET_FILE, "w") as f:
        f.write(text)
    print("✅ Streamripper URL parser successfully patched!")
else:
    print("⚠️ Target line matching signature not found (It may have been modified or pre-patched)!")
EOF

RUN python3 /tmp/patch.py

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
