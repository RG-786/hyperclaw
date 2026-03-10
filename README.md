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
