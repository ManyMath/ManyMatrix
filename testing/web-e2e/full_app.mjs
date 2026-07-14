// Full Flutter web workflow against the in-process Tuwunel tier. Drives the
// rendered accessibility DOM in a fresh browser profile rather than calling
// the Worker protocol directly.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createReadStream} from 'node:fs';
import {stat, writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import {dirname, extname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

import puppeteer from 'puppeteer';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const actorBinary =
  process.env.ACTOR_BIN ?? resolve(repoRoot, 'target/debug/web_e2e_actor');
const webRoot = resolve(repoRoot, 'apps/ManyMatrix/build/web');

class Actor {
  constructor() {
    this.child = spawn(actorBinary, ['embedded'], {
      stdio: ['pipe', 'pipe', 'inherit'],
    });
    this.pending = new Map();
    this.nextId = 1;
    this.ready = new Promise((resolveReady, rejectReady) => {
      this.resolveReady = resolveReady;
      this.child.once('exit', (code) =>
        rejectReady(new Error(`embedded actor exited before ready (${code})`)),
      );
    });
    this.ready.catch(() => {});
    createInterface({input: this.child.stdout}).on('line', (line) => {
      const message = JSON.parse(line);
      if (message.ready) {
        this.resolveReady(message);
        return;
      }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.ok) pending.resolve(message);
      else pending.reject(new Error(message.error));
    });
  }

  command(cmd, fields = {}) {
    const id = this.nextId++;
    return new Promise((resolveCommand, rejectCommand) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectCommand(new Error(`actor command ${cmd} timed out`));
      }, 90_000);
      this.pending.set(id, {resolve: resolveCommand, reject: rejectCommand, timer});
      this.child.stdin.write(`${JSON.stringify({id, cmd, ...fields})}\n`);
    });
  }

  async stop() {
    await this.command('stop');
    const code = await new Promise((resolveExit) =>
      this.child.once('exit', resolveExit),
    );
    if (code !== 0) throw new Error(`embedded actor exited with code ${code}`);
  }

  kill() {
    this.child.kill('SIGKILL');
  }
}

const mimeTypes = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.png': 'image/png',
  '.wasm': 'application/wasm',
};
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://127.0.0.1');
    const relative = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    const path = resolve(webRoot, decodeURIComponent(relative));
    if (!path.startsWith(`${webRoot}/`) && path !== resolve(webRoot, 'index.html')) {
      response.writeHead(403).end();
      return;
    }
    const info = await stat(path);
    if (!info.isFile()) throw new Error('not a file');
    response.writeHead(200, {
      'cache-control': 'no-store',
      'content-length': info.size,
      'content-type': mimeTypes[extname(path)] ?? 'application/octet-stream',
    });
    createReadStream(path).pipe(response);
  } catch (_) {
    response.writeHead(404).end();
  }
});

async function enableSemantics(page, {minimumNodes = 6} = {}) {
  await page.waitForSelector('flt-semantics-placeholder', {
    timeout: 30_000,
  });
  // Flutter deliberately positions this activator as a one-pixel offscreen
  // accessibility target. Geometric clicks can hit the platform-view overlay,
  // and the root view can reclaim keyboard focus before Enter is dispatched.
  // Invoke the activator's DOM click contract directly instead.
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (!(placeholder instanceof HTMLElement)) {
      throw new Error('Flutter semantics activator is unavailable');
    }
    placeholder.click();
  });
  try {
    await page.waitForFunction(
      () => document.querySelector('flt-semantics-placeholder') === null,
      {timeout: 2_000},
    );
  } catch (_) {
    const center = await page.evaluate(() => {
      const placeholder = document.querySelector('flt-semantics-placeholder');
      if (!(placeholder instanceof HTMLElement)) return null;
      Object.assign(placeholder.style, {
        display: 'block',
        position: 'fixed',
        left: '0px',
        top: '0px',
        width: '48px',
        height: '48px',
        zIndex: '2147483647',
        pointerEvents: 'auto',
      });
      const bounds = placeholder.getBoundingClientRect();
      return {x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2};
    });
    if (center != null) await page.mouse.click(center.x, center.y);
  }
  await page.waitForFunction(
    (minimum) => document.querySelectorAll('flt-semantics').length >= minimum,
    {timeout: 60_000},
    minimumNodes,
  );
}

async function fillField(page, label, value) {
  const selector = `input[aria-label="${label}"], textarea[aria-label="${label}"]`;
  await page.waitForSelector(selector, {timeout: 15_000});
  // Flutter's semantics input is only an accessibility proxy. DOM `fill`
  // mutates that proxy without reaching the framework's text controller.
  // A real pointer tap and keyboard events exercise Flutter's editing channel.
  await page.evaluate(() => {
    for (const element of document.querySelectorAll(
      'flt-semantics, flt-semantics-host',
    )) {
      element.style.pointerEvents = 'none';
    }
  });
  let focused = false;
  for (const [dx, dy] of [[0, 0], [0, -4], [0, 4]]) {
    const fields = await page.$$(selector);
    let bounds = null;
    for (const field of fields.reverse()) {
      const candidate = await field.boundingBox();
      if (candidate && candidate.width > 0 && candidate.height > 0) {
        bounds = candidate;
        break;
      }
    }
    if (!bounds) throw new Error(`field has no bounds: ${label}`);
    await page.mouse.click(
      bounds.x + bounds.width / 2 + dx,
      bounds.y + bounds.height / 2 + dy,
    );
    try {
      await page.waitForFunction(
        (expectedLabel) =>
          document.activeElement?.classList.contains('flt-text-editing') ||
          document.activeElement?.getAttribute('aria-label') === expectedLabel,
        {timeout: 2_000},
        label,
      );
      focused = true;
      break;
    } catch (_) {
      // Flutter may still be settling a route transition; retry nearby.
    }
  }
  if (!focused) throw new Error(`Flutter text field did not focus: ${label}`);
  const selectModifier = process.platform === 'darwin' ? 'Meta' : 'Control';
  await page.keyboard.down(selectModifier);
  await page.keyboard.press('A');
  await page.keyboard.up(selectModifier);
  await page.keyboard.press('Backspace');
  await page.keyboard.sendCharacter(value);
}

async function screenshotStats(page, screenshot) {
  return page.evaluate(async (encoded) => {
    const bytes = Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));
    const bitmap = await createImageBitmap(new Blob([bytes], {type: 'image/png'}));
    const canvas = document.createElement('canvas');
    canvas.width = 96;
    canvas.height = 64;
    const context = canvas.getContext('2d', {willReadFrequently: true});
    context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    bitmap.close();
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
    const buckets = new Map();
    let minLuminance = 255;
    let maxLuminance = 0;
    for (let index = 0; index < pixels.length; index += 4) {
      const red = pixels[index];
      const green = pixels[index + 1];
      const blue = pixels[index + 2];
      const bucket = `${red >> 4}:${green >> 4}:${blue >> 4}`;
      buckets.set(bucket, (buckets.get(bucket) ?? 0) + 1);
      const luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
      minLuminance = Math.min(minLuminance, luminance);
      maxLuminance = Math.max(maxLuminance, luminance);
    }
    const dominant = [...buckets.entries()].reduce((best, entry) =>
      entry[1] > best[1] ? entry : best,
    );
    const background = dominant[0]
      .split(':')
      .map((channel) => Number(channel) * 16 + 7.5);
    const cellMeaningful = Array(16).fill(0);
    const cellTotals = Array(16).fill(0);
    let meaningfulPixels = 0;
    let topMeaningfulPixels = 0;
    let topPixels = 0;
    let bottomMeaningfulPixels = 0;
    let bottomPixels = 0;
    for (let index = 0; index < pixels.length; index += 4) {
      const pixelIndex = index / 4;
      const x = pixelIndex % canvas.width;
      const y = Math.floor(pixelIndex / canvas.width);
      const cell =
        Math.min(3, Math.floor(y / (canvas.height / 4))) * 4 +
        Math.min(3, Math.floor(x / (canvas.width / 4)));
      cellTotals[cell] += 1;
      const inTopRegion = y < canvas.height / 4;
      const inBottomRegion = y >= (canvas.height * 3) / 4;
      if (inTopRegion) topPixels += 1;
      if (inBottomRegion) bottomPixels += 1;
      const differs = Math.max(
        Math.abs(pixels[index] - background[0]),
        Math.abs(pixels[index + 1] - background[1]),
        Math.abs(pixels[index + 2] - background[2]),
      ) >= 24;
      if (differs) {
        meaningfulPixels += 1;
        cellMeaningful[cell] += 1;
        if (inTopRegion) topMeaningfulPixels += 1;
        if (inBottomRegion) bottomMeaningfulPixels += 1;
      }
    }
    const pixelCount = canvas.width * canvas.height;
    return {
      uniqueColorBuckets: buckets.size,
      luminanceRange: maxLuminance - minLuminance,
      dominantFraction: dominant[1] / pixelCount,
      meaningfulFraction: meaningfulPixels / pixelCount,
      topMeaningfulFraction: topMeaningfulPixels / topPixels,
      bottomMeaningfulFraction: bottomMeaningfulPixels / bottomPixels,
      activeCells: cellMeaningful.filter(
        (count, index) => count / cellTotals[index] >= 0.015,
      ).length,
    };
  }, screenshot.toString('base64'));
}

function semanticSurfaceMatches({texts = [], fields = [], buttons = []}) {
  const normalize = (value) => String(value ?? '').replace(/\s+/g, ' ').trim();
  const semantics = [...document.querySelectorAll('flt-semantics')];
  const hasText = (text) => {
    const expected = normalize(text);
    return semantics.some((element) =>
      normalize(
        `${element.textContent ?? ''} ${element.getAttribute('aria-label') ?? ''}`,
      ).includes(expected),
    );
  };
  const hasField = (field) =>
    document.querySelector(
      `input[aria-label="${CSS.escape(field)}"], ` +
        `textarea[aria-label="${CSS.escape(field)}"]`,
    ) !== null;
  const hasButton = (label) =>
    [...document.querySelectorAll('[role="button"]')].some(
      (element) =>
        normalize(element.getAttribute('aria-label')) === normalize(label) ||
        normalize(element.parentElement?.getAttribute('aria-label')) ===
          normalize(label) ||
        normalize(element.textContent) === normalize(label),
    );
  return texts.every(hasText) && fields.every(hasField) && buttons.every(hasButton);
}

async function captureStableFrame(
  page,
  {
    path,
    label,
    texts = [],
    fields = [],
    buttons = [],
    requiredRegions = ['top', 'bottom'],
    minimumMeaningfulFraction = 0.035,
  },
) {
  let lastStats = null;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const landmarksPresent = await page.evaluate(semanticSurfaceMatches, {
      texts,
      fields,
      buttons,
    });
    if (landmarksPresent) {
      await page.evaluate(
        () =>
          new Promise((resolveFrame) =>
            requestAnimationFrame(() => requestAnimationFrame(resolveFrame)),
          ),
      );
      const screenshot = await page.screenshot();
      lastStats = await screenshotStats(page, screenshot);
      if (
        screenshot.length > 4_000 &&
        lastStats.uniqueColorBuckets >= 8 &&
        lastStats.luminanceRange >= 35 &&
        lastStats.dominantFraction < 0.98 &&
        lastStats.meaningfulFraction >= minimumMeaningfulFraction &&
        lastStats.activeCells >= 4 &&
        (!requiredRegions.includes('top') ||
          lastStats.topMeaningfulFraction >= 0.005) &&
        (!requiredRegions.includes('bottom') ||
          lastStats.bottomMeaningfulFraction >= 0.005)
      ) {
        await writeFile(path, screenshot);
        return lastStats;
      }
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 250));
  }
  throw new Error(
    `${label} did not produce a stable full frame: ${JSON.stringify(lastStats)}`,
  );
}

async function buttonHandle(page, label, {last = false} = {}) {
  try {
    await page.waitForFunction(
      (text) => {
        const labelled = [...document.querySelectorAll(`[aria-label="${CSS.escape(text)}"]`)]
          .flatMap((element) =>
            element.getAttribute('role') === 'button'
              ? [element]
              : [...element.querySelectorAll('[role="button"]')],
          );
        const textButtons = [...document.querySelectorAll('[role="button"]')].filter(
          (element) => element.textContent.trim() === text,
        );
        return [...labelled, ...textButtons].length > 0;
      },
      {timeout: 20_000},
      label,
    );
  } catch (error) {
    const semantics = await page.evaluate(() => ({
      buttons: [...document.querySelectorAll('[role="button"]')].map((element) => ({
        label: element.getAttribute('aria-label'),
        text: element.textContent.trim(),
      })),
      fields: [...document.querySelectorAll('input, textarea')].map((element) =>
        element.getAttribute('aria-label'),
      ),
      semanticsCount: document.querySelectorAll('flt-semantics').length,
    }));
    throw new Error(
      `button ${JSON.stringify(label)} unavailable: ${JSON.stringify(semantics)}`,
      {cause: error},
    );
  }
  const handles = await page.$$('[role="button"]');
  const matches = [];
  for (const handle of handles) {
    const matchesLabel = await handle.evaluate(
      (element, text) =>
        element.getAttribute('aria-label') === text ||
        element.parentElement?.getAttribute('aria-label') === text ||
        element.textContent.trim() === text,
      label,
    );
    if (matchesLabel) matches.push(handle);
  }
  if (matches.length === 0) throw new Error(`button not found: ${label}`);
  return last ? matches.at(-1) : matches[0];
}

async function clickButton(page, label, options) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const button = await buttonHandle(page, label, options);
    try {
      await button.click();
      return;
    } catch (error) {
      if (!String(error).includes('Node is detached') || attempt === 2) {
        throw error;
      }
      await new Promise((resolveWait) => setTimeout(resolveWait, 100));
    }
  }
}

async function buttonHandleStartingWith(page, labelPrefix) {
  await page.waitForFunction(
    (prefix) =>
      [...document.querySelectorAll('[role="button"]')].some((element) => {
        const labels = [
          element.getAttribute('aria-label') ??
            '',
          element.parentElement?.getAttribute('aria-label') ?? '',
          element.textContent ?? '',
        ].map((label) => label.replace(/\s+/g, ' ').trim());
        return labels.some((label) => label.startsWith(prefix));
      }),
    {timeout: 60_000},
    labelPrefix,
  );
  for (const handle of await page.$$('[role="button"]')) {
    const matches = await handle.evaluate((element, prefix) => {
      const labels = [
        element.getAttribute('aria-label') ?? '',
        element.parentElement?.getAttribute('aria-label') ?? '',
        element.textContent ?? '',
      ].map((label) => label.replace(/\s+/g, ' ').trim());
      return labels.some((label) => label.startsWith(prefix));
    }, labelPrefix);
    if (matches) return handle;
  }
  throw new Error(`button not found with prefix: ${labelPrefix}`);
}

async function clickButtonStartingWith(page, labelPrefix) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const button = await buttonHandleStartingWith(page, labelPrefix);
    try {
      await button.click();
      return;
    } catch (error) {
      if (!String(error).includes('Node is detached') || attempt === 2) {
        throw error;
      }
      await new Promise((resolveWait) => setTimeout(resolveWait, 100));
    }
  }
}

async function clickRoomTile(page, roomName) {
  const expectedPrefix = `Open room ${roomName}`;
  await page.waitForFunction(
    ({prefix, name}) =>
      [...document.querySelectorAll('[role="button"]')].some((element) => {
        const aria = (element.getAttribute('aria-label') ?? '')
          .replace(/\s+/g, ' ')
          .trim();
        const text = (element.textContent ?? '').replace(/\s+/g, ' ').trim();
        return aria.startsWith(prefix) || text.startsWith(prefix) || text.startsWith(name);
      }),
    {timeout: 20_000},
    {prefix: expectedPrefix, name: roomName},
  );
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const buttons = await page.$$('[role="button"]');
    let tile = null;
    for (const button of buttons) {
      const match = await button.evaluate(
        (element, {prefix, name}) => {
          const aria = (element.getAttribute('aria-label') ?? '')
            .replace(/\s+/g, ' ')
            .trim();
          const text = (element.textContent ?? '').replace(/\s+/g, ' ').trim();
          return (
            aria.startsWith(prefix) || text.startsWith(prefix) || text.startsWith(name)
          );
        },
        {prefix: expectedPrefix, name: roomName},
      );
      if (match) {
        tile = button;
        break;
      }
    }
    if (!tile) continue;
    try {
      await tile.click();
      return;
    } catch (error) {
      if (!String(error).includes('Node is detached') || attempt === 2) {
        throw error;
      }
      await new Promise((resolveWait) => setTimeout(resolveWait, 100));
    }
  }
  throw new Error(`room tile not found: ${roomName}`);
}

async function waitForText(page, text, timeout = 30_000) {
  await page.waitForFunction(semanticSurfaceMatches, {timeout}, {texts: [text]});
}

function matrixRequestSummary(requestOrResponse, phase) {
  const request = phase === 'response' ? requestOrResponse.request() : requestOrResponse;
  const url = new URL(request.url());
  if (!url.pathname.startsWith('/_matrix/')) return null;
  return {
    at: new Date().toISOString(),
    phase,
    method: request.method(),
    path: url.pathname,
    ...(phase === 'response' ? {status: requestOrResponse.status()} : {}),
  };
}

async function dumpSendDiagnostics(page, matrixTraffic, label) {
  const semantics = await page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics')]
      .map((element) => ({
        label: element.getAttribute('aria-label'),
        role: element.getAttribute('role'),
        text: element.textContent.replace(/\s+/g, ' ').trim(),
      }))
      .filter((entry) => entry.label || entry.text)
      .slice(-80),
  );
  console.error(
    `[full-app:${label}] send diagnostics\n${JSON.stringify(
      {matrixTraffic: matrixTraffic.slice(-40), semantics},
      null,
      2,
    )}`,
  );
}

async function assertSessionStoragePolicy(page, {expectSession}) {
  const storage = await page.evaluate(() => ({
    local: Object.entries(localStorage),
    session: Object.entries(sessionStorage),
  }));
  const localText = JSON.stringify(storage.local).toLowerCase();
  assert.doesNotMatch(localText, /access_token|refresh_token/);
  assert.equal(
    storage.local.some(([key]) => key.endsWith('.session')),
    false,
  );
  const sessionEntries = storage.session.filter(([key]) =>
    key.startsWith('manymatrix_session_'),
  );
  assert.equal(sessionEntries.length > 0, expectSession);
  if (expectSession) {
    assert.match(sessionEntries[0][1], /"access_token"/);
  }
}

async function savedAccounts(page) {
  return page.evaluate(() => {
    const raw = localStorage.getItem('flutter.manymatrix.accounts');
    return raw ? JSON.parse(JSON.parse(raw)) : [];
  });
}

async function assertMobileSurface(page) {
  await page.setViewport({width: 390, height: 844});
  await new Promise((resolveWait) => setTimeout(resolveWait, 750));
  await captureStableFrame(page, {
    path: '/tmp/manymatrix-full-app-mobile.png',
    label: 'mobile room list',
    texts: ['Rooms'],
    fields: ['Search rooms'],
    buttons: ['Create room'],
    requiredRegions: ['top'],
    minimumMeaningfulFraction: 0.03,
  });
  const metrics = await page.evaluate(() => ({
    flutterViews: document.querySelectorAll('flutter-view').length,
    glassPanes: document.querySelectorAll('flt-glass-pane').length,
    scrollWidth: document.documentElement.scrollWidth,
  }));
  assert.equal(metrics.flutterViews, 1);
  assert.equal(metrics.glassPanes, 1);
  assert.ok(metrics.scrollWidth <= 390, `mobile content overflowed to ${metrics.scrollWidth}px`);
  await page.setViewport({width: 1280, height: 800});
  await new Promise((resolveWait) => setTimeout(resolveWait, 500));
}

async function assertNoHorizontalOverflow(page, label) {
  const metrics = await page.evaluate(async () => {
    window.scrollTo(999, 0);
    await new Promise((resolveFrame) => requestAnimationFrame(resolveFrame));
    const scrollX = window.scrollX;
    window.scrollTo(0, 0);
    const offenders = [...document.body.querySelectorAll('*')]
      .map((element) => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return {
          tag: element.tagName.toLowerCase(),
          className: String(element.className ?? '').slice(0, 120),
          aria: element.getAttribute('aria-label'),
          left: Math.round(rect.left * 100) / 100,
          right: Math.round(rect.right * 100) / 100,
          top: Math.round(rect.top * 100) / 100,
          bottom: Math.round(rect.bottom * 100) / 100,
          width: Math.round(rect.width * 100) / 100,
          height: Math.round(rect.height * 100) / 100,
          display: style.display,
          position: style.position,
          overflow: `${style.overflowX}/${style.overflowY}`,
          transform: style.transform,
          visibility: style.visibility,
          opacity: style.opacity,
        };
      })
      .filter((entry) => entry.left < -0.5 || entry.right > window.innerWidth + 0.5)
      .slice(0, 80);
    const layoutOffenders = offenders.filter(
      (entry) =>
        entry.position !== 'fixed' &&
        entry.display !== 'none' &&
        entry.visibility === 'visible' &&
        Number.parseFloat(entry.opacity) > 0 &&
        entry.width > 0 &&
        entry.height > 0 &&
        entry.right > 0 &&
        entry.left < window.innerWidth &&
        entry.bottom > 0 &&
        entry.top < window.innerHeight,
    );
    return {
      viewportWidth: window.innerWidth,
      documentWidth: document.documentElement.scrollWidth,
      bodyWidth: document.body.scrollWidth,
      scrollX,
      offenders,
      layoutOffenders,
    };
  });
  if (
    metrics.documentWidth > metrics.viewportWidth ||
    metrics.scrollX > 0 ||
    metrics.layoutOffenders.length > 0
  ) {
    await page.screenshot({
      path: `/tmp/manymatrix-${label.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}-overflow.png`,
    });
  }
  assert.ok(
    metrics.documentWidth <= metrics.viewportWidth,
    `${label} document overflow: ${JSON.stringify(metrics)}`,
  );
  assert.equal(metrics.scrollX, 0, `${label} horizontally scrolled: ${JSON.stringify(metrics)}`);
  assert.deepEqual(
    metrics.layoutOffenders,
    [],
    `${label} has visible layout offenders: ${JSON.stringify(metrics)}`,
  );
}

async function assertMobileConversation(page) {
  await page.setViewport({width: 390, height: 844});
  await new Promise((resolveWait) => setTimeout(resolveWait, 750));
  await waitForText(page, 'Flutter E2E room');
  const composerSelector =
    'input[aria-label="Message"], textarea[aria-label="Message"]';
  if (!(await page.$(composerSelector))) {
    await clickRoomTile(page, 'Flutter E2E room');
  }
  await page.waitForSelector(
    composerSelector,
    {timeout: 15_000},
  );
  await buttonHandle(page, 'Room info');
  await buttonHandle(page, 'Send message');
  await assertNoHorizontalOverflow(page, 'mobile conversation');

  await fillField(page, 'Message', 'sent from the mobile composer');
  await clickButton(page, 'Send message');
  await waitForText(page, 'sent from the mobile composer', 30_000);

  await clickButton(page, 'Room info');
  await buttonHandle(page, 'Back to chat');
  await waitForText(page, 'Members', 30_000);
  await assertNoHorizontalOverflow(page, 'mobile room info');
  await clickButton(page, 'Back to chat');
  await page.waitForSelector(
    'input[aria-label="Message"], textarea[aria-label="Message"]',
    {timeout: 15_000},
  );

  await captureStableFrame(page, {
    path: '/tmp/manymatrix-full-app-mobile-conversation.png',
    label: 'mobile conversation',
    texts: ['Flutter E2E room', 'sent from the mobile composer'],
    fields: ['Message'],
    buttons: ['Room info', 'Send message'],
  });
  await assertNoHorizontalOverflow(page, 'mobile conversation after navigation');

  await clickButton(page, 'Back to rooms');
  await waitForText(page, 'Rooms', 15_000);
  await page.setViewport({width: 1280, height: 800});
  await new Promise((resolveWait) => setTimeout(resolveWait, 500));
}

async function corruptPersistedSession(page) {
  return page.evaluate(() => {
    const entry = Object.entries(sessionStorage).find(([key]) =>
      key.startsWith('manymatrix_session_'),
    );
    if (!entry) throw new Error('persisted Matrix session not found');
    const [key, raw] = entry;
    const session = JSON.parse(raw);
    const replaceTokens = (value) => {
      if (!value || typeof value !== 'object') return;
      for (const [field, child] of Object.entries(value)) {
        if (field === 'access_token' || field === 'refresh_token') {
          value[field] = `invalid-e2e-${field}`;
        } else {
          replaceTokens(child);
        }
      }
    };
    replaceTokens(session);
    sessionStorage.setItem(key, JSON.stringify(session));
  });
}

async function reauthenticate(page, {password, expectedUserId}) {
  await waitForText(page, 'Sign in again', 60_000);
  await page.waitForSelector(
    'input[aria-label="Username"], textarea[aria-label="Username"]',
    {timeout: 15_000},
  );
  await new Promise((resolveWait) => setTimeout(resolveWait, 500));
  await fillField(page, 'Password', password);
  await clickButton(page, 'Sign in again');
  await waitForText(page, 'Rooms', 60_000);
  await waitForText(page, expectedUserId, 60_000);
}

async function signIn(page, {homeserver, username, password}) {
  await fillField(page, 'Homeserver', homeserver);
  await fillField(page, 'Username', username);
  await fillField(page, 'Password', password);
  await clickButton(page, 'Sign in');
  await waitForText(page, username.startsWith('@') ? username : `@${username}:localhost`, 60_000);
}

async function openAccounts(page) {
  await clickButton(page, 'Accounts');
  await waitForText(page, 'Add account');
}

async function signOutActive(page, expectLogin) {
  await openAccounts(page);
  await clickButton(page, 'Sign out');
  await waitForText(page, 'Sign out of this account?');
  await clickButton(page, 'Sign out', {last: true});
  if (expectLogin) {
    await page.waitForSelector(
      'input[aria-label="Homeserver"], textarea[aria-label="Homeserver"]',
      {timeout: 30_000},
    );
  } else {
    await waitForText(page, 'Rooms', 30_000);
  }
}

await new Promise((resolveListen) =>
  server.listen(0, '127.0.0.1', resolveListen),
);
const {port} = server.address();
let actor;
let browser;
try {
  actor = new Actor();
  browser = await puppeteer.launch({
    ...(process.env.CHROME_BIN
      ? {executablePath: process.env.CHROME_BIN}
      : {}),
    headless: true,
    protocolTimeout: 180_000,
    args: ['--no-sandbox'],
  });
  const page = await browser.newPage();
  await page.setViewport({width: 1280, height: 800});
  const pageErrors = [];
  const consoleErrors = [];
  const requestFailures = [];
  const matrixTraffic = [];
  page.on('pageerror', (error) =>
    pageErrors.push(error.stack ?? error.message),
  );
  page.on('console', (message) => {
    const messageText = message.text();
    if (message.type() === 'error') consoleErrors.push(messageText);
    if (messageText.startsWith('[manymatrix-worker]')) {
      console.log(messageText);
    }
  });
  page.on('request', (request) => {
    const summary = matrixRequestSummary(request, 'request');
    if (summary) matrixTraffic.push(summary);
  });
  page.on('response', (response) => {
    const summary = matrixRequestSummary(response, 'response');
    if (summary) matrixTraffic.push(summary);
  });
  page.on('requestfailed', (request) => {
    requestFailures.push({
      url: request.url(),
      error: request.failure()?.errorText ?? 'unknown',
    });
  });

  const info = await actor.ready;
  await page.goto(`http://127.0.0.1:${port}/`, {waitUntil: 'networkidle0'});
  await enableSemantics(page, {minimumNodes: 1});
  await signIn(page, {
    homeserver: info.base_url,
    username: info.ext_localpart,
    password: info.ext_password,
  });
  await assertSessionStoragePolicy(page, {expectSession: true});

  // A fresh Flutter boot must restore both the account metadata/session and
  // the account-specific IndexedDB store without returning to the login page.
  await page.reload({waitUntil: 'domcontentloaded'});
  await enableSemantics(page);
  await waitForText(page, info.ext_user_id, 60_000);
  await assertSessionStoragePolicy(page, {expectSession: true});
  requestFailures.length = 0;
  await assertMobileSurface(page);
  assert.deepEqual(requestFailures, []);

  // Corrupt both bearer tokens, then prove password reauthentication restores
  // the same saved Matrix device instead of creating a replacement device.
  const deviceBeforeReauth = (await savedAccounts(page))[0].deviceId;
  assert.ok(deviceBeforeReauth, 'initial login did not persist a Matrix device id');
  await corruptPersistedSession(page);
  await page.reload({waitUntil: 'domcontentloaded'});
  await enableSemantics(page);
  await reauthenticate(page, {
    username: info.ext_localpart,
    password: info.ext_password,
    expectedUserId: info.ext_user_id,
  });
  assert.equal((await savedAccounts(page))[0].deviceId, deviceBeforeReauth);
  await assertSessionStoragePolicy(page, {expectSession: true});
  requestFailures.length = 0;

  // A separate tab shares non-secret account metadata but not the tab-scoped
  // Matrix session, so closing the original tab ends its local login.
  const freshTab = await browser.newPage();
  await freshTab.setViewport({width: 1280, height: 800});
  await freshTab.goto(`http://127.0.0.1:${port}/`, {
    waitUntil: 'domcontentloaded',
  });
  await enableSemantics(freshTab);
  await waitForText(freshTab, 'active in another browser tab', 30_000);
  await assertSessionStoragePolicy(freshTab, {expectSession: false});
  await clickButton(freshTab, 'Reconnect');
  await waitForText(freshTab, 'active in another browser tab', 30_000);
  await freshTab.close();

  await clickButton(page, 'Create room');
  await fillField(page, 'Room name', 'Flutter E2E room');
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await clickButton(page, 'Create');
    try {
      await page.waitForSelector(
        'input[aria-label="Room name"], textarea[aria-label="Room name"]',
        {hidden: true, timeout: 5_000},
      );
      break;
    } catch (_) {
      if (attempt === 1) throw _;
    }
  }
  await page.waitForSelector(
    'input[aria-label="Room name"], textarea[aria-label="Room name"]',
    {hidden: true, timeout: 30_000},
  );
  await new Promise((resolveWait) => setTimeout(resolveWait, 2_000));
  await page.waitForSelector(
    'input[aria-label="Message"], textarea[aria-label="Message"]',
    {timeout: 30_000},
  );
  await waitForText(page, 'Flutter E2E room', 30_000);
  const preSendMessageBubbles = await page.evaluate(
    () => document.querySelectorAll('[aria-label="Message actions"]').length,
  );
  assert.equal(
    preSendMessageBubbles,
    0,
    'a newly-created room rendered blank timeline message bubbles',
  );
  await captureStableFrame(page, {
    path: '/tmp/manymatrix-full-app-created.png',
    label: 'desktop created room',
    texts: ['Flutter E2E room', 'No messages yet'],
    fields: ['Message'],
    buttons: ['Room info', 'Send message'],
  });
  await fillField(page, 'Message', 'sent through the Flutter UI');
  await clickButton(page, 'Send message');
  const tenSecondDiagnostics = setTimeout(() => {
    void dumpSendDiagnostics(page, matrixTraffic, '10s').catch((error) =>
      console.error(`[full-app:10s] diagnostic failure: ${error}`),
    );
  }, 10_000);
  try {
    await waitForText(page, 'sent through the Flutter UI', 30_000);
  } catch (error) {
    await dumpSendDiagnostics(page, matrixTraffic, '30s');
    throw error;
  } finally {
    clearTimeout(tenSecondDiagnostics);
  }
  await assertMobileConversation(page);

  // Join an actor-owned room so incoming sync, reactions, media download, and
  // leave-room are exercised through the rendered Flutter controls.
  const invitation = await actor.command('create_invite', {
    user_id: info.ext_user_id,
  });
  await clickButton(page, 'Refresh rooms');
  await waitForText(page, 'Actor invitation', 30_000);
  await clickButton(page, 'Join');
  await page.waitForSelector(
    'input[aria-label="Message"], textarea[aria-label="Message"]',
    {timeout: 30_000},
  );
  const incoming = await actor.command('send_text', {
    room_id: invitation.room_id,
    body: 'incoming through Matrix sync',
  });
  console.log(`[full-app] actor sent event ${incoming.event_id}`);
  const incomingDiagnostics = setTimeout(() => {
    void dumpSendDiagnostics(page, matrixTraffic, 'incoming-10s').catch((error) =>
      console.error(`[full-app:incoming-10s] diagnostic failure: ${error}`),
    );
  }, 10_000);
  try {
    await waitForText(page, 'incoming through Matrix sync', 60_000);
  } catch (error) {
    await dumpSendDiagnostics(page, matrixTraffic, 'incoming-60s');
    throw error;
  } finally {
    clearTimeout(incomingDiagnostics);
  }
  const firstThreadReply = await actor.command('thread_reply', {
    room_id: invitation.room_id,
    thread_root_event_id: incoming.event_id,
    body: 'first actor thread reply',
  });
  console.log(`[full-app] actor sent thread reply ${firstThreadReply.event_id}`);
  try {
    await buttonHandleStartingWith(page, 'Open thread, 1 reply');
  } catch (error) {
    const semantics = await page.evaluate(() => ({
      buttons: [...document.querySelectorAll('[role="button"]')].map((element) => ({
        label:
          element.getAttribute('aria-label') ??
          element.parentElement?.getAttribute('aria-label') ??
          '',
        text: (element.textContent ?? '').replace(/\s+/g, ' ').trim(),
      })),
      messages: [...document.querySelectorAll('[aria-label="Message actions"]')].map(
        (element) => (element.textContent ?? '').replace(/\s+/g, ' ').trim(),
      ),
    }));
    console.error(`[full-app:thread] semantics=${JSON.stringify(semantics)}`);
    await dumpSendDiagnostics(page, matrixTraffic, 'thread-reply-60s');
    throw error;
  }
  await clickButtonStartingWith(page, 'Open thread, 1 reply');
  await waitForText(page, 'Thread - 1 reply', 60_000);
  await waitForText(page, 'first actor thread reply', 60_000);
  await clickButton(page, 'Close thread');

  // A second reply after closing the panel must remain unread. The room view's
  // explicit `main` receipt cannot advance the thread-specific receipt.
  const secondThreadReply = await actor.command('thread_reply', {
    room_id: invitation.room_id,
    thread_root_event_id: incoming.event_id,
    body: 'unread actor thread reply',
  });
  console.log(`[full-app] actor sent unread thread reply ${secondThreadReply.event_id}`);
  try {
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll('[role="button"]')].some((element) => {
          const label = [
            element.getAttribute('aria-label') ??
            element.parentElement?.getAttribute('aria-label') ??
            '',
            element.textContent ?? '',
          ]
            .join(' ')
            .replace(/\s+/g, ' ')
            .trim();
          return /^Threads, [1-9][0-9]* unread repl(?:y|ies)$/.test(label);
        }),
      {timeout: 60_000},
    );
  } catch (error) {
    const buttons = await page.evaluate(() =>
      [...document.querySelectorAll('[role="button"]')].map((element) => ({
        label:
          element.getAttribute('aria-label') ??
          element.parentElement?.getAttribute('aria-label') ??
          '',
        text: (element.textContent ?? '').replace(/\s+/g, ' ').trim(),
      })),
    );
    console.error(`[full-app:thread-unread] buttons=${JSON.stringify(buttons)}`);
    await dumpSendDiagnostics(page, matrixTraffic, 'thread-unread-60s');
    throw error;
  }
  const threadsShortcut = await buttonHandleStartingWith(page, 'Threads, ');
  await threadsShortcut.evaluate((element) => element.click());
  await page.waitForSelector(
    'input[aria-label="Search threads"], textarea[aria-label="Search threads"]',
    {timeout: 30_000},
  );
  const indexedThread = await buttonHandleStartingWith(
    page,
    'Open thread in Actor invitation',
  );
  await indexedThread.evaluate((element) => element.click());
  await waitForText(page, 'Thread - 2 replies', 60_000);
  await waitForText(page, 'unread actor thread reply', 60_000);
  await clickButton(page, 'Close thread');

  await actor.command('react', {
    room_id: invitation.room_id,
    event_id: incoming.event_id,
    key: 'verified',
  });
  await waitForText(page, 'verified 1', 60_000);
  await actor.command('send_media', {
    room_id: invitation.room_id,
    filename: 'actor-proof.txt',
    mime_type: 'text/plain',
    body: 'ManyMatrix browser media round trip',
  });
  await waitForText(page, 'actor-proof.txt', 60_000);
  await clickButton(page, 'Download attachment');
  await waitForText(page, 'actor-proof.txt downloaded', 60_000);

  await clickButton(page, 'Room info');
  await waitForText(page, 'Room info', 30_000);
  await clickButton(page, 'Leave room');
  await waitForText(page, 'Leave "Actor invitation"?', 30_000);
  await clickButton(page, 'Leave room', {last: true});
  await waitForText(page, 'Choose a conversation', 30_000);

  await openAccounts(page);
  await clickButton(page, 'Add account');
  await page.waitForSelector(
    'input[aria-label="Homeserver"], textarea[aria-label="Homeserver"]',
    {timeout: 15_000},
  );
  await signIn(page, {
    homeserver: info.base_url,
    username: info.second_localpart,
    password: info.second_password,
  });
  await waitForText(page, info.second_user_id, 30_000);

  const accountIds = (await savedAccounts(page)).map((account) => account.id);

  await openAccounts(page);
  await clickButton(page, `Switch to ${info.ext_user_id}`);
  await waitForText(page, info.ext_user_id, 60_000);

  // Sign out the first account; the second is restored automatically. Then
  // sign out the remaining account and return to a clean login surface.
  await signOutActive(page, false);
  await waitForText(page, info.second_user_id, 60_000);
  await signOutActive(page, true);
  await assertSessionStoragePolicy(page, {expectSession: false});
  if (await page.evaluate(() => typeof indexedDB.databases === 'function')) {
    const databaseNames = await page.evaluate(async () =>
      (await indexedDB.databases()).map((database) => database.name ?? ''),
    );
    for (const accountId of accountIds) {
      assert.equal(
        databaseNames.some((name) => name.includes(accountId)),
        false,
        `IndexedDB state remained for forgotten account ${accountId}`,
      );
    }
  }
  assert.deepEqual(requestFailures, []);
  assert.deepEqual(pageErrors, []);
  assert.deepEqual(consoleErrors, []);
  await browser.close();
  browser = null;
  // Browser-side long polls are bounded to 30 seconds. Wait out any request
  // accepted before logout so embedded Tuwunel can assert a clean shutdown.
  await new Promise((resolveWait) => setTimeout(resolveWait, 31_000));
  await actor.stop();
  actor = null;
  console.log(
    'full Flutter web E2E passed: secure tab session, same-device reauth, tab lock, desktop/mobile render, create/send, incoming sync/threads/media, leave, account switching, logout cleanup',
  );
} finally {
  actor?.kill();
  await browser?.close();
  await new Promise((resolveClose) => server.close(resolveClose));
}
