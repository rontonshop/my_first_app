FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY backend/*.py ./backend/
ENV BIND_HOST=0.0.0.0 PORT=8787 FEED_DB_PATH=/data/feed.sqlite PYTHONUNBUFFERED=1
EXPOSE 8787
CMD ["python", "backend/server.py"]
