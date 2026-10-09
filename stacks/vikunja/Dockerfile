# Vikunja's own binary (upstream image, pinned) on Alpine, so start.sh can
# create the first account before the server starts.
ARG VIKUNJA_VERSION=2.7.0
FROM vikunja/vikunja:${VIKUNJA_VERSION} AS upstream

FROM alpine:3.22
COPY --from=upstream /app/vikunja/vikunja /app/vikunja/vikunja
COPY start.sh /start.sh
WORKDIR /app/vikunja
ENV VIKUNJA_SERVICE_ROOTPATH=/app/vikunja/
EXPOSE 3456
USER 1000
ENTRYPOINT ["/start.sh"]
