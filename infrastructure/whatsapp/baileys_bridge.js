#!/usr/bin/env node
"use strict";

/**
 * Pincer WhatsApp bridge (Baileys) over JSONL STDIO.
 *
 * Inbound (stdin):
 * {"action":"send_message","chat_id":"551199000111@s.whatsapp.net","text":"hello"}
 *
 * Outbound (stdout):
 * {"type":"ready"}
 * {"type":"qr","qr":"..."}
 * {"type":"message","chat_id":"...","sender_id":"...","is_group":false,"text":"..."}
 * {"type":"error","reason":"..."}
 */

const readline = require("readline");
let qrcodeTerminal = null;
let activeSocket = null;
let stdinBound = false;
let reconnectTimer = null;
let pairingCodeDisabled = false;

try {
  qrcodeTerminal = require("qrcode-terminal");
} catch (_error) {
  qrcodeTerminal = null;
}

function emit(event) {
  process.stdout.write(JSON.stringify(event) + "\n");
}

function emitError(reason, details) {
  emit({
    type: "error",
    reason: String(reason || "unknown"),
    details: details || null,
  });
}

function scheduleReconnect() {
  if (reconnectTimer) return;

  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;

    boot().catch((error) => {
      emitError("reconnect_failed", { message: error.message });
      scheduleReconnect();
    });
  }, 1500);
}

function boolFromEnv(name, defaultValue) {
  const raw = process.env[name];

  if (raw == null || String(raw).trim() === "") {
    return defaultValue;
  }

  return ["1", "true", "yes", "on"].includes(String(raw).trim().toLowerCase());
}

function normalizePhone(phone) {
  return String(phone || "").replace(/\D/g, "").trim();
}

function maskPhone(phone) {
  if (!phone) return null;
  if (phone.length <= 4) return phone;
  return `${phone.slice(0, 2)}****${phone.slice(-4)}`;
}

function renderQrAscii(qrPayload, small) {
  if (!qrcodeTerminal || typeof qrcodeTerminal.generate !== "function") {
    return null;
  }

  try {
    let ascii = null;

    qrcodeTerminal.generate(qrPayload, { small }, (rendered) => {
      ascii = rendered;
    });

    if (typeof ascii === "string" && ascii.trim() !== "") {
      return ascii;
    }

    return null;
  } catch (_error) {
    return null;
  }
}

function extractText(message) {
  if (!message || typeof message !== "object") return null;
  if (typeof message.conversation === "string") return message.conversation;
  if (message.extendedTextMessage?.text) return message.extendedTextMessage.text;
  if (message.imageMessage?.caption) return message.imageMessage.caption;
  if (message.videoMessage?.caption) return message.videoMessage.caption;
  if (message.documentMessage?.caption) return message.documentMessage.caption;
  return null;
}

function bindStdin() {
  if (stdinBound) return;
  stdinBound = true;

  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });

  rl.on("line", async (line) => {
    const trimmed = (line || "").trim();
    if (!trimmed) return;

    let payload;

    try {
      payload = JSON.parse(trimmed);
    } catch (_error) {
      emitError("invalid_json");
      return;
    }

    if (payload.action !== "send_message") return;

    const chatId = String(payload.chat_id || "").trim();
    const text = String(payload.text || "").trim();

    if (!chatId || !text) {
      emitError("invalid_send_payload");
      return;
    }

    if (!activeSocket) {
      emitError("bridge_not_ready", { message: "WhatsApp socket is reconnecting" });
      return;
    }

    try {
      await activeSocket.sendMessage(chatId, { text });
    } catch (error) {
      emitError("send_failed", { message: error.message });
    }
  });
}

async function boot() {
  let makeWASocket;
  let useMultiFileAuthState;
  let fetchLatestBaileysVersion;
  let DisconnectReason;
  let pino;

  try {
    const baileys = require("@whiskeysockets/baileys");
    makeWASocket = baileys.default;
    useMultiFileAuthState = baileys.useMultiFileAuthState;
    fetchLatestBaileysVersion = baileys.fetchLatestBaileysVersion;
    DisconnectReason = baileys.DisconnectReason;
    pino = require("pino");
  } catch (error) {
    emitError("baileys_not_installed", { message: error.message });
    process.exit(1);
  }

  const authDir = process.env.WA_AUTH_DIR || "sessions/whatsapp";
  const logLevel = process.env.WA_LOG_LEVEL || "silent";
  const emitQrAscii = boolFromEnv("WA_QR_ASCII", true);
  const qrAsciiSmall = boolFromEnv("WA_QR_ASCII_SMALL", true);
  const pairingPhone = normalizePhone(process.env.WA_PAIRING_PHONE || "");

  const { state, saveCreds } = await useMultiFileAuthState(authDir);
  const { version } = await fetchLatestBaileysVersion();

  const sock = makeWASocket({
    auth: state,
    version,
    printQRInTerminal: false,
    logger: pino({ level: logLevel }),
  });

  activeSocket = sock;
  bindStdin();

  const shouldRequestPairingCode =
    pairingPhone && !pairingCodeDisabled && sock?.authState?.creds?.registered !== true;

  if (shouldRequestPairingCode) {
    try {
      const code = await sock.requestPairingCode(pairingPhone);

      if (code && String(code).trim() !== "") {
        emit({
          type: "pairing_code",
          code: String(code).trim(),
          phone: maskPhone(pairingPhone),
        });
      } else {
        pairingCodeDisabled = true;
        emitError("pairing_code_empty", { phone: maskPhone(pairingPhone) });
      }
    } catch (error) {
      pairingCodeDisabled = true;
      emitError("pairing_code_failed", {
        phone: maskPhone(pairingPhone),
        message: error.message,
      });
    }
  }

  sock.ev.on("creds.update", saveCreds);

  sock.ev.on("connection.update", (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      const payload = { type: "qr", qr };

      if (emitQrAscii) {
        const ascii = renderQrAscii(qr, qrAsciiSmall);

        if (ascii) {
          payload.ascii = ascii;
        }
      }

      emit(payload);
    }

    if (connection === "open") {
      emit({ type: "ready" });
    }

    if (connection === "close") {
      const statusCode = lastDisconnect?.error?.output?.statusCode;
      const loggedOut = statusCode === DisconnectReason.loggedOut;

      emit({
        type: "connection_closed",
        logged_out: Boolean(loggedOut),
        status_code: statusCode || null,
      });

      if (loggedOut) {
        emitError("session_logged_out", {
          status_code: statusCode || null,
          message: "Bridge reconnecting. Re-scan QR if needed.",
        });
      }

      if (activeSocket === sock) {
        activeSocket = null;
      }

      scheduleReconnect();
    }
  });

  sock.ev.on("messages.upsert", (upsert) => {
    const messages = upsert?.messages || [];

    for (const item of messages) {
      if (!item || item.key?.fromMe) continue;

      const text = extractText(item.message);
      if (!text || !text.trim()) continue;

      const chatId = item.key?.remoteJid || "";
      const senderId =
        item.key?.participant || item.key?.remoteJid || item.pushName || "unknown";
      const isGroup = typeof chatId === "string" && chatId.endsWith("@g.us");

      emit({
        type: "message",
        chat_id: chatId,
        sender_id: senderId,
        is_group: isGroup,
        text: text.trim(),
      });
    }
  });

  if (activeSocket === sock) {
    activeSocket = sock;
  }
}

boot().catch((error) => {
  emitError("bridge_boot_failed", { message: error.message });
  scheduleReconnect();
});
