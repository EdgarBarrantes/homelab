# Kismet from its own Ubuntu packages (there is no official image): the
# server, the Linux Wi-Fi capture tool and the log tools (kismetdb_* for
# exports), plus iw/ip for start.sh and radio.sh. Bump KISMET_VERSION with
# the image tag in compose.yml.
FROM ubuntu:24.04
ARG KISMET_VERSION=2025-09-R1
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg iw iproute2 tzdata \
 && curl -fsSL --retry 5 https://www.kismetwireless.net/repos/kismet-release.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/kismet.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/kismet.gpg] https://www.kismetwireless.net/repos/apt/release/noble noble main" \
    > /etc/apt/sources.list.d/kismet.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    kismet-core=$KISMET_VERSION kismet-capture-linux-wifi=$KISMET_VERSION kismet-logtools=$KISMET_VERSION \
 && rm -rf /var/lib/apt/lists/*
