# DevOps Sandbox — Makefile
# All secrets via .env; never committed

-include .env
export

SHELL        := /bin/bash
ROOT_DIR     := $(shell pwd)
PLATFORM     := $(ROOT_DIR)/platform
DAEMON_PIDFILE := $(ROOT_DIR)/logs/daemon.pid
MONITOR_PIDFILE := $(ROOT_DIR)/logs/monitor.pid

.PHONY: up down create destroy logs health simulate clean build help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'

# ── Build demo app image ──────────────────────────────────────────────────────
build: ## Build the sandbox demo-app Docker image
	docker build -t sandbox-demo-app $(ROOT_DIR)/demo-app/

# ── Platform lifecycle ────────────────────────────────────────────────────────
up: build ## Start Nginx, cleanup daemon, monitor, and API
	@echo "▶  Starting Nginx..."
	@mkdir -p $(ROOT_DIR)/nginx/conf.d $(ROOT_DIR)/logs $(ROOT_DIR)/envs
	@docker rm -f sandbox-nginx 2>/dev/null || true
	docker run -d \
	  --name sandbox-nginx \
	  --add-host=host.docker.internal:host-gateway \
	  -p 80:80 \
	  -v $(ROOT_DIR)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
	  -v $(ROOT_DIR)/nginx/conf.d:/etc/nginx/conf.d:rw \
	  nginx:alpine
	@echo "▶  Starting cleanup daemon..."
	@mkdir -p $(ROOT_DIR)/logs
	@nohup bash $(PLATFORM)/cleanup_daemon.sh >> $(ROOT_DIR)/logs/cleanup.log 2>&1 & echo $$! > $(DAEMON_PIDFILE)
	@echo "▶  Starting health monitor..."
	@nohup bash $(ROOT_DIR)/monitor/health_poller.sh >> $(ROOT_DIR)/logs/monitor.log 2>&1 & echo $$! > $(MONITOR_PIDFILE)
	@echo "▶  Starting control API..."
	@pip install --quiet fastapi uvicorn pydantic 2>/dev/null || true
	@nohup python3 $(PLATFORM)/api.py >> $(ROOT_DIR)/logs/api.log 2>&1 & echo $$! > $(ROOT_DIR)/logs/api.pid
	@sleep 1
	@echo ""
	@echo "✅  Platform is UP"
	@echo "   Nginx    → http://localhost:80"
	@echo "   API      → http://localhost:8000"
	@echo "   API docs → http://localhost:8000/docs"

down: ## Stop everything and destroy all active environments
	@echo "▶  Destroying all environments..."
	@for f in $(ROOT_DIR)/envs/*.json; do \
	  [ -f "$$f" ] || continue; \
	  id=$$(jq -r '.id' "$$f"); \
	  echo "  → destroying $$id"; \
	  bash $(PLATFORM)/destroy_env.sh "$$id" 2>/dev/null || true; \
	done
	@echo "▶  Stopping background processes..."
	@[ -f $(DAEMON_PIDFILE)  ] && kill $$(cat $(DAEMON_PIDFILE))  2>/dev/null || true
	@[ -f $(MONITOR_PIDFILE) ] && kill $$(cat $(MONITOR_PIDFILE)) 2>/dev/null || true
	@[ -f $(ROOT_DIR)/logs/api.pid ] && kill $$(cat $(ROOT_DIR)/logs/api.pid) 2>/dev/null || true
	@docker rm -f sandbox-nginx 2>/dev/null || true
	@echo "✅  Platform is DOWN"

# ── Environment management ────────────────────────────────────────────────────
create: ## Create a new environment (prompts for name + TTL)
	@read -p "Environment name: " name; \
	 read -p "TTL in seconds [1800]: " ttl; \
	 ttl=$${ttl:-1800}; \
	 bash $(PLATFORM)/create_env.sh "$$name" "$$ttl"

destroy: ## Destroy a specific environment  (usage: make destroy ENV=env-abc123)
ifndef ENV
	$(error ENV is not set. Usage: make destroy ENV=env-abc123)
endif
	bash $(PLATFORM)/destroy_env.sh "$(ENV)"

logs: ## Tail app logs for an environment  (usage: make logs ENV=env-abc123)
ifndef ENV
	$(error ENV is not set. Usage: make logs ENV=env-abc123)
endif
	@LOG="$(ROOT_DIR)/logs/$(ENV)/app.log"; \
	 [ -f "$$LOG" ] || LOG="$(ROOT_DIR)/logs/archived/$(ENV)/app.log"; \
	 [ -f "$$LOG" ] && tail -f "$$LOG" || echo "No log file found for $(ENV)"

health: ## Show health status for all environments
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  ENV ID                STATUS       TTL REM  PORT"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@for f in $(ROOT_DIR)/envs/*.json; do \
	  [ -f "$$f" ] || continue; \
	  id=$$(jq -r '.id' "$$f"); \
	  status=$$(jq -r '.status' "$$f"); \
	  port=$$(jq -r '.host_port' "$$f"); \
	  created=$$(jq -r '.created_at' "$$f"); \
	  ttl=$$(jq -r '.ttl' "$$f"); \
	  now=$$(date +%s); \
	  rem=$$((created + ttl - now)); \
	  [ $$rem -lt 0 ] && rem=0; \
	  printf "  %-20s %-12s %6ss  %s\n" "$$id" "$$status" "$$rem" "$$port"; \
	done
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

simulate: ## Trigger outage simulation  (usage: make simulate ENV=env-abc123 MODE=crash)
ifndef ENV
	$(error ENV is not set. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
ifndef MODE
	$(error MODE is not set. Choices: crash|pause|network|recover|stress)
endif
	bash $(PLATFORM)/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

# ── Maintenance ───────────────────────────────────────────────────────────────
clean: ## Wipe all runtime state, logs, and archives (keeps code)
	@echo "⚠️   This will delete all logs, envs, and archived data."
	@read -p "Are you sure? [y/N] " confirm; [ "$$confirm" = "y" ] || exit 0
	@rm -rf $(ROOT_DIR)/logs/* $(ROOT_DIR)/envs/*.json $(ROOT_DIR)/nginx/conf.d/*.conf
	@echo "✅  Cleaned."
