FROM debian:bookworm-slim

# Install streamripper, jq, curl, and bash
RUN apt-get update && apt-get install -y --no-install-recommends \
    streamripper \
    jq \
    curl \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Copy the startup script into the image
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD [ "/run.sh" ]
