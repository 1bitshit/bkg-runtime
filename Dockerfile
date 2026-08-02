FROM python:3.14-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    ca-certificates \
    gnupg \
    screen \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x (for npm CLIs)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install bun for `bunx --yes claude`
ENV BUN_INSTALL=/root/.bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH=$BUN_INSTALL/bin:$PATH

# Create apps directory
WORKDIR /app

# Copy runtime files
COPY bin/ /app/bin/
COPY .env /app/.env
COPY start-claude-nim.sh /app/start-claude-nim.sh
COPY setup-claude.sh /app/setup-claude.sh
RUN chmod +x /app/start-claude-nim.sh /app/bin/claude-nim-w1 /app/bin/claude-nim-w2 /app/bin/claude-nim-w3

# Expose ports
EXPOSE 7000 7001 7002

# Default: start all instances
CMD ["./start-claude-nim.sh", "start", "--all"]
