FROM debian:bookworm-slim
ARG BORE_VERSION=0.6.0
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(uname -m) && \
    curl -fL "https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/bore-v${BORE_VERSION}-${ARCH}-unknown-linux-musl.tar.gz" \
    | tar -xz -C /usr/local/bin bore && \
    chmod +x /usr/local/bin/bore
EXPOSE 7835
# Tunnel ports allocated by the server for each client connection
EXPOSE 10000-20000
CMD ["bore", "server", "--min-port", "10000", "--max-port", "20000"]
# To connect: bore local <port> --to <your-server-hostname>
