import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const siteRoot = fileURLToPath(new URL("..", import.meta.url));
const html = readFileSync(join(siteRoot, "index.html"), "utf8");
const iphoneHtml = readFileSync(join(siteRoot, "iphone/index.html"), "utf8");
const deviceSetupHtml = readFileSync(join(siteRoot, "iphone/device-setup/index.html"), "utf8");
const css = readFileSync(join(siteRoot, "styles.css"), "utf8");
const script = readFileSync(join(siteRoot, "script.js"), "utf8");

function androidInstallBlock(source) {
  const match = source.match(
    /<article class="install-card reveal">[\s\S]*?<h3>Android<\/h3>[\s\S]*?<\/article>/,
  );
  assert.ok(match, "Android install card missing");
  return match[0];
}

test("page has one clear title and a landmark structure", () => {
  assert.match(html, /<title>VocaPhone: voice typing that stays yours<\/title>/);
  assert.equal((html.match(/<h1\b/g) || []).length, 1);
  assert.match(html, /<main id="main-content">/);
  assert.match(html, /<nav[^>]+aria-label="Main navigation"/);
});

test("in-page links have matching section ids", () => {
  const anchors = [...html.matchAll(/href="#([\w-]+)"/g)].map((match) => match[1]);
  for (const anchor of anchors) {
    assert.match(html, new RegExp(`id="${anchor}"`), `Missing #${anchor}`);
  }
});

test("document ids are unique", () => {
  const ids = [...html.matchAll(/\sid="([\w-]+)"/g)].map((match) => match[1]);
  assert.equal(new Set(ids).size, ids.length);
});

test("on-device transcription is the primary product promise", () => {
  assert.match(html, /private speech-to-text, running on your phone/i);
  assert.match(html, /no gateway is required/i);
  assert.match(html, /audio stays on this phone/i);
  assert.match(html, /gateway optional/i);
});

test("VocaGateway is presented as an explicit optional path", () => {
  assert.match(html, /two local paths/i);
  assert.match(html, /Mac, Linux machine, or home server/i);
  assert.match(html, /trusted LAN, an encrypted private\s+network, or HTTPS/i);
  assert.match(html, /href="https:\/\/github\.com\/VocaHQ\/vocagateway"/);
  assert.doesNotMatch(html, /no gateway\. no catch/i);
  assert.doesNotMatch(html, />no gateway needed</i);
});

test("hero presents a global supported-language mix", () => {
  assert.match(html, /27 languages \+ automatic/i);
  assert.match(html, /support depends on model/i);
  assert.match(html, /filtered to what your selected model can\s+actually transcribe/i);
  for (const language of ["English", "Español", "Français", "日本語", "हिन्दी", "العربية"]) {
    assert.match(html, new RegExp(`<b>${language}</b>`));
  }
});

test("all local image assets exist", () => {
  const localImages = [...html.matchAll(/(?:src|href)="(assets\/[^"]+)"/g)].map(
    (match) => match[1],
  );
  for (const asset of localImages) {
    assert.ok(existsSync(join(siteRoot, asset)), `Missing ${asset}`);
  }
});

test("production metadata is complete", () => {
  assert.match(html, /rel="canonical" href="https:\/\/vocaphone\.vocahq\.com\/"/);
  assert.match(html, /property="og:url" content="https:\/\/vocaphone\.vocahq\.com\/"/);
  for (const tag of [
    /property="og:type" content="website"/,
    /property="og:locale" content="en_US"/,
    /property="og:site_name" content="VocaPhone"/,
    /property="og:image" content="https:\/\/vocaphone\.vocahq\.com\/assets\/og-image\.png"/,
    /property="og:image:secure_url"\s+content="https:\/\/vocaphone\.vocahq\.com\/assets\/og-image\.png"/,
    /property="og:image:type" content="image\/png"/,
    /property="og:image:width" content="1200"/,
    /property="og:image:height" content="630"/,
    /property="og:image:alt"\s+content="VocaPhone voice typing that stays yours, on-device first with an optional gateway"/,
    /name="twitter:card" content="summary_large_image"/,
    /name="twitter:title" content="VocaPhone: voice typing that stays yours"/,
    /name="twitter:image" content="https:\/\/vocaphone\.vocahq\.com\/assets\/og-image\.png"/,
    /name="twitter:image:alt"\s+content="VocaPhone voice typing that stays yours, on-device first with an optional gateway"/,
  ]) {
    assert.match(html, tag);
  }

  for (const tag of [
    /property="og:site_name" content="VocaPhone"/,
    /property="og:locale" content="en_US"/,
    /property="og:image" content="https:\/\/vocaphone\.vocahq\.com\/assets\/og-image\.png"/,
    /property="og:image:secure_url"\s+content="https:\/\/vocaphone\.vocahq\.com\/assets\/og-image\.png"/,
    /property="og:image:type" content="image\/png"/,
    /property="og:image:width" content="1200"/,
    /property="og:image:height" content="630"/,
    /property="og:image:alt"\s+content="VocaPhone private voice typing, on-device first with an optional self-hosted gateway"/,
    /name="twitter:title" content="Install VocaPhone on iPhone"/,
    /name="twitter:description"\s+content="Build VocaPhone from source, install the private keyboard, and run speech-to-text on your iPhone\."/,
    /name="twitter:image" content="https:\/\/vocaphone\.vocahq\.com\/assets\/og-image\.png"/,
    /name="twitter:image:alt"\s+content="VocaPhone private voice typing, on-device first with an optional self-hosted gateway"/,
  ]) {
    assert.match(iphoneHtml, tag);
  }

  for (const asset of [
    "assets/og-image.png",
    "assets/social-card.png",
    "assets/apple-touch-icon.png",
    "favicon.ico",
    "robots.txt",
    "sitemap.xml",
    "site.webmanifest",
  ]) {
    assert.ok(existsSync(join(siteRoot, asset)), `Missing ${asset}`);
  }
});

test("real Android product screenshots are present", () => {
  for (const screenshot of [
    "assets/screenshots/android-dictate.jpg",
    "assets/screenshots/android-keyboard.jpg",
    "assets/screenshots/android-models.jpg",
  ]) {
    assert.match(html, new RegExp(screenshot.replaceAll("/", "\\/")));
    assert.ok(existsSync(join(siteRoot, screenshot)), `Missing ${screenshot}`);
  }
  assert.match(html, /real app, real phone/i);
  assert.match(html, /These are unedited VocaPhone screens from Android/i);
});

test("availability and install paths are honest", () => {
  assert.match(html, /Android 13 or newer/);
  assert.match(html, /iOS 17 or newer/);
  assert.match(html, /There is no App Store or TestFlight build today/);
  assert.match(
    html,
    /href="https:\/\/github\.com\/VocaHQ\/vocaphone\/releases\/tag\/v0\.1\.0-beta\.14"/,
  );
  assert.match(html, /v0\.1\.0-beta\.14/);
  assert.match(html, /io\.github\.mrsunglasses\.localflow/);
  assert.match(html, /href="\/iphone\/"/);
  assert.match(html, /SHA256SUMS\.txt/);
  assert.doesNotMatch(html, /href="\/download\/android"/);
  assert.doesNotMatch(html, /releases\/latest/);
  assert.doesNotMatch(html, /href="https:\/\/github\.com\/VocaHQ\/vocaphone\/releases"/);
  assert.doesNotMatch(html, /free forever/i);
  assert.doesNotMatch(html, /available on (the )?App Store/i);
  assert.doesNotMatch(html, /available on TestFlight/i);
  assert.doesNotMatch(html, /available on F-Droid/i);

  const androidCard = androidInstallBlock(html);
  const uninstallAt = androidCard.indexOf("io.github.mrsunglasses.localflow");
  const tagHrefAt = androidCard.indexOf(
    "https://github.com/VocaHQ/vocaphone/releases/tag/v0.1.0-beta.14",
  );
  const checksumAt = androidCard.indexOf("SHA256SUMS.txt");
  assert.ok(uninstallAt !== -1, "uninstall note missing from Android install block");
  assert.ok(tagHrefAt !== -1, "pinned beta.14 URL missing from Android install block");
  assert.ok(checksumAt !== -1, "checksum note missing from Android install block");
  assert.ok(uninstallAt < tagHrefAt, "uninstall line must lead the Android install block");
  assert.ok(tagHrefAt < checksumAt, "pinned beta.14 URL must precede the checksum note");

  assert.match(iphoneHtml, /The gateway is optional/);
  assert.match(iphoneHtml, /No gateway address or token\s+is needed for this mode/);
  assert.match(iphoneHtml, /iOS does not permit[\s\S]*keyboard extensions to access the microphone/);
  assert.match(iphoneHtml, /href="\/iphone\/device-setup\/"/);
  assert.match(
    iphoneHtml,
    /href="https:\/\/github\.com\/VocaHQ\/vocaphone#build-and-test"/,
  );
  assert.match(iphoneHtml, /There is no App Store or\s+TestFlight build yet/);

  assert.ok(existsSync(join(siteRoot, "iphone/device-setup/index.html")));
  assert.match(deviceSetupHtml, /There is no App Store or\s+TestFlight\s+build today/);
  assert.match(deviceSetupHtml, /iOS 17 or newer/);
  assert.match(deviceSetupHtml, /keyboard extensions cannot use the microphone/);
  assert.match(deviceSetupHtml, /companion app\s+records/i);
  assert.match(deviceSetupHtml, /model still runs on the iPhone/);
  assert.match(deviceSetupHtml, /gateway is never required/);
  assert.doesNotMatch(deviceSetupHtml, /available on (the )?App Store/i);
  assert.doesNotMatch(deviceSetupHtml, /available on TestFlight/i);
});

test("decorative product frames do not expose focusable controls", () => {
  const hiddenFrames = [...html.matchAll(/<div class="phone-frame[^>]*aria-hidden="true">([\s\S]*?)<\/div>\s*<p>/g)];
  assert.ok(hiddenFrames.length >= 2);
  for (const frame of hiddenFrames) {
    assert.doesNotMatch(frame[1], /<(?:button|a|input|select|textarea)\b/);
  }
});

test("numbered story headings remain in normal flow", () => {
  assert.match(
    css,
    /\.story-number\s*\{[\s\S]*?position:\s*static;[\s\S]*?margin-bottom:\s*24px;/,
  );
});

test("website source remains hosting-provider agnostic", () => {
  for (const artifact of ["netlify.toml", "deno.lock", "netlify"]) {
    assert.ok(!existsSync(join(siteRoot, artifact)), `Unexpected hosting artifact: ${artifact}`);
  }
});

test("mobile navigation can be dismissed with the keyboard", () => {
  assert.match(script, /event\.key === "Escape"/);
  assert.match(script, /closeNavigation\(\{ returnFocus: true \}\)/);
});

test("the iPhone gateway callout uses a dark-surface button", () => {
  assert.match(
    css,
    /\.guide-callout \.button-secondary\s*\{[\s\S]*?background:\s*#17392d;/,
  );
});

test("visual treatment stays flat", () => {
  const bannedFunction = ["linear-" + "gradient", "radial-" + "gradient", "conic-" + "gradient"];
  for (const token of bannedFunction) {
    assert.ok(!css.includes(token), `Unexpected ${token}`);
  }
});

test("motion has a reduced-motion fallback", () => {
  assert.match(css, /prefers-reduced-motion:\s*reduce/);
  assert.match(script, /setTimeout\([\s\S]*revealNodes[\s\S]*is-visible/);
});
