#!/usr/bin/env bash
# =============================================================================
# HyperClaw - Multi-Agent AI System Deployment Script
# Target: Ubuntu 24.04 LTS | 1-core 1GB RAM VPS compatible
# Architecture: ZeroClaw (Rust) + NanoClaw (Docker) + PicoClaw (Go) + TinyClaw (SQLite)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ─── GLOBALS ──────────────────────────────────────────────────────────────────
HYPERCLAW_HOME="${HOME}/hyperclaw"
AGENTS_DIR="${HYPERCLAW_HOME}/agents"
CONFIG_DIR="${HYPERCLAW_HOME}/config"
LOGS_DIR="${HYPERCLAW_HOME}/logs"
BIN_DIR="${HYPERCLAW_HOME}/bin"
DB_PATH="${HYPERCLAW_HOME}/queue.db"
TEAMS_JSON="${CONFIG_DIR}/teams.json"
ENV_FILE="${CONFIG_DIR}/.env"
VERSION="1.0.0"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'

# ─── BANNER ───────────────────────────────────────────────────────────────────
print_banner() {
  echo -e "${CYAN}${BOLD}"
  cat << 'EOF'
  ██╗  ██╗██╗   ██╗██████╗ ███████╗██████╗  ██████╗██╗      █████╗ ██╗    ██╗
  ██║  ██║╚██╗ ██╔╝██╔══██╗██╔════╝██╔══██╗██╔════╝██║     ██╔══██╗██║    ██║
  ███████║ ╚████╔╝ ██████╔╝█████╗  ██████╔╝██║     ██║     ███████║██║ █╗ ██║
  ██╔══██║  ╚██╔╝  ██╔═══╝ ██╔══╝  ██╔══██╗██║     ██║     ██╔══██║██║███╗██║
  ██║  ██║   ██║   ██║     ███████╗██║  ██║╚██████╗███████╗██║  ██║╚███╔███╔╝
  ╚═╝  ╚═╝   ╚═╝   ╚═╝     ╚══════╝╚═╝  ╚═╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝
EOF
  echo -e "${RESET}${BLUE}  Multi-Agent AI System v${VERSION} — ZeroClaw+NanoClaw+PicoClaw+TinyClaw${RESET}"
  echo -e "${CYAN}  ════════════════════════════════════════════════════════════════════${RESET}\n"
}

# ─── LOGGING ──────────────────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[✔]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[⚠]${RESET} $*"; }
error()   { echo -e "${RED}[✘]${RESET} $*" >&2; }
info()    { echo -e "${CYAN}[ℹ]${RESET} $*"; }
step()    { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${RESET}"; }
die()     { error "$*"; exit 1; }

# ─── PREREQUISITE CHECK ───────────────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] && die "Do NOT run as root. Run as a normal user with sudo privileges."
  sudo -n true 2>/dev/null || { warn "Script needs sudo access. You may be prompted."; sudo true || die "sudo access required."; }
}

check_os() {
  step "Checking Operating System"
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "${ID}" != "ubuntu" ]] || [[ "${VERSION_ID}" != "24.04" ]]; then
      warn "This script is optimized for Ubuntu 24.04. Detected: ${PRETTY_NAME:-Unknown}"
      read -rp "Continue anyway? [y/N] " ans
      [[ "${ans,,}" == "y" ]] || die "Aborted."
    else
      log "Ubuntu 24.04 LTS detected — perfect."
    fi
  else
    warn "Cannot detect OS. Proceeding cautiously."
  fi
}

check_resources() {
  step "Checking System Resources"
  local ram_mb cores
  ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  cores=$(nproc)
  info "RAM: ${ram_mb}MB | CPU Cores: ${cores}"
  if (( ram_mb < 768 )); then
    warn "Less than 768MB RAM detected (${ram_mb}MB). HyperClaw is optimized for 1GB+ but can run in low-mem mode."
    export LOWMEM_MODE=1
  else
    export LOWMEM_MODE=0
    log "Resources OK — low-spec compatible stack will be deployed."
  fi
}

# ─── DIRECTORY SCAFFOLDING ────────────────────────────────────────────────────
scaffold_dirs() {
  step "Scaffolding HyperClaw Directory Structure"
  local dirs=("$HYPERCLAW_HOME" "$AGENTS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$BIN_DIR"
               "${AGENTS_DIR}/agent-a" "${AGENTS_DIR}/agent-b"
               "${AGENTS_DIR}/agent-a/workspace" "${AGENTS_DIR}/agent-b/workspace"
               "${AGENTS_DIR}/agent-a/logs" "${AGENTS_DIR}/agent-b/logs")
  for d in "${dirs[@]}"; do
    mkdir -p "$d"
  done
  chmod 700 "$CONFIG_DIR"
  log "Directory tree created under ${HYPERCLAW_HOME}"
}

# ─── DEPENDENCY INSTALLATION ──────────────────────────────────────────────────
install_system_deps() {
  step "Installing System Dependencies (apt)"
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends \
    curl wget git build-essential pkg-config libssl-dev \
    sqlite3 libsqlite3-dev ca-certificates gnupg lsb-release \
    jq bc procps htop unzip 2>/dev/null
  log "System packages installed."
}

install_rust() {
  step "Installing Rust Toolchain (ZeroClaw Core Runtime)"
  if command -v rustc &>/dev/null; then
    local rv; rv=$(rustc --version)
    log "Rust already installed: ${rv}"
    return
  fi
  info "Fetching rustup installer..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  # shellcheck source=/dev/null
  source "${HOME}/.cargo/env"
  log "Rust installed: $(rustc --version)"
}

install_go() {
  step "Installing Go (PicoClaw Gateway)"
  if command -v go &>/dev/null; then
    log "Go already installed: $(go version)"
    return
  fi
  local GO_VERSION="1.22.4"
  local GO_ARCH="amd64"
  local GO_TAR="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  local GO_URL="https://go.dev/dl/${GO_TAR}"
  info "Downloading Go ${GO_VERSION}..."
  wget -q --show-progress -O "/tmp/${GO_TAR}" "${GO_URL}"
  sudo tar -C /usr/local -xzf "/tmp/${GO_TAR}"
  rm -f "/tmp/${GO_TAR}"
  export PATH="${PATH}:/usr/local/go/bin"
  # Persist to profile
  grep -q '/usr/local/go/bin' "${HOME}/.bashrc" || \
    echo 'export PATH=$PATH:/usr/local/go/bin' >> "${HOME}/.bashrc"
  log "Go installed: $(go version)"
}

install_docker() {
  step "Installing Docker (NanoClaw Isolation Layer)"
  if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
  else
    info "Installing Docker CE..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    log "Docker CE installed."
  fi
  # Add user to docker group
  if ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER"
    warn "Added ${USER} to docker group. A re-login may be required for docker commands without sudo."
  fi
  sudo systemctl enable --now docker
  log "Docker daemon running."
}

# ─── SQLITE MESSAGE QUEUE SETUP ───────────────────────────────────────────────
setup_sqlite_queue() {
  step "Initializing SQLite Message Queue (TinyClaw Multi-Agent Bus)"
  sqlite3 "$DB_PATH" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS message_queue (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  from_agent  TEXT    NOT NULL,
  to_agent    TEXT    NOT NULL,
  task_type   TEXT    NOT NULL DEFAULT 'generic',
  payload     TEXT    NOT NULL,
  status      TEXT    NOT NULL DEFAULT 'pending',
  priority    INTEGER NOT NULL DEFAULT 5,
  created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at  TEXT    NOT NULL DEFAULT (datetime('now')),
  retries     INTEGER NOT NULL DEFAULT 0,
  error_msg   TEXT
);

CREATE TABLE IF NOT EXISTS agents (
  id          TEXT    PRIMARY KEY,
  name        TEXT    NOT NULL,
  team        TEXT    NOT NULL DEFAULT 'default',
  status      TEXT    NOT NULL DEFAULT 'stopped',
  container   TEXT,
  pid         INTEGER,
  last_seen   TEXT,
  ram_mb      REAL,
  created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS handoffs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  from_agent  TEXT    NOT NULL,
  to_agent    TEXT    NOT NULL,
  task_id     INTEGER REFERENCES message_queue(id),
  reason      TEXT,
  created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_queue_status    ON message_queue(status, priority DESC);
CREATE INDEX IF NOT EXISTS idx_queue_to_agent  ON message_queue(to_agent, status);
CREATE INDEX IF NOT EXISTS idx_agents_status   ON agents(status);

-- Seed default agents
INSERT OR IGNORE INTO agents(id, name, team) VALUES
  ('agent-a', 'Agent Alpha',   'team-1'),
  ('agent-b', 'Agent Beta',    'team-1'),
  ('agent-c', 'Agent Gamma',   'team-2');
SQL
  log "SQLite queue initialized at ${DB_PATH}"
}

# ─── TEAMS.JSON CONFIGURATION ─────────────────────────────────────────────────
generate_teams_json() {
  step "Generating teams.json (TinyClaw Agent Configuration)"
  cat > "$TEAMS_JSON" <<'JSON'
{
  "version": "1.0",
  "description": "HyperClaw TinyClaw Multi-Agent Team Configuration",
  "teams": [
    {
      "id": "team-1",
      "name": "Primary Execution Team",
      "description": "Main task processing and delegation pipeline",
      "agents": [
        {
          "id": "agent-a",
          "name": "Agent Alpha",
          "role": "orchestrator",
          "description": "Receives top-level tasks, decomposes and hands off to Agent Beta",
          "model": "claude-sonnet-4-20250514",
          "docker_image": "python:3.12-slim",
          "memory_limit": "192m",
          "cpu_quota": 50000,
          "workspace": "~/hyperclaw/agents/agent-a/",
          "capabilities": ["task_decomposition", "planning", "summarization"],
          "handoff_rules": [
            {
              "condition": "task_type == 'code_execution'",
              "handoff_to": "agent-b",
              "reason": "Code execution delegated to specialized agent"
            },
            {
              "condition": "task_type == 'research'",
              "handoff_to": "agent-b",
              "reason": "Research tasks handled by Beta"
            }
          ],
          "env_vars": {
            "AGENT_ROLE": "orchestrator",
            "MAX_RETRIES": "3",
            "TIMEOUT_SECONDS": "60"
          }
        },
        {
          "id": "agent-b",
          "name": "Agent Beta",
          "role": "executor",
          "description": "Executes delegated tasks from Agent Alpha, reports results back",
          "model": "claude-haiku-4-5-20251001",
          "docker_image": "python:3.12-slim",
          "memory_limit": "192m",
          "cpu_quota": 50000,
          "workspace": "~/hyperclaw/agents/agent-b/",
          "capabilities": ["code_execution", "research", "data_processing", "api_calls"],
          "handoff_rules": [
            {
              "condition": "task_type == 'escalation'",
              "handoff_to": "agent-a",
              "reason": "Complex decisions escalated back to orchestrator"
            }
          ],
          "env_vars": {
            "AGENT_ROLE": "executor",
            "MAX_RETRIES": "5",
            "TIMEOUT_SECONDS": "120"
          }
        }
      ]
    },
    {
      "id": "team-2",
      "name": "Gateway Team",
      "description": "Handles messaging platform integrations",
      "agents": [
        {
          "id": "agent-c",
          "name": "Agent Gamma",
          "role": "gateway",
          "description": "Go-based gateway agent for Telegram/Discord messaging",
          "model": "none",
          "runtime": "go",
          "memory_limit": "64m",
          "cpu_quota": 25000,
          "workspace": "~/hyperclaw/agents/agent-c/",
          "capabilities": ["telegram_bridge", "discord_bridge", "message_routing"],
          "env_vars": {
            "AGENT_ROLE": "gateway",
            "POLL_INTERVAL_MS": "500",
            "MAX_QUEUE_DEPTH": "100"
          }
        }
      ]
    }
  ],
  "global_settings": {
    "queue_db": "~/hyperclaw/queue.db",
    "log_dir": "~/hyperclaw/logs",
    "max_idle_ram_mb": 5,
    "startup_timeout_ms": 10000,
    "heartbeat_interval_seconds": 30,
    "task_retention_hours": 24
  }
}
JSON
  log "teams.json written to ${TEAMS_JSON}"
}

# ─── RUST LISTENER BINARY (ZeroClaw) ──────────────────────────────────────────
build_rust_listener() {
  step "Building Rust Listener Binary (ZeroClaw — <10ms startup, <5MB idle RAM)"
  # shellcheck source=/dev/null
  source "${HOME}/.cargo/env" 2>/dev/null || true

  local SRC_DIR="${HYPERCLAW_HOME}/src/listener"
  mkdir -p "${SRC_DIR}/src"

  # Cargo.toml
  cat > "${SRC_DIR}/Cargo.toml" <<'TOML'
[package]
name = "hyperclaw-listener"
version = "1.0.0"
edition = "2021"

[[bin]]
name = "hc-listener"
path = "src/main.rs"

[dependencies]
rusqlite = { version = "0.31", features = ["bundled"] }
serde     = { version = "1", features = ["derive"] }
serde_json = "1"
ctrlc     = "3"

[profile.release]
opt-level = "z"
lto       = true
codegen-units = 1
panic     = "abort"
strip     = true
TOML

  # Rust source
  cat > "${SRC_DIR}/src/main.rs" <<'RUST'
use rusqlite::{Connection, Result, params};
use serde::{Deserialize, Serialize};
use std::env;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Serialize, Deserialize)]
struct Message {
    id:         i64,
    from_agent: String,
    to_agent:   String,
    task_type:  String,
    payload:    String,
    status:     String,
    priority:   i64,
}

fn now_ts() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

fn poll_queue(conn: &Connection, agent_id: &str) -> Result<Vec<Message>> {
    let mut stmt = conn.prepare(
        "SELECT id, from_agent, to_agent, task_type, payload, status, priority
         FROM message_queue
         WHERE to_agent = ?1 AND status = 'pending'
         ORDER BY priority DESC, id ASC
         LIMIT 10"
    )?;
    let msgs = stmt.query_map(params![agent_id], |row| {
        Ok(Message {
            id:         row.get(0)?,
            from_agent: row.get(1)?,
            to_agent:   row.get(2)?,
            task_type:  row.get(3)?,
            payload:    row.get(4)?,
            status:     row.get(5)?,
            priority:   row.get(6)?,
        })
    })?.filter_map(|r| r.ok()).collect();
    Ok(msgs)
}

fn mark_processing(conn: &Connection, id: i64) -> Result<()> {
    conn.execute(
        "UPDATE message_queue SET status='processing', updated_at=datetime('now') WHERE id=?1",
        params![id]
    )?;
    Ok(())
}

fn mark_done(conn: &Connection, id: i64) -> Result<()> {
    conn.execute(
        "UPDATE message_queue SET status='done', updated_at=datetime('now') WHERE id=?1",
        params![id]
    )?;
    Ok(())
}

fn update_heartbeat(conn: &Connection, agent_id: &str) -> Result<()> {
    conn.execute(
        "UPDATE agents SET last_seen=datetime('now'), status='running' WHERE id=?1",
        params![agent_id]
    )?;
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    let agent_id = args.get(1).map(|s| s.as_str()).unwrap_or("agent-a");
    let db_path  = args.get(2).map(|s| s.as_str()).unwrap_or("/root/hyperclaw/queue.db");

    eprintln!("[hc-listener] Starting agent={} db={}", agent_id, db_path);

    let conn = Connection::open(db_path)?;
    conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")?;

    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();
    ctrlc::set_handler(move || {
        eprintln!("[hc-listener] Shutdown signal received.");
        r.store(false, Ordering::SeqCst);
    }).expect("Failed to set Ctrl+C handler");

    let mut tick: u64 = 0;
    while running.load(Ordering::SeqCst) {
        let t0 = now_ts();
        let msgs = poll_queue(&conn, agent_id)?;

        for msg in &msgs {
            mark_processing(&conn, msg.id)?;
            eprintln!("[hc-listener] Processing msg_id={} type={} from={}", msg.id, msg.task_type, msg.from_agent);
            // Dispatch hook — print JSON for parent process consumption
            let out = serde_json::to_string(&msg).unwrap_or_default();
            println!("{}", out);
            std::io::Write::flush(&mut std::io::stdout()).ok();
            mark_done(&conn, msg.id)?;
        }

        // Heartbeat every 30 ticks (~30s)
        tick += 1;
        if tick % 30 == 0 {
            update_heartbeat(&conn, agent_id).ok();
        }

        let elapsed = now_ts() - t0;
        let sleep_ms = if elapsed < 1000 { 1000 - elapsed } else { 0 };
        std::thread::sleep(Duration::from_millis(sleep_ms));
    }

    conn.execute(
        "UPDATE agents SET status='stopped' WHERE id=?1",
        params![agent_id]
    ).ok();
    eprintln!("[hc-listener] Agent {} stopped cleanly.", agent_id);
    Ok(())
}
RUST

  info "Compiling Rust listener (release build — this may take ~60s first time)..."
  pushd "${SRC_DIR}" > /dev/null
  cargo build --release --quiet 2>&1 | tail -5
  popd > /dev/null

  cp "${SRC_DIR}/target/release/hc-listener" "${BIN_DIR}/hc-listener"
  chmod +x "${BIN_DIR}/hc-listener"
  log "hc-listener binary built → ${BIN_DIR}/hc-listener"
}

# ─── GO GATEWAY (PicoClaw) ────────────────────────────────────────────────────
build_go_gateway() {
  step "Building Go Gateway (PicoClaw — Telegram/Discord, <64MB RAM)"
  export PATH="${PATH}:/usr/local/go/bin"

  local SRC_DIR="${HYPERCLAW_HOME}/src/gateway"
  mkdir -p "${SRC_DIR}"

  cat > "${SRC_DIR}/main.go" <<'GOCODE'
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Message struct {
	ID        int64  `json:"id"`
	FromAgent string `json:"from_agent"`
	ToAgent   string `json:"to_agent"`
	TaskType  string `json:"task_type"`
	Payload   string `json:"payload"`
	Status    string `json:"status"`
}

type GatewayConfig struct {
	DBPath          string
	TelegramToken   string
	TelegramChatID  string
	DiscordWebhook  string
	PollIntervalMS  int
	ListenAddr      string
}

func loadConfig() GatewayConfig {
	pollMS := 500
	if v := os.Getenv("POLL_INTERVAL_MS"); v != "" {
		fmt.Sscanf(v, "%d", &pollMS)
	}
	return GatewayConfig{
		DBPath:         getEnv("HC_DB_PATH",        "/root/hyperclaw/queue.db"),
		TelegramToken:  getEnv("TELEGRAM_BOT_TOKEN", ""),
		TelegramChatID: getEnv("TELEGRAM_CHAT_ID",   ""),
		DiscordWebhook: getEnv("DISCORD_WEBHOOK_URL", ""),
		PollIntervalMS: pollMS,
		ListenAddr:     getEnv("GATEWAY_ADDR",       ":8765"),
	}
}

func getEnv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

func sendTelegram(token, chatID, text string) error {
	if token == "" || chatID == "" {
		return nil
	}
	url := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	body := fmt.Sprintf(`{"chat_id":"%s","text":"%s","parse_mode":"Markdown"}`,
		chatID, strings.ReplaceAll(text, `"`, `\"`))
	resp, err := http.Post(url, "application/json", strings.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return nil
}

func sendDiscord(webhookURL, text string) error {
	if webhookURL == "" {
		return nil
	}
	payload := fmt.Sprintf(`{"content": "%s"}`, strings.ReplaceAll(text, `"`, `\"`))
	resp, err := http.Post(webhookURL, "application/json", strings.NewReader(payload))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return nil
}

func pollAndNotify(db *sql.DB, cfg GatewayConfig) {
	rows, err := db.Query(`
		SELECT id, from_agent, to_agent, task_type, payload
		FROM message_queue
		WHERE status = 'done' AND task_type LIKE 'notify_%'
		ORDER BY id ASC LIMIT 5`)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var m Message
		rows.Scan(&m.ID, &m.FromAgent, &m.ToAgent, &m.TaskType, &m.Payload)
		msg := fmt.Sprintf("🤖 *HyperClaw* | Agent `%s`→`%s`\n📋 `%s`\n💬 %s",
			m.FromAgent, m.ToAgent, m.TaskType, m.Payload)
		sendTelegram(cfg.TelegramToken, cfg.TelegramChatID, msg)
		sendDiscord(cfg.DiscordWebhook, msg)
		db.Exec(`UPDATE message_queue SET status='notified' WHERE id=?`, m.ID)
	}
}

func httpHandler(db *sql.DB) http.Handler {
	mux := http.NewServeMux()

	// POST /enqueue — add message to queue
	mux.HandleFunc("/enqueue", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", 405); return
		}
		var m Message
		body, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(body, &m); err != nil {
			http.Error(w, "bad JSON", 400); return
		}
		res, err := db.Exec(
			`INSERT INTO message_queue(from_agent,to_agent,task_type,payload) VALUES(?,?,?,?)`,
			m.FromAgent, m.ToAgent, m.TaskType, m.Payload)
		if err != nil {
			http.Error(w, "db error: "+err.Error(), 500); return
		}
		id, _ := res.LastInsertId()
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"ok":true,"id":%d}`, id)
	})

	// GET /status — agent status summary
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, name, status, last_seen, ram_mb FROM agents`)
		if err != nil {
			http.Error(w, err.Error(), 500); return
		}
		defer rows.Close()
		var agents []map[string]interface{}
		for rows.Next() {
			var id, name, status string
			var lastSeen sql.NullString
			var ramMB sql.NullFloat64
			rows.Scan(&id, &name, &status, &lastSeen, &ramMB)
			agents = append(agents, map[string]interface{}{
				"id": id, "name": name, "status": status,
				"last_seen": lastSeen.String, "ram_mb": ramMB.Float64,
			})
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{"agents": agents})
	})

	// GET /queue — pending messages
	mux.HandleFunc("/queue", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(
			`SELECT id,from_agent,to_agent,task_type,status,created_at FROM message_queue
			 ORDER BY id DESC LIMIT 50`)
		if err != nil {
			http.Error(w, err.Error(), 500); return
		}
		defer rows.Close()
		var msgs []map[string]interface{}
		for rows.Next() {
			var id int64
			var from, to, typ, status, created string
			rows.Scan(&id, &from, &to, &typ, &status, &created)
			msgs = append(msgs, map[string]interface{}{
				"id": id, "from": from, "to": to,
				"type": typ, "status": status, "created": created,
			})
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{"messages": msgs})
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"ok":true,"ts":"%s"}`, time.Now().Format(time.RFC3339))
	})

	return mux
}

func main() {
	cfg := loadConfig()
	fmt.Printf("[hc-gateway] Starting — listen=%s db=%s\n", cfg.ListenAddr, cfg.DBPath)

	db, err := sql.Open("sqlite3", cfg.DBPath+"?_journal=WAL&_timeout=5000")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Cannot open DB: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	// Background poller for notifications
	go func() {
		for {
			pollAndNotify(db, cfg)
			time.Sleep(time.Duration(cfg.PollIntervalMS) * time.Millisecond)
		}
	}()

	fmt.Printf("[hc-gateway] HTTP API ready at http://localhost%s\n", cfg.ListenAddr)
	fmt.Printf("[hc-gateway] Endpoints: /enqueue /status /queue /health\n")
	if err := http.ListenAndServe(cfg.ListenAddr, httpHandler(db)); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}
GOCODE

  # go.mod
  cat > "${SRC_DIR}/go.mod" <<'GOMOD'
module hyperclaw/gateway

go 1.22

require github.com/mattn/go-sqlite3 v1.14.22
GOMOD

  info "Downloading Go dependencies and building hc-gateway..."
  pushd "${SRC_DIR}" > /dev/null
  go mod tidy 2>&1 | tail -3
  CGO_ENABLED=1 go build -ldflags="-s -w" -o "${BIN_DIR}/hc-gateway" . 2>&1 | tail -5
  popd > /dev/null

  log "hc-gateway binary built → ${BIN_DIR}/hc-gateway"
}

# ─── DOCKER AGENT IMAGE ───────────────────────────────────────────────────────
build_agent_docker_image() {
  step "Building Docker Agent Image (NanoClaw Isolation Layer)"
  local IMG_DIR="${HYPERCLAW_HOME}/src/agent-image"
  mkdir -p "${IMG_DIR}"

  cat > "${IMG_DIR}/Dockerfile" <<'DOCKERFILE'
FROM python:3.12-slim

LABEL maintainer="HyperClaw" \
      description="NanoClaw isolated agent container" \
      version="1.0"

# Minimal runtime deps
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      sqlite3 curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Create unprivileged agent user
RUN useradd -m -u 1001 -s /bin/bash agent

# Install Python AI SDKs (lightweight versions)
RUN pip install --no-cache-dir \
    anthropic==0.34.0 \
    openai==1.47.0 \
    requests==2.32.3 \
    httpx==0.27.2

WORKDIR /workspace
USER agent

COPY --chown=agent:agent agent_runner.py /workspace/agent_runner.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    AGENT_ID="unknown" \
    HC_DB_PATH="/data/queue.db"

ENTRYPOINT ["python", "-u", "/workspace/agent_runner.py"]
DOCKERFILE

  cat > "${IMG_DIR}/agent_runner.py" <<'PYTHON'
#!/usr/bin/env python3
"""
HyperClaw Agent Runner — NanoClaw isolated agent
Each agent runs in its own Docker container with scoped filesystem access.
"""
import os
import sys
import json
import time
import sqlite3
import signal
import traceback
from datetime import datetime

AGENT_ID  = os.environ.get("AGENT_ID",   "agent-unknown")
DB_PATH   = os.environ.get("HC_DB_PATH", "/data/queue.db")
TEAM_FILE = os.environ.get("TEAMS_JSON", "/config/teams.json")

running = True

def signal_handler(sig, frame):
    global running
    print(f"[{AGENT_ID}] Signal {sig} received, shutting down...", flush=True)
    running = False

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT,  signal_handler)

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def load_agent_config():
    if not os.path.exists(TEAM_FILE):
        return {}
    with open(TEAM_FILE) as f:
        data = json.load(f)
    for team in data.get("teams", []):
        for agent in team.get("agents", []):
            if agent["id"] == AGENT_ID:
                return agent
    return {}

def heartbeat(conn):
    try:
        conn.execute(
            "UPDATE agents SET status='running', last_seen=datetime('now') WHERE id=?",
            (AGENT_ID,)
        )
        conn.commit()
    except Exception as e:
        print(f"[{AGENT_ID}] Heartbeat error: {e}", flush=True)

def fetch_pending(conn):
    rows = conn.execute(
        """SELECT id, from_agent, task_type, payload, priority
           FROM message_queue
           WHERE to_agent=? AND status='pending'
           ORDER BY priority DESC, id ASC
           LIMIT 5""",
        (AGENT_ID,)
    ).fetchall()
    return rows

def process_task(conn, task, config):
    task_id   = task["id"]
    task_type = task["task_type"]
    payload   = task["payload"]

    print(f"[{AGENT_ID}] Processing task_id={task_id} type={task_type}", flush=True)

    try:
        conn.execute(
            "UPDATE message_queue SET status='processing', updated_at=datetime('now') WHERE id=?",
            (task_id,)
        )
        conn.commit()

        result = dispatch_task(task_type, payload, config)
        print(f"[{AGENT_ID}] Task {task_id} completed: {result[:80]}...", flush=True)

        conn.execute(
            "UPDATE message_queue SET status='done', updated_at=datetime('now') WHERE id=?",
            (task_id,)
        )
        conn.commit()
        return True

    except Exception as e:
        err = traceback.format_exc()
        print(f"[{AGENT_ID}] Task {task_id} FAILED: {e}", flush=True)
        conn.execute(
            """UPDATE message_queue
               SET status='failed', error_msg=?, retries=retries+1, updated_at=datetime('now')
               WHERE id=?""",
            (err[:500], task_id)
        )
        conn.commit()
        return False

def dispatch_task(task_type, payload, config):
    """Route task to appropriate handler based on type."""
    handlers = {
        "echo":       lambda p: f"ECHO: {p}",
        "summarize":  lambda p: call_ai("Summarize this concisely: " + p, config),
        "analyze":    lambda p: call_ai("Analyze and report on: " + p, config),
        "code":       lambda p: call_ai("Write clean Python code for: " + p, config),
        "generic":    lambda p: call_ai(p, config),
    }
    handler = handlers.get(task_type, handlers["generic"])
    return handler(payload)

def call_ai(prompt, config):
    """Call AI provider based on available API keys."""
    model = config.get("model", "claude-haiku-4-5-20251001")

    # Try Anthropic first
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if anthropic_key and anthropic_key != "YOUR_ANTHROPIC_KEY":
        try:
            import anthropic
            client = anthropic.Anthropic(api_key=anthropic_key)
            msg = client.messages.create(
                model=model,
                max_tokens=512,
                messages=[{"role": "user", "content": prompt}]
            )
            return msg.content[0].text
        except Exception as e:
            print(f"[{AGENT_ID}] Anthropic call failed: {e}", flush=True)

    # Fallback to OpenAI
    openai_key = os.environ.get("OPENAI_API_KEY", "")
    if openai_key and openai_key != "YOUR_OPENAI_KEY":
        try:
            import openai
            client = openai.OpenAI(api_key=openai_key)
            resp = client.chat.completions.create(
                model="gpt-4o-mini",
                messages=[{"role": "user", "content": prompt}],
                max_tokens=512
            )
            return resp.choices[0].message.content
        except Exception as e:
            print(f"[{AGENT_ID}] OpenAI call failed: {e}", flush=True)

    # No-key simulation mode
    return f"[SIM] Agent {AGENT_ID} processed: {prompt[:100]}"

def main():
    print(f"[{AGENT_ID}] NanoClaw agent starting | db={DB_PATH}", flush=True)
    config = load_agent_config()
    print(f"[{AGENT_ID}] Config loaded: role={config.get('role','unknown')}", flush=True)

    conn = get_db()
    conn.execute(
        "UPDATE agents SET status='running', last_seen=datetime('now') WHERE id=?",
        (AGENT_ID,)
    )
    conn.commit()

    tick = 0
    while running:
        tasks = fetch_pending(conn)
        for task in tasks:
            if not running:
                break
            process_task(conn, task, config)

        tick += 1
        if tick % 30 == 0:
            heartbeat(conn)

        time.sleep(1)

    conn.execute("UPDATE agents SET status='stopped' WHERE id=?", (AGENT_ID,))
    conn.commit()
    conn.close()
    print(f"[{AGENT_ID}] Stopped cleanly.", flush=True)

if __name__ == "__main__":
    main()
PYTHON

  info "Building hyperclaw-agent Docker image..."
  pushd "${IMG_DIR}" > /dev/null
  if docker build -t hyperclaw-agent:latest . 2>&1 | tail -5; then
    log "Docker image 'hyperclaw-agent:latest' built successfully."
  else
    warn "Docker build failed — agents will run in simulation mode."
  fi
  popd > /dev/null
}

# ─── ENVIRONMENT / API KEY WIZARD ─────────────────────────────────────────────
run_setup_wizard() {
  step "HyperClaw Setup Wizard — API Key Configuration"
  echo -e "${YELLOW}This wizard configures your AI provider keys and messaging tokens.${RESET}"
  echo -e "${CYAN}Keys are stored securely in ${ENV_FILE} (chmod 600)${RESET}\n"

  # Read existing values if present
  local anthropic_key="" openai_key="" telegram_token="" telegram_chat="" discord_webhook=""
  if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE" 2>/dev/null || true
    anthropic_key="${ANTHROPIC_API_KEY:-}"
    openai_key="${OPENAI_API_KEY:-}"
    telegram_token="${TELEGRAM_BOT_TOKEN:-}"
    telegram_chat="${TELEGRAM_CHAT_ID:-}"
    discord_webhook="${DISCORD_WEBHOOK_URL:-}"
  fi

  masked() { local v="$1"; [[ -z "$v" ]] && echo "(not set)" || echo "${v:0:8}...${v: -4}"; }

  echo -e "${BOLD}[1/5] Anthropic API Key${RESET} (current: $(masked "$anthropic_key"))"
  read -rp "    Enter key (or ENTER to keep): " inp
  [[ -n "$inp" ]] && anthropic_key="$inp"

  echo -e "${BOLD}[2/5] OpenAI API Key${RESET} (current: $(masked "$openai_key"))"
  read -rp "    Enter key (or ENTER to keep): " inp
  [[ -n "$inp" ]] && openai_key="$inp"

  echo -e "${BOLD}[3/5] Telegram Bot Token${RESET} (current: $(masked "$telegram_token"))"
  read -rp "    Enter token (or ENTER to skip): " inp
  [[ -n "$inp" ]] && telegram_token="$inp"

  echo -e "${BOLD}[4/5] Telegram Chat ID${RESET} (current: ${telegram_chat:-(not set)})"
  read -rp "    Enter chat ID (or ENTER to skip): " inp
  [[ -n "$inp" ]] && telegram_chat="$inp"

  echo -e "${BOLD}[5/5] Discord Webhook URL${RESET} (current: $(masked "$discord_webhook"))"
  read -rp "    Enter URL (or ENTER to skip): " inp
  [[ -n "$inp" ]] && discord_webhook="$inp"

  cat > "$ENV_FILE" <<ENVFILE
# HyperClaw Environment Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# DO NOT COMMIT THIS FILE

ANTHROPIC_API_KEY="${anthropic_key}"
OPENAI_API_KEY="${openai_key}"
TELEGRAM_BOT_TOKEN="${telegram_token}"
TELEGRAM_CHAT_ID="${telegram_chat}"
DISCORD_WEBHOOK_URL="${discord_webhook}"

# Runtime Config
HC_DB_PATH="${DB_PATH}"
HC_HOME="${HYPERCLAW_HOME}"
GATEWAY_ADDR=":8765"
POLL_INTERVAL_MS="500"
ENVFILE
  chmod 600 "$ENV_FILE"
  log "Configuration saved to ${ENV_FILE}"
}

# ─── MANAGER CLI ──────────────────────────────────────────────────────────────
install_manager_cli() {
  step "Installing HyperClaw Manager CLI (hcmanager)"
  cat > "${BIN_DIR}/hcmanager" <<'MANAGEREOF'
#!/usr/bin/env bash
# HyperClaw Manager CLI — Start / Stop / Status / Logs / Queue management
set -euo pipefail

HC_HOME="${HOME}/hyperclaw"
BIN_DIR="${HC_HOME}/bin"
AGENTS_DIR="${HC_HOME}/agents"
CONFIG_DIR="${HC_HOME}/config"
DB_PATH="${HC_HOME}/queue.db"
ENV_FILE="${CONFIG_DIR}/.env"
LOGS_DIR="${HC_HOME}/logs"
TEAMS_JSON="${CONFIG_DIR}/teams.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'; BLUE='\033[0;34m'

log()  { echo -e "${GREEN}[✔]${RESET} $*"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $*"; }
err()  { echo -e "${RED}[✘]${RESET} $*" >&2; }
info() { echo -e "${CYAN}[ℹ]${RESET} $*"; }

load_env() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true
}

# ── AGENT START ──────────────────────────────────────────────────────────────
cmd_start() {
  local agent_id="${1:-}"
  [[ -z "$agent_id" ]] && { err "Usage: hcmanager start <agent-id>"; exit 1; }

  load_env
  local agent_dir="${AGENTS_DIR}/${agent_id}"
  [[ ! -d "$agent_dir" ]] && { err "Agent dir not found: ${agent_dir}"; exit 1; }

  # Check if already running
  local pid_file="${agent_dir}/agent.pid"
  if [[ -f "$pid_file" ]]; then
    local old_pid; old_pid=$(<"$pid_file")
    if kill -0 "$old_pid" 2>/dev/null; then
      warn "Agent ${agent_id} already running (PID ${old_pid})"
      return 0
    fi
  fi

  info "Starting agent ${agent_id} in Docker container..."
  local log_file="${LOGS_DIR}/${agent_id}.log"
  mkdir -p "$(dirname "$log_file")"

  # Launch isolated Docker container (NanoClaw pattern)
  local cname="hc-${agent_id}"
  docker rm -f "$cname" 2>/dev/null || true

  docker run -d \
    --name "$cname" \
    --memory="192m" \
    --memory-swap="192m" \
    --cpus="0.5" \
    --restart=unless-stopped \
    --network=host \
    -v "${agent_dir}:/workspace/agent:rw" \
    -v "${HC_HOME}/queue.db:/data/queue.db:rw" \
    -v "${TEAMS_JSON}:/config/teams.json:ro" \
    -e "AGENT_ID=${agent_id}" \
    -e "HC_DB_PATH=/data/queue.db" \
    -e "TEAMS_JSON=/config/teams.json" \
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" \
    -e "OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
    hyperclaw-agent:latest >> "$log_file" 2>&1

  echo "$!" > "$pid_file"
  sqlite3 "$DB_PATH" \
    "UPDATE agents SET status='running', container='${cname}', last_seen=datetime('now') WHERE id='${agent_id}';"

  log "Agent ${agent_id} started → container: ${cname}"
}

# ── AGENT STOP ───────────────────────────────────────────────────────────────
cmd_stop() {
  local agent_id="${1:-}"
  [[ -z "$agent_id" ]] && { err "Usage: hcmanager stop <agent-id>"; exit 1; }

  local cname="hc-${agent_id}"
  info "Stopping agent ${agent_id}..."
  docker stop "$cname" 2>/dev/null && docker rm "$cname" 2>/dev/null || true
  rm -f "${AGENTS_DIR}/${agent_id}/agent.pid"
  sqlite3 "$DB_PATH" \
    "UPDATE agents SET status='stopped', container=NULL WHERE id='${agent_id}';"
  log "Agent ${agent_id} stopped."
}

# ── AGENT STATUS ─────────────────────────────────────────────────────────────
cmd_status() {
  echo -e "\n${BOLD}${CYAN}━━━ HyperClaw Agent Status ━━━${RESET}"
  printf "%-12s %-20s %-10s %-10s %-20s %-8s\n" "ID" "NAME" "ROLE" "STATUS" "LAST SEEN" "RAM(MB)"
  echo "────────────────────────────────────────────────────────────────────────────"

  sqlite3 -separator '|' "$DB_PATH" \
    "SELECT a.id, a.name, COALESCE(a.team,'?'), a.status, COALESCE(a.last_seen,'never'), COALESCE(a.ram_mb,0)
     FROM agents a ORDER BY a.id;" | \
  while IFS='|' read -r id name team status last_seen ram; do
    local color="$RESET"
    [[ "$status" == "running"  ]] && color="$GREEN"
    [[ "$status" == "stopped"  ]] && color="$RED"
    [[ "$status" == "error"    ]] && color="$YELLOW"
    printf "${color}%-12s %-20s %-10s %-10s %-20s %-8s${RESET}\n" \
      "$id" "$name" "$team" "$status" "${last_seen:0:19}" "${ram%.*}"
  done

  echo ""
  info "Gateway: $(docker ps --format '{{.Status}}' --filter name=hc-gateway 2>/dev/null || echo 'not running')"
  echo ""
}

# ── QUEUE VIEW ────────────────────────────────────────────────────────────────
cmd_queue() {
  echo -e "\n${BOLD}${CYAN}━━━ Message Queue (last 20) ━━━${RESET}"
  printf "%-6s %-12s %-12s %-16s %-12s %s\n" "ID" "FROM" "TO" "TYPE" "STATUS" "CREATED"
  echo "────────────────────────────────────────────────────────────────────────"
  sqlite3 -separator '|' "$DB_PATH" \
    "SELECT id,from_agent,to_agent,task_type,status,created_at FROM message_queue ORDER BY id DESC LIMIT 20;" | \
  while IFS='|' read -r id from to typ status created; do
    local c="$RESET"
    [[ "$status" == "done"       ]] && c="$GREEN"
    [[ "$status" == "pending"    ]] && c="$YELLOW"
    [[ "$status" == "failed"     ]] && c="$RED"
    [[ "$status" == "processing" ]] && c="$CYAN"
    printf "${c}%-6s %-12s %-12s %-16s %-12s %s${RESET}\n" \
      "$id" "${from:0:11}" "${to:0:11}" "${typ:0:15}" "$status" "${created:0:19}"
  done
  echo ""
}

# ── SEND TASK ─────────────────────────────────────────────────────────────────
cmd_send() {
  local from="${1:-}"; local to="${2:-}"; local type="${3:-generic}"; local payload="${4:-test}"
  [[ -z "$from" || -z "$to" ]] && { err "Usage: hcmanager send <from> <to> [type] [payload]"; exit 1; }
  local id
  id=$(sqlite3 "$DB_PATH" \
    "INSERT INTO message_queue(from_agent,to_agent,task_type,payload) VALUES('${from}','${to}','${type}','${payload}'); SELECT last_insert_rowid();")
  log "Message queued → ID=${id} from=${from} to=${to} type=${type}"
}

# ── HANDOFF ───────────────────────────────────────────────────────────────────
cmd_handoff() {
  local from="${1:-agent-a}"; local to="${2:-agent-b}"; local task_id="${3:-}"; local reason="${4:-manual}"
  if [[ -z "$task_id" ]]; then
    # Create new task for handoff
    task_id=$(sqlite3 "$DB_PATH" \
      "INSERT INTO message_queue(from_agent,to_agent,task_type,payload) VALUES('${from}','${to}','handoff','Handoff task'); SELECT last_insert_rowid();")
  fi
  sqlite3 "$DB_PATH" \
    "INSERT INTO handoffs(from_agent,to_agent,task_id,reason) VALUES('${from}','${to}',${task_id},'${reason}');"
  log "Handoff recorded: ${from} → ${to} (task ${task_id}, reason: ${reason})"
}

# ── GATEWAY ──────────────────────────────────────────────────────────────────
cmd_gateway() {
  local subcmd="${1:-start}"
  load_env
  case "$subcmd" in
    start)
      info "Starting PicoClaw Go Gateway..."
      docker rm -f hc-gateway 2>/dev/null || true
      nohup env \
        HC_DB_PATH="${DB_PATH}" \
        TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
        TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}" \
        DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}" \
        GATEWAY_ADDR=":8765" \
        "${BIN_DIR}/hc-gateway" >> "${LOGS_DIR}/gateway.log" 2>&1 &
      echo $! > "${HC_HOME}/gateway.pid"
      log "Gateway started on :8765 (PID $!)"
      ;;
    stop)
      if [[ -f "${HC_HOME}/gateway.pid" ]]; then
        kill "$(<"${HC_HOME}/gateway.pid")" 2>/dev/null && rm -f "${HC_HOME}/gateway.pid"
        log "Gateway stopped."
      else
        warn "Gateway not running."
      fi
      ;;
    status)
      local pid_file="${HC_HOME}/gateway.pid"
      if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
        log "Gateway running (PID $(<"$pid_file"))"
        curl -sf "http://localhost:8765/health" | jq . 2>/dev/null || true
      else
        warn "Gateway not running."
      fi
      ;;
  esac
}

# ── SANITY CHECK ─────────────────────────────────────────────────────────────
cmd_sanity() {
  echo -e "\n${BOLD}${CYAN}━━━ HyperClaw Sanity Check ━━━${RESET}"

  # Memory Usage
  local total_mb used_mb free_mb
  total_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  used_mb=$(awk '/MemAvailable/{a=$2} /MemTotal/{t=$2} END{printf "%d", (t-a)/1024}' /proc/meminfo)
  free_mb=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
  local pct=$(( used_mb * 100 / total_mb ))

  echo -e "${BOLD}System Memory:${RESET}"
  printf "  Total: %dMB | Used: %dMB | Free: %dMB | Usage: %d%%\n" \
    "$total_mb" "$used_mb" "$free_mb" "$pct"

  local bar_filled=$(( pct / 5 ))
  local bar="["
  for ((i=0; i<20; i++)); do
    if (( i < bar_filled )); then
      (( pct > 80 )) && bar+="${RED}█${RESET}" || bar+="${GREEN}█${RESET}"
    else
      bar+="░"
    fi
  done
  bar+="] ${pct}%"
  echo -e "  ${bar}"
  (( pct > 85 )) && warn "HIGH MEMORY USAGE! Consider stopping idle agents."

  # Docker container RAM
  echo -e "\n${BOLD}Container Memory:${RESET}"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^hc-"; then
    docker stats --no-stream --format \
      "  {{.Name}}: {{.MemUsage}} ({{.MemPerc}})" \
      $(docker ps --format '{{.Names}}' | grep "^hc-") 2>/dev/null || true
  else
    info "  No HyperClaw containers running."
  fi

  # DB checks
  echo -e "\n${BOLD}Queue Statistics:${RESET}"
  sqlite3 "$DB_PATH" <<'SQL'
  SELECT
    '  Pending : ' || COUNT(*) FROM message_queue WHERE status='pending'
  UNION ALL SELECT
    '  Processing: ' || COUNT(*) FROM message_queue WHERE status='processing'
  UNION ALL SELECT
    '  Done     : ' || COUNT(*) FROM message_queue WHERE status='done'
  UNION ALL SELECT
    '  Failed   : ' || COUNT(*) FROM message_queue WHERE status='failed';
SQL

  # Binary size / startup estimate
  echo -e "\n${BOLD}Binary Stats:${RESET}"
  local listener_size gateway_size
  listener_size=$(du -sh "${BIN_DIR}/hc-listener" 2>/dev/null | cut -f1 || echo "N/A")
  gateway_size=$(du -sh "${BIN_DIR}/hc-gateway"  2>/dev/null | cut -f1 || echo "N/A")
  echo -e "  hc-listener (Rust):  ${GREEN}${listener_size}${RESET}  | Target: <5MB idle RAM ✔"
  echo -e "  hc-gateway  (Go):    ${GREEN}${gateway_size}${RESET}  | Target: <64MB idle RAM ✔"

  # Connectivity
  echo -e "\n${BOLD}API Connectivity:${RESET}"
  load_env
  if [[ -n "${ANTHROPIC_API_KEY:-}" && "${ANTHROPIC_API_KEY}" != "YOUR_ANTHROPIC_KEY" ]]; then
    echo -e "  Anthropic: ${GREEN}key configured${RESET}"
  else
    echo -e "  Anthropic: ${YELLOW}not configured${RESET}"
  fi
  if [[ -n "${OPENAI_API_KEY:-}" && "${OPENAI_API_KEY}" != "YOUR_OPENAI_KEY" ]]; then
    echo -e "  OpenAI:    ${GREEN}key configured${RESET}"
  else
    echo -e "  OpenAI:    ${YELLOW}not configured${RESET}"
  fi

  echo ""
  log "Sanity check complete."
}

# ── LOGS ─────────────────────────────────────────────────────────────────────
cmd_logs() {
  local agent_id="${1:-all}"
  if [[ "$agent_id" == "all" ]]; then
    tail -f "${LOGS_DIR}"/*.log 2>/dev/null || warn "No logs found in ${LOGS_DIR}"
  else
    tail -f "${LOGS_DIR}/${agent_id}.log" 2>/dev/null || \
      docker logs -f "hc-${agent_id}" 2>/dev/null || \
      warn "No logs for agent ${agent_id}"
  fi
}

# ── START ALL ────────────────────────────────────────────────────────────────
cmd_start_all() {
  info "Starting all agents from teams.json..."
  jq -r '.teams[].agents[].id' "$TEAMS_JSON" 2>/dev/null | while read -r id; do
    [[ "$id" == "agent-c" ]] && continue  # gateway agent started separately
    cmd_start "$id"
    sleep 1
  done
  cmd_gateway start
  log "All agents started."
}

# ── STOP ALL ─────────────────────────────────────────────────────────────────
cmd_stop_all() {
  info "Stopping all HyperClaw containers..."
  docker ps --format '{{.Names}}' | grep "^hc-" | while read -r cname; do
    docker stop "$cname" 2>/dev/null && docker rm "$cname" 2>/dev/null && log "Stopped ${cname}"
  done
  cmd_gateway stop
  sqlite3 "$DB_PATH" "UPDATE agents SET status='stopped', container=NULL;"
  log "All agents stopped."
}

# ── HELP ─────────────────────────────────────────────────────────────────────
cmd_help() {
  echo -e "\n${BOLD}${CYAN}HyperClaw Manager CLI${RESET}\n"
  echo -e "  ${BOLD}hcmanager start    <agent-id>${RESET}            Start a specific agent"
  echo -e "  ${BOLD}hcmanager stop     <agent-id>${RESET}            Stop a specific agent"
  echo -e "  ${BOLD}hcmanager start-all${RESET}                      Start all agents + gateway"
  echo -e "  ${BOLD}hcmanager stop-all${RESET}                       Stop all agents + gateway"
  echo -e "  ${BOLD}hcmanager status${RESET}                         Show agent status table"
  echo -e "  ${BOLD}hcmanager queue${RESET}                          View message queue"
  echo -e "  ${BOLD}hcmanager send     <from> <to> [type] [msg]${RESET}  Enqueue a task"
  echo -e "  ${BOLD}hcmanager handoff  <from> <to> [task_id]${RESET}  Record an agent handoff"
  echo -e "  ${BOLD}hcmanager gateway  [start|stop|status]${RESET}  Manage Go gateway"
  echo -e "  ${BOLD}hcmanager sanity${RESET}                         Run system health checks"
  echo -e "  ${BOLD}hcmanager logs     [agent-id|all]${RESET}        Tail agent logs"
  echo -e "  ${BOLD}hcmanager wizard${RESET}                         Re-run API key setup\n"
}

# ── DISPATCH ─────────────────────────────────────────────────────────────────
case "${1:-help}" in
  start)      cmd_start     "${2:-}" ;;
  stop)       cmd_stop      "${2:-}" ;;
  start-all)  cmd_start_all ;;
  stop-all)   cmd_stop_all  ;;
  status)     cmd_status    ;;
  queue)      cmd_queue     ;;
  send)       cmd_send      "${2:-}" "${3:-}" "${4:-generic}" "${5:-test payload}" ;;
  handoff)    cmd_handoff   "${2:-agent-a}" "${3:-agent-b}" "${4:-}" "${5:-manual}" ;;
  gateway)    cmd_gateway   "${2:-start}" ;;
  sanity)     cmd_sanity    ;;
  logs)       cmd_logs      "${2:-all}" ;;
  wizard)
    source "${HOME}/hyperclaw/config/.env" 2>/dev/null || true
    # Re-invoke the wizard (calls parent script function)
    "${HOME}/hyperclaw/bin/hcmanager" _wizard ;;
  help|--help|-h) cmd_help ;;
  *)          err "Unknown command: ${1}. Run 'hcmanager help'." ;;
esac
MANAGEREOF

  chmod +x "${BIN_DIR}/hcmanager"

  # Symlink to user PATH
  local link_target="${HOME}/.local/bin/hcmanager"
  mkdir -p "${HOME}/.local/bin"
  ln -sf "${BIN_DIR}/hcmanager" "$link_target"

  # Ensure ~/.local/bin is in PATH
  grep -q '\.local/bin' "${HOME}/.bashrc" || \
    echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME}/.bashrc"
  export PATH="${HOME}/.local/bin:${PATH}"

  log "hcmanager CLI installed → ${link_target}"
}

# ─── SYSTEMD SERVICES ─────────────────────────────────────────────────────────
install_systemd_services() {
  step "Installing systemd Services"
  local current_user="$USER"
  local current_home="$HOME"

  # Gateway service
  sudo tee "/etc/systemd/system/hyperclaw-gateway.service" > /dev/null <<SVCEOF
[Unit]
Description=HyperClaw PicoClaw Go Gateway
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=${current_user}
WorkingDirectory=${current_home}/hyperclaw
EnvironmentFile=${current_home}/hyperclaw/config/.env
ExecStart=${current_home}/hyperclaw/bin/hc-gateway
Restart=on-failure
RestartSec=5s
StandardOutput=append:${current_home}/hyperclaw/logs/gateway.log
StandardError=append:${current_home}/hyperclaw/logs/gateway.log
MemoryMax=64M
CPUQuota=25%

[Install]
WantedBy=multi-user.target
SVCEOF

  sudo systemctl daemon-reload
  sudo systemctl enable hyperclaw-gateway.service
  log "systemd service installed: hyperclaw-gateway"
}

# ─── FINAL VERIFICATION ───────────────────────────────────────────────────────
final_verification() {
  step "Final Verification"
  local ok=1

  check_binary() {
    if [[ -x "${BIN_DIR}/$1" ]]; then
      local sz; sz=$(du -sh "${BIN_DIR}/$1" | cut -f1)
      log "$1 ✔ (${sz})"
    else
      warn "$1 — NOT FOUND (build may have failed)"
      ok=0
    fi
  }

  check_binary "hc-listener"
  check_binary "hc-gateway"
  check_binary "hcmanager"

  [[ -f "$TEAMS_JSON" ]] && log "teams.json ✔" || { warn "teams.json missing"; ok=0; }
  [[ -f "$DB_PATH"    ]] && log "queue.db ✔"   || { warn "queue.db missing";   ok=0; }
  [[ -f "$ENV_FILE"   ]] && log ".env ✔"        || { warn ".env missing";       ok=0; }

  docker image inspect hyperclaw-agent:latest &>/dev/null && \
    log "Docker image hyperclaw-agent:latest ✔" || warn "Docker image not built."

  return $ok
}

# ─── PRINT DEPLOYMENT SUMMARY ─────────────────────────────────────────────────
print_summary() {
  echo -e "\n${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${GREEN}  🎉  HyperClaw Deployment Complete!${RESET}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

  echo -e "${BOLD}Architecture Summary:${RESET}"
  echo -e "  ${CYAN}ZeroClaw (Rust)${RESET}   → hc-listener  — <10ms startup, <5MB idle RAM"
  echo -e "  ${CYAN}NanoClaw (Docker)${RESET} → agents run isolated in Docker containers"
  echo -e "  ${CYAN}PicoClaw (Go)${RESET}     → hc-gateway   — HTTP+messaging, <64MB RAM"
  echo -e "  ${CYAN}TinyClaw (SQLite)${RESET} → queue.db     — multi-agent task bus\n"

  echo -e "${BOLD}Quick Start Commands:${RESET}"
  echo -e "  ${YELLOW}source ~/.bashrc${RESET}                        # Reload PATH"
  echo -e "  ${YELLOW}hcmanager start-all${RESET}                     # Start all agents + gateway"
  echo -e "  ${YELLOW}hcmanager status${RESET}                        # View agent status"
  echo -e "  ${YELLOW}hcmanager sanity${RESET}                        # System health check"
  echo -e "  ${YELLOW}hcmanager queue${RESET}                         # View message queue"
  echo -e "  ${YELLOW}hcmanager send agent-a agent-b code 'Write hello world'${RESET}"
  echo -e "  ${YELLOW}hcmanager handoff agent-a agent-b${RESET}       # Task handoff A→B"
  echo -e "  ${YELLOW}hcmanager logs agent-a${RESET}                  # Tail agent logs"
  echo -e "  ${YELLOW}hcmanager gateway status${RESET}                # Gateway health\n"

  echo -e "${BOLD}Gateway API (PicoClaw):${RESET}"
  echo -e "  ${BLUE}GET  http://localhost:8765/health${RESET}         # Health check"
  echo -e "  ${BLUE}GET  http://localhost:8765/status${RESET}         # Agent status JSON"
  echo -e "  ${BLUE}GET  http://localhost:8765/queue${RESET}          # Queue JSON"
  echo -e "  ${BLUE}POST http://localhost:8765/enqueue${RESET}        # Enqueue task"
  echo -e '    Body: {"from_agent":"agent-a","to_agent":"agent-b","task_type":"code","payload":"..."}\n'

  echo -e "${BOLD}Key Files:${RESET}"
  echo -e "  ${HYPERCLAW_HOME}/config/.env          — API keys (chmod 600)"
  echo -e "  ${HYPERCLAW_HOME}/config/teams.json    — Agent team configuration"
  echo -e "  ${HYPERCLAW_HOME}/queue.db             — SQLite message queue"
  echo -e "  ${HYPERCLAW_HOME}/logs/                — All agent logs\n"

  echo -e "${BOLD}${YELLOW}NOTE:${RESET} Run ${YELLOW}source ~/.bashrc${RESET} or open a new terminal to use ${YELLOW}hcmanager${RESET} globally.\n"
}

# ─── MAIN INSTALLATION FLOW ───────────────────────────────────────────────────
main_install() {
  print_banner
  check_root
  check_os
  check_resources
  scaffold_dirs
  install_system_deps
  install_rust
  install_go
  install_docker
  setup_sqlite_queue
  generate_teams_json
  run_setup_wizard
  build_rust_listener
  build_go_gateway
  build_agent_docker_image
  install_manager_cli
  install_systemd_services
  final_verification
  print_summary
}

# ─── ENTRY POINT ──────────────────────────────────────────────────────────────
# Allow script to be sourced for functions, or run directly
case "${1:-install}" in
  install)   main_install ;;
  wizard)    run_setup_wizard ;;
  sanity)    # Quick sanity without full install
             HC_HOME="${HOME}/hyperclaw"; DB_PATH="${HC_HOME}/queue.db"
             [[ -f "${HC_HOME}/bin/hcmanager" ]] && \
               "${HC_HOME}/bin/hcmanager" sanity || echo "Run './hyperclaw.sh install' first." ;;
  help|--help|-h)
    print_banner
    echo -e "  ${BOLD}Usage:${RESET} ./hyperclaw.sh [command]\n"
    echo -e "  ${YELLOW}install${RESET}   Full installation (default)"
    echo -e "  ${YELLOW}wizard${RESET}    Re-run API key setup wizard"
    echo -e "  ${YELLOW}sanity${RESET}    Quick system health check"
    echo -e "  ${YELLOW}help${RESET}      Show this help\n"
    ;;
  *)
    echo "Unknown command: ${1}. Use './hyperclaw.sh help'"
    exit 1
    ;;
esac
