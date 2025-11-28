FROM oven/bun AS builder

WORKDIR /app

ARG PUB_ENV
ARG PUB_HOSTNAME
ARG PUB_PLAUSIBLE_URL
ARG PUB_VERTD_URL
ARG PUB_DISABLE_ALL_EXTERNAL_REQUESTS
ARG PUB_DONATION_URL
ARG PUB_STRIPE_KEY

ENV PUB_ENV=${PUB_ENV}
ENV PUB_HOSTNAME=${PUB_HOSTNAME}
ENV PUB_PLAUSIBLE_URL=${PUB_PLAUSIBLE_URL}
ENV PUB_VERTD_URL=${PUB_VERTD_URL}
ENV PUB_DISABLE_ALL_EXTERNAL_REQUESTS=${PUB_DISABLE_ALL_EXTERNAL_REQUESTS}
ENV PUB_DONATION_URL=${PUB_DONATION_URL}
ENV PUB_STRIPE_KEY=${PUB_STRIPE_KEY}

COPY package.json ./

RUN apt-get update && \
	apt-get install -y --no-install-recommends git && \
	rm -rf /var/lib/apt/lists/*

RUN bun install

COPY . ./

RUN bun run build

# -----------------------------------------------------------------------------
# Stage 2: Downloader (Backend)
# Fetches the latest 'vertd' binary dynamically using GitHub API.
# -----------------------------------------------------------------------------
FROM alpine:3.19 AS downloader

RUN apk add --no-cache curl jq

WORKDIR /downloads

RUN echo "Downloading nightly build #3 VERTD binary..." && \
    DOWNLOAD_URL="https://github.com/VERT-sh/vertd/releases/download/nightly-352463e1ae65a5afd87e250309656f4f2062d76a/vertd-linux-x86_64" && \
    echo "Downloading from: $DOWNLOAD_URL" && \
    # Using -sL for silent output and following redirects
    curl -sL -o vertd "$DOWNLOAD_URL" && \
    chmod +x vertd

# ------
# FINAL STAGE

FROM nginx:mainline

EXPOSE 80/tcp

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libstdc++6 \
        curl \
        procps \
        ca-certificates \
        ffmpeg \
        && rm -rf /var/lib/apt/lists/*

COPY ./nginx/default.conf /etc/nginx/conf.d/default.conf

COPY --from=builder /app/build /usr/share/nginx/html

COPY --from=downloader /downloads/vertd /usr/local/bin/vertd

# Create runner script to handle both processes reliably
RUN printf "#!/bin/sh\n\n" > /start.sh && \
    printf "echo 'Starting VERTD backend...'\n" >> /start.sh && \
    # Start vertd in the background and capture its PID
    printf "/usr/local/bin/vertd &\n" >> /start.sh && \
    printf "VERTD_PID=\$!\n" >> /start.sh && \
    printf "sleep 1\n" >> /start.sh && \
    \
    # Check if the process is running using 'kill -0', which is PID-only and works on BusyBox
    printf "if ! kill -0 \$VERTD_PID > /dev/null 2>&1; then\n" >> /start.sh && \
    printf "  echo 'Error: VERTD failed to start or immediately crashed. Check its logs.' >&2\n" >> /start.sh && \
    printf "  exit 1\n" >> /start.sh && \
    printf "fi\n\n" >> /start.sh && \
    \
    printf "echo 'Starting Nginx...'\n" >> /start.sh && \
    printf "exec nginx -g 'daemon off;'\n" >> /start.sh && \
    \
    chmod +x /start.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
	CMD curl --fail --silent --output /dev/null http://localhost || exit 1

CMD ["/start.sh"]
