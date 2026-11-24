#!/usr/bin/env node
/**
 * Pincer Browser Sidecar
 *
 * Manages one Playwright browser instance with one page per session.
 * Communicates with the Elixir host via newline-delimited JSON on stdin/stdout.
 *
 * Protocol:
 *   stdin  → {"id":"<req_id>","session":"<session_id>","cmd":"<action>",[...args]}
 *   stdout → {"id":"<req_id>","ok":"<result>"} | {"id":"<req_id>","error":"<message>"}
 *
 * Supported commands:
 *   navigate   { url }
 *   click      { selector }
 *   fill       { selector, value }
 *   press      { selector, key }
 *   select     { selector, value }
 *   screenshot { path }
 *   text       { selector? }          — extract_text
 *   attribute  { selector, attr }
 *   evaluate   { expression }
 *   content    {}
 *   close      {}
 *   ping       {}
 */

const { chromium } = require("playwright");
const readline = require("readline");
const path = require("path");
const fs = require("fs");
const dns = require("dns").promises;
const net = require("net");

const BLOCKED_HOSTS = new Set([
  "localhost",
  "localhost.localdomain",
  "ip6-localhost",
  "ip6-loopback",
  "metadata",
  "metadata.google.internal",
  "instance-data",
]);
const BLOCKED_SUFFIXES = [".localhost", ".local", ".internal", ".home.arpa"];

function ipv4Parts(address) {
  const parts = address.split(".").map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
    return null;
  }
  return parts;
}

function inIpv4Range(parts, base, prefix) {
  const ip = ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
  const baseIp = ((base[0] << 24) | (base[1] << 16) | (base[2] << 8) | base[3]) >>> 0;
  const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;
  return (ip & mask) === (baseIp & mask);
}

function isPrivateIpv4(address) {
  const p = ipv4Parts(address);
  if (!p) return true;
  return [
    [[0, 0, 0, 0], 8],
    [[10, 0, 0, 0], 8],
    [[100, 64, 0, 0], 10],
    [[127, 0, 0, 0], 8],
    [[169, 254, 0, 0], 16],
    [[172, 16, 0, 0], 12],
    [[192, 0, 0, 0], 24],
    [[192, 0, 2, 0], 24],
    [[192, 88, 99, 0], 24],
    [[192, 168, 0, 0], 16],
    [[198, 18, 0, 0], 15],
    [[198, 51, 100, 0], 24],
    [[203, 0, 113, 0], 24],
    [[224, 0, 0, 0], 4],
    [[240, 0, 0, 0], 4],
  ].some(([base, prefix]) => inIpv4Range(p, base, prefix));
}

function isPrivateIpv6(address) {
  const normalized = address.toLowerCase().split("%")[0];
  if (normalized === "::" || normalized === "::1") return true;

  const mapped = normalized.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return isPrivateIpv4(mapped[1]);

  const compatible = normalized.match(/^::(\d+\.\d+\.\d+\.\d+)$/);
  if (compatible) return isPrivateIpv4(compatible[1]);

  const first = parseInt(normalized.split(":")[0] || "0", 16);
  if (first >= 0xfc00 && first <= 0xfdff) return true;
  if (first >= 0xfe80 && first <= 0xfebf) return true;
  if (first >= 0xff00) return true;
  if (normalized.startsWith("2001:db8:")) return true;
  if (normalized.startsWith("2001:2:")) return true;
  if (normalized.startsWith("64:ff9b:")) return true;
  return false;
}

function isPrivateAddress(address) {
  if (net.isIPv4(address)) return isPrivateIpv4(address);
  if (net.isIPv6(address)) return isPrivateIpv6(address);
  return true;
}

async function assertPublicUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new Error(`Invalid URL: ${rawUrl}`);
  }

  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error(`Blocked URL scheme: ${url.protocol}`);
  }
  if (url.username || url.password) {
    throw new Error("URL credentials are not allowed");
  }

  const host = url.hostname
    .replace(/^\[|\]$/g, "")
    .replace(/\.$/, "")
    .toLowerCase();

  if (!host) throw new Error("Invalid URL host");
  if (BLOCKED_HOSTS.has(host)) throw new Error(`Blocked internal host: ${host}`);
  if (BLOCKED_SUFFIXES.some((suffix) => host.endsWith(suffix))) {
    throw new Error(`Blocked internal host: ${host}`);
  }

  if (net.isIP(host)) {
    if (isPrivateAddress(host)) throw new Error(`Blocked internal address: ${host}`);
    return;
  }

  let addresses;
  try {
    addresses = await dns.lookup(host, { all: true, verbatim: true });
  } catch {
    throw new Error(`Could not resolve host: ${host}`);
  }

  if (!addresses.length) throw new Error(`Could not resolve host: ${host}`);
  for (const { address } of addresses) {
    if (isPrivateAddress(address)) {
      throw new Error(`Blocked internal address for ${host}: ${address}`);
    }
  }
}

async function installNetworkGuard(page) {
  if (page.__pincerNetworkGuard) return;
  page.__pincerNetworkGuard = true;

  await page.route("**/*", async (route) => {
    const url = route.request().url();
    if (!/^https?:/i.test(url)) {
      return route.continue();
    }

    try {
      await assertPublicUrl(url);
      return route.continue();
    } catch {
      return route.abort("blockedbyclient").catch(() => {});
    }
  });
}

let browser = null;
/** @type {Map<string, import("playwright").Page>} */
const pages = new Map();

async function getBrowser() {
  if (!browser) {
    browser = await chromium.launch({ headless: true });
  }
  return browser;
}

async function getPage(session) {
  if (pages.has(session)) {
    return pages.get(session);
  }
  const b = await getBrowser();
  const page = await b.newPage();
  await installNetworkGuard(page);
  pages.set(session, page);
  return page;
}

async function closePage(session) {
  if (pages.has(session)) {
    const page = pages.get(session);
    pages.delete(session);
    await page.close().catch(() => {});
  }
}

async function handle(req) {
  const { id, session = "default", cmd } = req;

  try {
    if (cmd === "ping") {
      return reply(id, "pong");
    }

    if (cmd === "close") {
      await closePage(session);
      return reply(id, "closed");
    }

    const page = await getPage(session);

    switch (cmd) {
      case "navigate": {
        await assertPublicUrl(req.url);
        await page.goto(req.url, { waitUntil: "domcontentloaded" });
        const title = await page.title();
        const url = page.url();
        return reply(id, `Navigated to ${url}\nTitle: ${title}`);
      }

      case "click": {
        await page.click(req.selector);
        return reply(id, `Clicked: ${req.selector}`);
      }

      case "fill": {
        await page.fill(req.selector, req.value);
        return reply(id, `Filled ${req.selector}`);
      }

      case "press": {
        await page.press(req.selector, req.key);
        return reply(id, `Pressed ${req.key} on ${req.selector}`);
      }

      case "select": {
        await page.selectOption(req.selector, req.value);
        return reply(id, `Selected '${req.value}' in ${req.selector}`);
      }

      case "screenshot": {
        const screenshotPath = req.path || "screenshots/screenshot.png";
        const abs = path.isAbsolute(screenshotPath)
          ? screenshotPath
          : path.join(process.cwd(), screenshotPath);
        fs.mkdirSync(path.dirname(abs), { recursive: true });
        await page.screenshot({ path: abs, fullPage: false });
        return reply(id, `Screenshot saved to ${screenshotPath}`);
      }

      case "screenshot_inline": {
        // Returns the PNG as a base64 string so the caller can pass it to an LLM vision model.
        const buffer = await page.screenshot({ fullPage: false });
        return reply(id, buffer.toString("base64"));
      }

      case "text": {
        const sel = req.selector || "body";
        const text = await page.textContent(sel);
        return reply(id, text ?? "(no text content)");
      }

      case "attribute": {
        const value = await page.getAttribute(req.selector, req.attr);
        return reply(id, value ?? "(attribute not found)");
      }

      case "evaluate": {
        const result = await page.evaluate(req.expression);
        return reply(id, JSON.stringify(result));
      }

      case "content": {
        const html = await page.content();
        return reply(id, html);
      }

      default:
        return replyError(id, `Unknown command: ${cmd}`);
    }
  } catch (err) {
    return replyError(id, err.message ?? String(err));
  }
}

function reply(id, ok) {
  process.stdout.write(JSON.stringify({ id, ok }) + "\n");
}

function replyError(id, error) {
  process.stdout.write(JSON.stringify({ id, error }) + "\n");
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });

rl.on("line", (line) => {
  line = line.trim();
  if (!line) return;

  let req;
  try {
    req = JSON.parse(line);
  } catch {
    process.stdout.write(JSON.stringify({ id: null, error: "invalid JSON" }) + "\n");
    return;
  }

  handle(req);
});

rl.on("close", async () => {
  // stdin closed — clean shutdown
  for (const page of pages.values()) {
    await page.close().catch(() => {});
  }
  if (browser) await browser.close().catch(() => {});
  process.exit(0);
});

process.on("SIGTERM", async () => {
  for (const page of pages.values()) {
    await page.close().catch(() => {});
  }
  if (browser) await browser.close().catch(() => {});
  process.exit(0);
});
