# TimeTagger from PyPI, like upstream's own pip.Dockerfile, but pinned and
# unprivileged.
FROM python:3.13-slim-bookworm
ARG TIMETAGGER_VERSION=26.1.3
RUN pip install --no-cache-dir uvicorn uvloop httptools "timetagger==${TIMETAGGER_VERSION}" \
 && useradd -r -u 1000 -m timetagger
USER 1000
WORKDIR /home/timetagger
CMD ["python", "-m", "timetagger"]
