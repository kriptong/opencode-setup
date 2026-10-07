#!/usr/bin/env node
// ============================================================
//  opencode-maintenance (Windows, Node.js) — ежедневная профилактика БД.
//  1) Удаляет старые неактивные сессии (порог RETENTION_DAYS) + их сообщения/события.
//  2) Удаляет события-сироты (главный раздуватель БД).
//  3) Валит WAL обратно в базу (checkpoint TRUNCATE).
//  4) Если opencode полностью закрыт — полный VACUUM.
//  5) Обрезает активный лог до разумного размера.
//  Поддерживает обе схемы: новую (session_v2/session_message) и старую
//  (session/message/part) — из исходного maintenance.sh для macOS.
//  Настройка: сколько дней хранить неактивные сессии (0 = удалять всё старше суток).
//  Запускается задачей Планировщика "opencode-maintenance" (см. setup.ps1).
// ============================================================
import { DatabaseSync } from "node:sqlite";
import { appendFileSync, existsSync, statSync, truncateSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execSync } from "node:child_process";

const RETENTION_DAYS = 3;
const RET_MS = RETENTION_DAYS * 86400000;
const DATA = join(homedir(), ".local", "share", "opencode");
const DB = join(DATA, "opencode.db");
const LOG = join(DATA, "log", "opencode.log");
const MAINT_LOG = join(DATA, "maintenance.log");
const LOGMAX = 52428800; // 50 МБ

const stamp = () => new Date().toISOString().replace("T", " ").slice(0, 19);
const say = (msg) => {
  try { appendFileSync(MAINT_LOG, `${stamp()} ${msg}\n`); } catch { /* лог недоступен — не мешаем работе */ }
};

// Определяем, закрыт ли opencode полностью (desktop + helper-процессы)
function opencodeRunning() {
  try {
    const out = execSync('tasklist /FI "IMAGENAME eq OpenCode.exe" /NH', { encoding: "utf8", windowsHide: true });
    return /OpenCode\.exe/i.test(out);
  } catch {
    return false;
  }
}

if (!existsSync(DB)) {
  say("нет базы, выход");
  process.exit(0);
}

const running = opencodeRunning();
const cutoff = Date.now() - RET_MS;

let db;
try {
  db = new DatabaseSync(DB);
  const tables = new Set(
    db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map((r) => r.name)
  );
  const has = (t) => tables.has(t);

  const lines = ["PRAGMA busy_timeout=300000;", "PRAGMA foreign_keys=ON;"];

  if (has("session_v2") && has("session_message")) {
    // Новая схема (opencode 1.x): session_v2, session_message, session_inbox, session_pending
    const fresh = `(SELECT id FROM session_v2 WHERE time_updated >= ${cutoff})`;
    lines.push(`DELETE FROM session_message WHERE session_id NOT IN ${fresh};`);
    if (has("session_inbox")) lines.push(`DELETE FROM session_inbox WHERE session_id NOT IN ${fresh};`);
    if (has("session_pending")) lines.push(`DELETE FROM session_pending WHERE session_id NOT IN ${fresh};`);
    lines.push(`DELETE FROM event WHERE aggregate_id NOT IN ${fresh};`);
    lines.push(`DELETE FROM event_sequence WHERE aggregate_id NOT IN ${fresh};`);
    lines.push(`DELETE FROM session_v2 WHERE time_updated < ${cutoff};`);
  } else if (has("session") && has("message")) {
    // Старая схема (из maintenance.sh): session, message, part, event
    const fresh = `(SELECT id FROM session WHERE time_updated >= ${cutoff})`;
    if (has("part")) lines.push(`DELETE FROM part WHERE message_id NOT IN (SELECT id FROM message WHERE session_id IN ${fresh});`);
    lines.push(`DELETE FROM message WHERE session_id NOT IN ${fresh};`);
    lines.push(`DELETE FROM event WHERE aggregate_id NOT IN ${fresh};`);
    lines.push(`DELETE FROM event_sequence WHERE aggregate_id NOT IN ${fresh};`);
    lines.push(`DELETE FROM session WHERE time_updated < ${cutoff};`);
  } else {
    say(`неизвестная схема БД (таблиц: ${[...tables].join(", ")}), пропускаю очистку сессий`);
  }

  lines.push("PRAGMA wal_checkpoint(TRUNCATE);");
  if (!running) lines.push("VACUUM;");

  say(`opencode_running=${running}, начинаю очистку`);
  db.exec(lines.join("\n"));
  say("готово");
} catch (err) {
  say(`ОШИБКА: ${err.message}`);
  process.exitCode = 1;
} finally {
  try { db?.close(); } catch { /* уже закрыта */ }
}

// Ротация лога opencode (безопасно для открытого дескриптора — просто усекаем)
try {
  if (existsSync(LOG) && statSync(LOG).size > LOGMAX) {
    truncateSync(LOG, 0);
    say("лог opencode обрезан");
  }
} catch { /* не критично */ }

// Ротация собственного лога (не даём ему расти вечно)
try {
  if (existsSync(MAINT_LOG) && statSync(MAINT_LOG).size > LOGMAX) {
    truncateSync(MAINT_LOG, 0);
  }
} catch { /* не критично */ }
