FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    streamripper \
    jq \
    curl \
    bash \
    ca-certificates \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
