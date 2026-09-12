# syntax=docker/dockerfile:1.7
# ----------- Stage 1: build wheels -----------
# Builder has compilers/headers; none of that ships in the final image.
FROM python:3.12-slim AS builder

# Apply OS security patches from the Debian security repo. This picks up
# fixes for base-image packages (perl-base, glibc, openssl, etc) that were
# outdated when the python:3.12-slim tag was last built. Trivy CI gates on
# CRITICAL — this keeps it honest.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
 && pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ----------- Stage 2: runtime -----------
FROM python:3.12-slim AS runtime

# Same OS-patch step for the runtime stage: the final shipped image needs
# to be patched, not just the builder we discard.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
 && rm -rf /var/lib/apt/lists/*

# Security: run as an unprivileged user, no shell for that user.
RUN groupadd -r app && useradd -r -g app -d /srv/app -s /usr/sbin/nologin app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

WORKDIR /srv

COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir /wheels/* && rm -rf /wheels

COPY --chown=app:app app/ ./app/

USER app
EXPOSE 8000

# Container-level health check (mirrored in the ECS task definition).
# Uses stdlib urllib so we don't add curl/wget to the image.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status==200 else 1)"

# --proxy-headers + --forwarded-allow-ips so the app sees the client IP from
# the ALB's X-Forwarded-For header instead of the ALB IP.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--proxy-headers", "--forwarded-allow-ips", "*"]
