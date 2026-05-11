FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn 2>/dev/null

COPY app.py .

ENV ENV_ID=local
ENV ENV_NAME=local

EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
