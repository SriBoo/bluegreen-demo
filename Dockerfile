FROM python:3.12-slim

WORKDIR /app

COPY app.py .

ENV APP_VERSION=v1

EXPOSE 9000

CMD ["python", "app.py"]