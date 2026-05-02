# syntax=docker/dockerfile:1.6
#
# Bootstrap Dockerfile — extracts kira-railway-ready1.zip first, then runs
# the real build inside the extracted contents.
#
# Why this exists: the GitHub repo currently contains the zipped Kira app
# instead of its extracted contents. Rather than re-uploading 158 files
# manually, this Dockerfile unzips on the fly inside the build container
# and continues from there.
#
# Strategy mirrors the original 3-stage Dockerfile inside the zip, just
# preceded by an unzip stage.

# ─── Stage 0: Unzip ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS unzipper
WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Copy the zip from the repo root, then extract it.
# After extraction, the kira/ folder lives at /src/kira (because the zip
# was created with a top-level "kira/" wrapper directory).
COPY kira-railway-ready1.zip /src/app.zip
RUN unzip -q /src/app.zip -d /src && rm /src/app.zip

# Detect whether the zip wraps everything in a single top-level folder
# (e.g. "kira/") and if so, flatten it. This makes the rest of the build
# resilient to either layout.
RUN if [ -d /src/kira ] && [ -f /src/kira/package.json ]; then \
      mv /src/kira /src/app; \
    else \
      mkdir -p /src/app && \
      find /src -maxdepth 1 -mindepth 1 ! -name 'app' -exec mv {} /src/app/ \; ; \
    fi


# ─── Stage 1: Dependencies ──────────────────────────────────────────────────
FROM node:20-bookworm-slim AS deps
WORKDIR /app

ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN corepack enable && corepack prepare pnpm@10.4.1 --activate

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PUPPETEER_SKIP_DOWNLOAD=1

# Pull the extracted package.json from the unzipper stage
COPY --from=unzipper /src/app/package.json ./
RUN pnpm install --no-frozen-lockfile


# ─── Stage 2: Build ─────────────────────────────────────────────────────────
FROM deps AS build
WORKDIR /app

# Pull all source files from the unzipper stage
COPY --from=unzipper /src/app/ ./
RUN pnpm build


# ─── Stage 3: Runtime ───────────────────────────────────────────────────────
FROM node:20-bookworm-slim AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PUPPETEER_SKIP_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    whois \
    ca-certificates \
    fonts-liberation \
    fonts-noto-color-emoji \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
 && rm -rf /var/lib/apt/lists/*

ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN corepack enable && corepack prepare pnpm@10.4.1 --activate

# Install only production deps to keep image smaller.
COPY --from=unzipper /src/app/package.json ./
RUN pnpm install --prod --no-frozen-lockfile

# Copy built artifacts + config files needed at runtime.
COPY --from=build /app/dist ./dist
COPY --from=unzipper /src/app/drizzle ./drizzle
COPY --from=unzipper /src/app/drizzle.config.ts ./drizzle.config.ts
COPY --from=unzipper /src/app/shared ./shared

ENV PORT=3000
EXPOSE 3000

RUN groupadd --system --gid 1001 kira \
 && useradd --system --uid 1001 --gid kira --create-home kira \
 && chown -R kira:kira /app
USER kira

CMD ["node", "dist/index.js"]
