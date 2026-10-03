# Anki's own sync server, from the anki package on PyPI (same code as the
# desktop app's built-in server). Keep the version close to your clients'.
FROM python:3.13-slim-bookworm
ARG ANKI_VERSION=26.9.3
RUN pip install --no-cache-dir "anki==${ANKI_VERSION}" \
 && useradd -r -u 1000 -m anki
USER 1000
WORKDIR /home/anki
CMD ["python", "-m", "anki.syncserver"]
