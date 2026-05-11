"""
Sandbox Demo App — a minimal FastAPI app that lives inside each environment.
Provides /health and a few demo endpoints.
"""
import os
import time
import random
from fastapi import FastAPI
from fastapi.responses import JSONResponse

app = FastAPI(title="Sandbox Demo App")

START_TIME = time.time()
ENV_ID   = os.getenv("ENV_ID", "unknown")
ENV_NAME = os.getenv("ENV_NAME", "unknown")

@app.get("/")
def root():
    return {
        "message": f"Hello from environment '{ENV_NAME}'!",
        "env_id":  ENV_ID,
        "uptime_seconds": round(time.time() - START_TIME, 1),
    }

@app.get("/health")
def health():
    """Health probe — always returns 200 while the container is alive."""
    return {
        "status":  "ok",
        "env_id":  ENV_ID,
        "env_name": ENV_NAME,
        "uptime":  round(time.time() - START_TIME, 1),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

@app.get("/info")
def info():
    return {
        "env_id":   ENV_ID,
        "env_name": ENV_NAME,
        "python":   "3.11",
        "framework": "FastAPI",
    }

@app.get("/random")
def random_data():
    """Returns random numbers — useful for testing latency in health logs."""
    return {"value": random.randint(1, 1000), "env_id": ENV_ID}
