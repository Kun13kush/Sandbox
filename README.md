# DevOps Sandbox Platform

A self-service platform for spinning up isolated, temporary environments — deploy apps, simulate outages, monitor health, and auto-destroy on a TTL. Think of it as a miniature internal Heroku with a chaos engineering toggle.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Linux VM (single host)                       │
│                                                                       │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────────────────┐  │
│  │  Makefile /  │   │  Control API │   │   Cleanup Daemon        │  │
│  │  CLI         │──▶│  (FastAPI    │   │   cleanup_daemon.sh     │  │
│  │              │   │   :8000)     │   │   (runs every 60s)      │  │
│  └──────────────┘   └──────┬───────┘   └─────────────────────────┘  │
│                             │ wraps                                   │
│                    ┌────────▼──────────────────────┐                 │
│                    │        Shell Scripts           │                 │
│                    │  create_env.sh                │                 │
│                    │  destroy_env.sh               │                 │
│                    │  simulate_outage.sh           │                 │
│                    └────────┬──────────────────────┘                 │
│                             │                                         │
│          ┌──────────────────┼──────────────────────┐                 │
│          ▼                  ▼                      ▼                 │
│  ┌───────────────┐  ┌────────────────┐  ┌──────────────────────┐    │
│  │  Docker       │  │  Nginx         │  │  State Files         │    │
│  │  Networks     │  │  (container)   │  │  envs/*.json         │    │
│  │  (per env)    │  │  :80           │  │  (atomic writes)     │    │
│  └───────────────┘  │  conf.d/       │  └──────────────────────┘    │
│                      │  *.conf        │                               │
│  ┌───────────────┐  └────────────────┘  ┌──────────────────────┐    │
│  │  App          │                       │  Health Monitor      │    │
│  │  Containers   │◀──── proxies ────────│  health_poller.sh    │    │
│  │  (per env)    │                       │  (every 30s)         │    │
│  │  :10000-19999 │                       └──────────────────────┘    │
│  └───────────────┘                                                    │
│                                                                       │
│  logs/                                                                │
│  ├── <env-id>/app.log       (live log shipping via docker logs -f)   │
│  ├── <env-id>/health.log    (health poller output)                   │
│  ├── archived/<env-id>/     (post-destroy archives)                  │
│  └── cleanup.log            (daemon audit trail)                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool         | Minimum version | Check              |
|--------------|-----------------|--------------------|
| Docker       | 20.x            | `docker --version` |
| Python 3     | 3.9+            | `python3 --version`|
| jq           | 1.6+            | `jq --version`     |
| curl         | any             | `curl --version`   |
| ss / iproute2| any             | `ss --version`     |
| make         | any             | `make --version`   |

Install on Ubuntu:
```bash
sudo apt-get update && sudo apt-get install -y docker.io jq make python3-pip iproute2
sudo usermod -aG docker $USER   # then log out/in
```

---

## Quick Start (zero → first running env in 4 commands)

```bash
# 1. Clone the repo
git clone https://github.com/<your-org>/devops-sandbox.git && cd devops-sandbox

# 2. Copy environment config
cp .env.example .env

# 3. Start the platform (Nginx + daemon + monitor + API)
make up

# 4. Create your first environment
make create
# → prompts: name = "myapp", TTL = 1800
# → prints URL + TTL countdown
```

That's it. Open the printed URL in your browser.

---

## Full Demo Walkthrough

### 1 — Create an environment
```bash
make create
# name: demo-app
# TTL:  300   (5 minutes for the demo)
#
# ╔══════════════════════════════════════════════════════════╗
# ║  ✅  Environment Ready                                   ║
# ╠══════════════════════════════════════════════════════════╣
# ║  ID      : env-a3f7c2b1                                  ║
# ║  URL     : http://localhost:12345                        ║
# ║  Expires : 2025-07-01 14:05:00 UTC                      ║
# ╚══════════════════════════════════════════════════════════╝
```

### 2 — Verify the app is running
```bash
curl http://localhost:12345/health
# {"status":"ok","env_id":"env-a3f7c2b1","uptime":3.2,...}
```

### 3 — Check health status dashboard
```bash
make health
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#   ENV ID                STATUS       TTL REM  PORT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#   env-a3f7c2b1          running         247s  12345
```

### 4 — Simulate an outage
```bash
make simulate ENV=env-a3f7c2b1 MODE=crash
# ✅  Outage simulation 'crash' applied to env-a3f7c2b1
```

### 5 — Observe the health monitor react (within 90s)
```bash
tail -f logs/env-a3f7c2b1/health.log
# 2025-07-01T14:01:30Z  status=000  latency=5.001s  env=env-a3f7c2b1
# 2025-07-01T14:02:00Z  status=000  latency=5.001s  env=env-a3f7c2b1
# 2025-07-01T14:02:30Z  status=000  latency=5.001s  env=env-a3f7c2b1
# 2025-07-01T14:02:30Z  [ALERT] env-a3f7c2b1 marked degraded after 3 failures
```

### 6 — Recover
```bash
make simulate ENV=env-a3f7c2b1 MODE=recover
# ✅  Outage simulation 'recover' applied to env-a3f7c2b1
```

### 7 — Watch auto-destroy when TTL expires
The cleanup daemon logs to `logs/cleanup.log`:
```
[2025-07-01T14:05:01Z] ENV env-a3f7c2b1 expired (status=running) — destroying
[2025-07-01T14:05:02Z] ENV env-a3f7c2b1 destroyed successfully
```

### 8 — View archived logs
```bash
ls logs/archived/env-a3f7c2b1/
# app.log  health.log
```

---

## API Reference

Base URL: `http://localhost:8000`  
Interactive docs: `http://localhost:8000/docs`

| Method   | Path                     | Description                         |
|----------|--------------------------|-------------------------------------|
| `POST`   | `/envs`                  | Create environment                  |
| `GET`    | `/envs`                  | List environments + TTL remaining   |
| `DELETE` | `/envs/:id`              | Destroy environment                 |
| `GET`    | `/envs/:id/logs`         | Last 100 lines of app.log           |
| `GET`    | `/envs/:id/health`       | Last 10 health check results        |
| `POST`   | `/envs/:id/outage`       | Trigger simulation                  |

### Examples
```bash
# Create
curl -s -X POST http://localhost:8000/envs \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-service","ttl":600}' | jq

# List
curl -s http://localhost:8000/envs | jq

# Trigger outage
curl -s -X POST http://localhost:8000/envs/env-a3f7c2b1/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"pause"}' | jq

# Recover
curl -s -X POST http://localhost:8000/envs/env-a3f7c2b1/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"recover"}' | jq

# Destroy
curl -s -X DELETE http://localhost:8000/envs/env-a3f7c2b1 | jq
```

---

## Makefile Targets

```
make up                        Start Nginx, daemon, monitor, and API
make down                      Stop everything, destroy all envs
make build                     Build the sandbox-demo-app Docker image
make create                    Create a new environment (interactive)
make destroy ENV=env-abc123    Destroy a specific environment
make logs ENV=env-abc123       Tail app logs for an environment
make health                    Show all env health statuses
make simulate ENV=… MODE=…     Trigger outage simulation
make clean                     Wipe all state, logs, and archives
make help                      Show this help
```

---

## Outage Simulation Modes

| Mode      | What it does                                | Recovery         |
|-----------|---------------------------------------------|------------------|
| `crash`   | `docker kill` the container                 | `--mode recover` |
| `pause`   | `docker pause` — freezes the process        | `--mode recover` |
| `network` | Disconnects container from its network      | `--mode recover` |
| `recover` | Restores whatever was broken                | —                |
| `stress`  | Runs `stress-ng` inside container (60s)     | auto             |

> **Safety guard:** simulation will refuse to target `sandbox-nginx`, `sandbox-daemon`, or `sandbox-api` containers.

---

## Design Decisions

### Network isolation
Each environment gets its own Docker bridge network (`sandbox-net-<env-id>`), providing L2 isolation between envs. Nginx runs as a separate container with `host-gateway` access to reach host-bound app ports.

### State files
Written atomically: `write temp file → mv into place`. This prevents partial reads by the daemon or monitor.

### Log shipping (Approach A)
`docker logs -f $CONTAINER >> app.log &` — the PID is stored in the state file and killed on destroy to prevent zombie processes.

### Port allocation
Random port drawn from 10000–19999, with collision detection against both `ss` output and existing state files.

---

## Known Limitations

1. **Single-VM only** — no cluster support; Docker Swarm or K8s would be needed for multi-host.
2. **No TLS** — Nginx serves plain HTTP; add Certbot + Let's Encrypt for production.
3. **Nginx reloads are best-effort** — if the Nginx container is stopped, per-env configs persist on disk but won't be served until Nginx restarts.
4. **Log shipping PID** — PIDs can be reused after VM reboot; `make up` should be run after reboots.
5. **No auth on the API** — add an API key middleware for any internet-exposed deployment.
6. **`stress` mode** requires `stress-ng` to be installed inside the demo-app image.

---

## File Structure

```
devops-sandbox/
├── platform/
│   ├── lib.sh              # Shared helpers (logging, port picker, Nginx reload)
│   ├── create_env.sh       # Spin up an environment
│   ├── destroy_env.sh      # Tear down an environment
│   ├── cleanup_daemon.sh   # TTL enforcement loop
│   ├── simulate_outage.sh  # Chaos engineering modes
│   └── api.py              # FastAPI control plane
├── nginx/
│   ├── nginx.conf          # Main config (includes conf.d/*.conf)
│   └── conf.d/             # Auto-generated per-env configs (gitignored)
├── monitor/
│   └── health_poller.sh    # 30s health checks + degraded detection
├── demo-app/
│   ├── Dockerfile
│   └── app.py              # Sample FastAPI app running inside each env
├── logs/                   # Gitignored runtime logs
├── envs/                   # Gitignored state files
├── .github/workflows/ci.yml
├── docker-compose.yml
├── Makefile
├── .env.example
├── .gitignore
└── README.md
```
# Sandbox
