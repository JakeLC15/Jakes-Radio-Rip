FROM debian:bookworm-slim

# Install jq, curl, bash, and runtime prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    curl \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download a modern, statically linked, multi-arch stable Linux build of streamripper
# This works seamlessly out-of-the-box on aarch64 (Raspberry Pi/ARM) and x86_64 servers
RUN curl -L -o /usr/bin/streamripper "https://github.com(uname -m)" \
    || apt-get update && apt-get install -y streamripper \
    && chmod +x /usr/bin/streamripper

# Mount execution entry script hooks
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
