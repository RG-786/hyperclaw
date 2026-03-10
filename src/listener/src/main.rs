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
