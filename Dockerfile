# Minimal container environment for building tmux .deb packages
FROM debian:bookworm-slim

# Install standard packaging tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dpkg-dev \
    file \
    gzip \
    make \
    python3 \
    tar \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

ENTRYPOINT ["./scripts/build-deb.sh"]
CMD ["--arch", "all"]
