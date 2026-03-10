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
