FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    APP_VERSION=v1

WORKDIR /app

COPY app.py .

EXPOSE 9000

# deploy.ps1 waits for this to report "healthy" before switching traffic.
HEALTHCHECK --interval=3s --timeout=2s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9000/health', timeout=2)"]

CMD ["python", "app.py"]
