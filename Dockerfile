FROM python:3.12-slim

WORKDIR /app

COPY Backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY Backend/server.py /app/server.py
COPY Support /app/Support
RUN mkdir -p /app/data/avatars

ENV PRIME_MESSAGING_HOST=0.0.0.0

EXPOSE 8080

CMD ["python3", "/app/server.py"]
