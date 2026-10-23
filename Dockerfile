# The image Cloud Run runs.
#
# `gcloud run deploy --source .` builds this in the cloud with Cloud Build, so
# Docker does not need to be installed locally.

FROM python:3.12-slim

# PYTHONUNBUFFERED keeps log lines flowing immediately. In a container stdout is
# not a terminal, so without it logs arrive in bursts and the last lines before a
# crash are lost.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080

WORKDIR /srv

# Dependencies first, so this layer is only rebuilt when requirements.txt changes
# instead of on every source edit.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Nothing here needs root. A dedicated user also means the process cannot write to
# its own image, which makes "this service keeps no files" true rather than a hope.
RUN useradd --create-home --uid 10001 appuser
USER appuser

# Documentation only — Cloud Run routes to the port in $PORT regardless.
EXPOSE 8080

# --host 0.0.0.0        : accept traffic from outside the container.
# --port ${PORT}        : Cloud Run injects it and routes to nothing else.
# --proxy-headers       : TLS ends in front of this container, so the real client
#                         address only exists in X-Forwarded-For.
# --forwarded-allow-ips : the quoted '*' is one argv element on purpose; unquoted,
#                         the shell would expand it against the workdir.
# exec                   : uvicorn becomes PID 1 and receives Cloud Run's SIGTERM
#                         directly instead of a shell swallowing it.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --proxy-headers --forwarded-allow-ips '*' --timeout-keep-alive 65"]
