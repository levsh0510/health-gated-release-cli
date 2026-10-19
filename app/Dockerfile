FROM python:3.12-slim

# Version is fixed per image: mockapp:v1.0.0, mockapp:v2.0.0, ...
ARG APP_VERSION=v0.0.0
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Dependencies first, so this layer is cached when only app.py changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Don't run as root
RUN useradd --system --no-create-home appuser
USER appuser

EXPOSE 5000

# Gunicorn finishes in-flight requests on SIGTERM (graceful stop)
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--graceful-timeout", "10", "app:app"]
