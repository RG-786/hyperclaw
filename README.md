# hyperclaw
🤖 Multi-agent AI deployment system for Ubuntu 24.04 — Rust listener + Go gateway + Docker isolation + SQLite task queue. 1-core 1GB VPS ready.

# HyperClaw 🦾

A single-script deployment system for running a full multi-agent AI stack 
on minimal hardware (1-core, 1GB RAM VPS). Inspired by the ZeroClaw, 
NanoClaw, PicoClaw, and TinyClaw architectures.

## Architecture
- ⚡ ZeroClaw (Rust)   — Core listener binary, <10ms startup, <5MB idle RAM
- 🐳 NanoClaw (Docker) — Each agent isolated in its own container with scoped filesystem
- 🚀 PicoClaw (Go)     — Lightweight HTTP gateway for Telegram & Discord messaging
- 🗄️ TinyClaw (SQLite) — Multi-agent task queue with A→B handoff support

## Features
- One-script install: Rust, Go, Docker, SQLite auto-configured
- Setup Wizard for OpenAI & Anthropic API keys
- Manager CLI (hcmanager) to start/stop/status agents
- Sanity check with memory bar and container stats
- REST API gateway on :8765
- systemd service for auto-restart

## Quick Start
chmod +x hyperclaw.sh
./hyperclaw.sh install

## Usage
hcmanager start-all
hcmanager status
hcmanager sanity
hcmanager send agent-a agent-b code "Write hello world"


How to Pull & Run HyperClaw — Step by Step
Step 1 — Clone the Repo
bashgit clone https://github.com/RG-786/hyperclaw.git
cd hyperclaw
Step 2 — Make Script Executable
bashchmod +x hyperclaw.sh
Step 3 — Run the Installer
bash./hyperclaw.sh install
This will auto-install Rust, Go, Docker, SQLite, build all binaries, and launch the Setup Wizard for your API keys.
Step 4 — Reload Terminal
bashsource ~/.bashrc
Step 5 — Start All Agents
bashhcmanager start-all
Step 6 — Check Everything is Working
bashhcmanager status       # See all agents
hcmanager sanity       # Memory + health check
hcmanager queue        # View message queue
Step 7 — Send Your First Task
bash# Agent A sends a task to Agent B
hcmanager send agent-a agent-b code "Write a Python hello world script"
Step 8 — Watch it Process
bashhcmanager logs agent-b     # Watch Agent B handle the task
hcmanager queue            # See status change: pending → done

Quick Troubleshooting
ProblemFixhcmanager not foundRun source ~/.bashrcDocker permission deniedLog out and log back inAgent won't startRun hcmanager sanity to diagnoseNo AI responseRun ./hyperclaw.sh wizard to re-enter API keys
