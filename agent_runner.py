#!/usr/bin/env python3
"""
HyperClaw Agent Runner — Ollama Edition
100% free, runs on local Qwen/DeepSeek models
"""
import os
import sys
import json
import time
import sqlite3
import signal
import traceback
import urllib.request
from datetime import datetime

AGENT_ID  = os.environ.get("AGENT_ID",        "agent-unknown")
DB_PATH   = os.environ.get("HC_DB_PATH",       "/data/queue.db")
TEAM_FILE = os.environ.get("TEAMS_JSON",       "/config/teams.json")
OLLAMA_URL= os.environ.get("OLLAMA_BASE_URL",  "http://172.17.0.1:11434")
OLLAMA_MDL= os.environ.get("OLLAMA_MODEL",     "qwen3:8b")

running = True

def signal_handler(sig, frame):
    global running
    print(f"[{AGENT_ID}] Signal {sig} — shutting down...", flush=True)
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
    return conn.execute(
        """SELECT id, from_agent, task_type, payload, priority
           FROM message_queue
           WHERE to_agent=? AND status='pending'
           ORDER BY priority DESC, id ASC
           LIMIT 5""",
        (AGENT_ID,)
    ).fetchall()

def call_ollama(prompt, model=None):
    """Call local Ollama — completely free."""
    mdl = model or OLLAMA_MDL
    payload = json.dumps({
        "model":  mdl,
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": 0.7,
            "num_predict": 512
        }
    }).encode()

    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = json.loads(resp.read())
            return data.get("response", "No response received")
    except Exception as e:
        return f"[Ollama Error] {e} — check if Ollama is running"

def dispatch_task(task_type, payload, config):
    """Route task to handler based on type."""
    model = config.get("model", OLLAMA_MDL)

    prompts = {
        "echo":      lambda p: f"ECHO: {p}",
        "code":      lambda p: call_ollama(
                         f"You are an expert programmer. Write clean, working code for:\n{p}\n"
                         f"Provide only the code with brief comments.", model),
        "summarize": lambda p: call_ollama(
                         f"Summarize this concisely in 3-5 bullet points:\n{p}", model),
        "analyze":   lambda p: call_ollama(
                         f"Analyze this and provide key insights:\n{p}", model),
        "research":  lambda p: call_ollama(
                         f"Research and explain thoroughly:\n{p}", model),
        "handoff":   lambda p: call_ollama(
                         f"You received a handoff task. Process this:\n{p}", model),
        "generic":   lambda p: call_ollama(p, model),
    }

    handler = prompts.get(task_type, prompts["generic"])
    return handler(payload)

def process_task(conn, task, config):
    task_id   = task["id"]
    task_type = task["task_type"]
    payload   = task["payload"]

    print(f"[{AGENT_ID}] ▶ Task {task_id} | type={task_type}", flush=True)
    print(f"[{AGENT_ID}] Payload: {payload[:80]}...", flush=True)

    try:
        conn.execute(
            "UPDATE message_queue SET status='processing', updated_at=datetime('now') WHERE id=?",
            (task_id,)
        )
        conn.commit()

        result = dispatch_task(task_type, payload, config)

        print(f"[{AGENT_ID}] ✔ Task {task_id} done", flush=True)
        print(f"[{AGENT_ID}] Result preview: {result[:120]}...", flush=True)

        # Store result back in queue payload
        conn.execute(
            """UPDATE message_queue
               SET status='done', payload=?, updated_at=datetime('now')
               WHERE id=?""",
            (result[:2000], task_id)
        )
        conn.commit()
        return True

    except Exception as e:
        err = traceback.format_exc()
        print(f"[{AGENT_ID}] ✘ Task {task_id} FAILED: {e}", flush=True)
        conn.execute(
            """UPDATE message_queue
               SET status='failed', error_msg=?, retries=retries+1,
               updated_at=datetime('now') WHERE id=?""",
            (err[:500], task_id)
        )
        conn.commit()
        return False

def main():
    print(f"[{AGENT_ID}] 🚀 Starting | Ollama={OLLAMA_URL} | Model={OLLAMA_MDL}", flush=True)
    config = load_agent_config()
    print(f"[{AGENT_ID}] Role: {config.get('role','unknown')}", flush=True)

    conn = get_db()
    conn.execute(
        "UPDATE agents SET status='running', last_seen=datetime('now') WHERE id=?",
        (AGENT_ID,)
    )
    conn.commit()

    # Quick Ollama connectivity test
    print(f"[{AGENT_ID}] Testing Ollama connection...", flush=True)
    test = call_ollama("Reply with just: ONLINE", OLLAMA_MDL)
    print(f"[{AGENT_ID}] Ollama test: {test[:50]}", flush=True)

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
