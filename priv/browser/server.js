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
