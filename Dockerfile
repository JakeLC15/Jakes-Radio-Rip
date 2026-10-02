FROM debian:bookworm-slim

# Install the native pre-compiled streamripper binary package alongside options utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    streamripper \
    jq \
    curl \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Mount execution entry script hooks
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
