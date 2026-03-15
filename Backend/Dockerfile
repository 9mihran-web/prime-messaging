FROM python:3.12-slim

WORKDIR /app

COPY Backend/server.py /app/server.py

RUN mkdir -p /app/data/avatars

ENV PRIME_MESSAGING_HOST=0.0.0.0

EXPOSE 8080

CMD ["python3", "/app/server.py"]
