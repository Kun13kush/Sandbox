#!/usr/bin/env python3
"""
DevOps Sandbox — Control API
Wraps the shell scripts and state files in a REST interface.
"""
import json
import os
import subprocess
import glob
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ── Config ────────────────────────────────────────────────────────────────────
ROOT_DIR = Path(__file__).parent.parent.resolve()
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
PLATFORM  = ROOT_DIR / "platform"

app = FastAPI(
    title="DevOps Sandbox API",
    description="Self-service ephemeral environment platform",
    version="1.0.0",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Pydantic models ───────────────────────────────────────────────────────────
class CreateEnvRequest(BaseModel):
    name: str
    ttl: Optional[int] = 1800   # seconds, default 30 min

class OutageRequest(BaseModel):
    mode: str   # crash | pause | network | recover | stress

# ── Helpers ───────────────────────────────────────────────────────────────────
def load_state(env_id: str) -> dict:
    path = ENVS_DIR / f"{env_id}.json"
    if not path.exists():
        raise HTTPException(404, f"Environment {env_id} not found")
    return json.loads(path.read_text())

def run_script(script: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(
        ["bash", str(script), *args],
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise HTTPException(500, detail=result.stderr or result.stdout)
    return result

def ttl_remaining(state: dict) -> int:
    return max(0, state["created_at"] + state["ttl"] - int(time.time()))

# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.post("/envs", status_code=201)
def create_env(body: CreateEnvRequest):
    """Spin up a new isolated environment."""
    result = run_script(PLATFORM / "create_env.sh", body.name, str(body.ttl))
    # Parse the env ID from stdout
    for line in result.stdout.splitlines():
        if "ID      :" in line:
            env_id = line.split(":", 1)[1].strip()
            return {"env_id": env_id, "output": result.stdout}
    return {"output": result.stdout}


@app.get("/envs")
def list_envs():
    """List all active environments with TTL remaining."""
    envs = []
    for f in sorted(ENVS_DIR.glob("*.json")):
        try:
            state = json.loads(f.read_text())
            envs.append({
                "id":            state["id"],
                "name":          state["name"],
                "status":        state["status"],
                "host_port":     state["host_port"],
                "ttl_remaining": ttl_remaining(state),
                "created_at":    state["created_at"],
            })
        except Exception:
            pass
    return {"environments": envs, "count": len(envs)}


@app.delete("/envs/{env_id}")
def destroy_env(env_id: str):
    """Destroy an environment immediately."""
    load_state(env_id)   # raises 404 if missing
    result = run_script(PLATFORM / "destroy_env.sh", env_id)
    return {"message": f"Environment {env_id} destroyed", "output": result.stdout}


@app.get("/envs/{env_id}/logs")
def get_logs(env_id: str, lines: int = 100):
    """Return the last N lines of the app log."""
    load_state(env_id)
    log_file = LOGS_DIR / env_id / "app.log"
    # Also check archive
    if not log_file.exists():
        log_file = LOGS_DIR / "archived" / env_id / "app.log"
    if not log_file.exists():
        return {"env_id": env_id, "lines": []}
    result = subprocess.run(
        ["tail", f"-{lines}", str(log_file)],
        capture_output=True, text=True,
    )
    return {"env_id": env_id, "lines": result.stdout.splitlines()}


@app.get("/envs/{env_id}/health")
def get_health(env_id: str, results: int = 10):
    """Return the last N health check results."""
    load_state(env_id)
    health_log = LOGS_DIR / env_id / "health.log"
    if not health_log.exists():
        return {"env_id": env_id, "results": []}
    result = subprocess.run(
        ["tail", f"-{results}", str(health_log)],
        capture_output=True, text=True,
    )
    parsed = []
    for line in result.stdout.splitlines():
        parts = line.split()
        entry = {"raw": line}
        for part in parts:
            if "=" in part:
                k, v = part.split("=", 1)
                entry[k] = v
        if parts:
            entry["timestamp"] = parts[0]
        parsed.append(entry)
    return {"env_id": env_id, "results": parsed}


@app.post("/envs/{env_id}/outage")
def trigger_outage(env_id: str, body: OutageRequest):
    """Trigger an outage simulation on the environment."""
    VALID_MODES = {"crash", "pause", "network", "recover", "stress"}
    if body.mode not in VALID_MODES:
        raise HTTPException(400, f"Invalid mode. Choose from: {VALID_MODES}")
    load_state(env_id)
    result = run_script(
        PLATFORM / "simulate_outage.sh",
        "--env", env_id,
        "--mode", body.mode,
    )
    return {"env_id": env_id, "mode": body.mode, "output": result.stdout}


@app.get("/health")
def api_health():
    """API liveness probe."""
    return {"status": "ok", "service": "devops-sandbox-api"}


if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("API_PORT", "8000"))
    uvicorn.run("api:app", host="0.0.0.0", port=port, reload=False)
