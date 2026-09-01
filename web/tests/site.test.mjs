import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const siteRoot = fileURLToPath(new URL("..", import.meta.url));
const html = readFileSync(join(siteRoot, "index.html"), "utf8");
const iphoneHtml = readFileSync(join(siteRoot, "iphone/index.html"), "utf8");
const deviceSetupHtml = readFileSync(join(siteRoot, "iphone/device-setup/index.html"), "utf8");
const privacyHtml = readFileSync(join(siteRoot, "privacy/index.html"), "utf8");
const sitemap = readFileSync(join(siteRoot, "sitemap.xml"), "utf8");
const css = readFileSync(join(siteRoot, "styles.css"), "utf8");
const script = readFileSync(join(siteRoot, "script.js"), "utf8");

function heroActions(source) {
  const match = source.match(/<div class="hero-actions">[\s\S]*?<\/div>/);
  assert.ok(match, "hero actions missing");
  return match[0];
}

function pngDimensions(buffer) {
  assert.equal(buffer.toString("ascii", 1, 4), "PNG", "asset must be a PNG");
  return {
    width: buffer.readUInt32BE(16),
    height: buffer.readUInt32BE(20),
  };
}

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
  assert.match(html, /two paths/i);
  assert.doesNotMatch(html, /two local paths/i);
  assert.match(html, /Mac, Linux machine, or home server/i);
  assert.match(html, /trusted LAN, an encrypted private\s+network, or HTTPS/i);
  assert.match(html, /href="https:\/\/vocagateway\.vocahq\.com"/);
  assert.match(html, /href="https:\/\/github\.com\/VocaHQ\/vocagateway"/);
  assert.doesNotMatch(html, /no gateway\. no catch/i);
  assert.doesNotMatch(html, />no gateway needed</i);
});

test("hero presents a global supported-language mix", () => {
  assert.match(html, /54 languages \+ automatic/i);
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
    /property="og:image:alt"\s+content="VocaPhone on Android and iPhone. Voice typing that stays yours, on-device first with an optional gateway"/,
    /name="twitter:card" content="summary_large_image"/,
    /name="twitter:title" content="VocaPhone: voice typing that stays yours"/,
    /name="twitter:image" content="https:\/\/vocaphone\.vocahq\.com\/assets\/og-image\.png"/,
    /name="twitter:image:alt"\s+content="VocaPhone on Android and iPhone. Voice typing that stays yours, on-device first with an optional gateway"/,
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
    /property="og:image:alt"\s+content="VocaPhone on Android and iPhone, on-device first with an optional self-hosted gateway"/,
    /property="og:description"\s+content="Join the public TestFlight, or build from source, then install the keyboard and run speech-to-text on your iPhone\."/,
    /name="twitter:title" content="Install VocaPhone on iPhone"/,
    /name="twitter:description"\s+content="Join the public TestFlight, or build from source, then install the private keyboard and run speech-to-text on your iPhone\."/,
    /name="twitter:image" content="https:\/\/vocaphone\.vocahq\.com\/assets\/og-image\.png"/,
    /name="twitter:image:alt"\s+content="VocaPhone on Android and iPhone, on-device first with an optional self-hosted gateway"/,
  ]) {
    assert.match(iphoneHtml, tag);
  }

  for (const asset of [
    "assets/og-image.png",
    "assets/social-card.png",
    "assets/og/src/og-default.html",
    "assets/og/src/preview.html",
    "assets/apple-touch-icon.png",
    "favicon.ico",
    "robots.txt",
    "sitemap.xml",
    "site.webmanifest",
  ]) {
    assert.ok(existsSync(join(siteRoot, asset)), `Missing ${asset}`);
  }

  const ogImage = readFileSync(join(siteRoot, "assets/og-image.png"));
  const socialCard = readFileSync(join(siteRoot, "assets/social-card.png"));
  assert.deepEqual(pngDimensions(ogImage), { width: 1200, height: 630 });
  assert.deepEqual(pngDimensions(socialCard), { width: 1200, height: 630 });
});

test("Open Graph card follows the Voca paper language", () => {
  const ogSource = readFileSync(join(siteRoot, "assets/og/src/og-default.html"), "utf8");
  assert.match(ogSource, /--paper:\s*#f4f1e8/);
  assert.match(ogSource, /--ink:\s*#14231c/);
  assert.match(ogSource, /--brand:\s*#0f6b57/);
  assert.match(ogSource, /class="device iphone"/);
  assert.match(ogSource, /class="device android"/);
  assert.match(ogSource, /class="island"/);
  assert.match(ogSource, /iMessage/);
  assert.match(ogSource, /WhatsApp/);
  assert.match(ogSource, /class="hole"/);
  assert.match(ogSource, /class="thread"/);
  assert.match(ogSource, /still on for 7\?/);
  assert.match(ogSource, /running 5 late/);
  assert.match(ogSource, /want the usual\?/);
  assert.match(ogSource, /the usual\. thanks/);
  assert.match(ogSource, /class="kb-ios"/);
  assert.match(ogSource, /class="kb-android"/);
  assert.match(ogSource, /class="plat"/);
  assert.match(ogSource, /gateway optional/);
  assert.doesNotMatch(ogSource, /android-keyboard\.jpg/);
  assert.doesNotMatch(ogSource, /class="badge"/);
  assert.doesNotMatch(ogSource, /class="m3-nav"/);
  assert.doesNotMatch(ogSource, /iPhone source/i);
  const bannedFunction = ["linear-" + "gradient", "radial-" + "gradient", "conic-" + "gradient"];
  for (const token of bannedFunction) {
    assert.ok(!ogSource.includes(token), `Unexpected ${token} in OG source`);
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
  // iOS is on a public TestFlight track, so the old "no TestFlight build"
  // line went with it. What still has to be true is that the link is real and
  // that the App Store, which VocaPhone is not on, is not implied.
  assert.match(html, /href="https:\/\/testflight\.apple\.com\/join\/wd85wQ3W"/);
  assert.match(html, /There is\s+no App Store release yet/);
  assert.match(
    html,
    /href="https:\/\/github\.com\/VocaHQ\/vocaphone\/releases\/tag\/android\/v0\.1\.6"/,
  );
  assert.match(html, /v0\.1\.6/);
  assert.match(html, /io\.github\.mrsunglasses\.localflow/);
  assert.match(html, /href="\/iphone\/"/);
  assert.match(html, /SHA256SUMS\.txt/);
  assert.doesNotMatch(html, /href="\/download\/android"/);
  assert.doesNotMatch(html, /releases\/latest/);
  assert.doesNotMatch(html, /href="https:\/\/github\.com\/VocaHQ\/vocaphone\/releases"/);
  assert.doesNotMatch(html, /free forever/i);
  assert.doesNotMatch(html, /available on (the )?App Store/i);
  assert.doesNotMatch(html, /available on F-Droid/i);

  // Both ways to install are offered before the fold, not just the Android
  // one. The hero is where most visitors decide, so an iPhone owner reaching
  // "see how it works" without ever being shown TestFlight is the bug.
  const hero = heroActions(html);
  assert.match(
    hero,
    /href="https:\/\/testflight\.apple\.com\/join\/wd85wQ3W"/,
    "hero is missing the TestFlight link",
  );
  // The Apple mark is filled, not stroked like the Android one beside it, and
  // .button svg sets stroke by default, so it needs the class to render solid.
  assert.match(hero, /<svg class="mark-solid"/);
  assert.match(hero, /<use href="#mark-android"/);
  assert.match(hero, /<use href="#mark-apple"/);
  assert.ok(
    hero.includes("https://github.com/VocaHQ/vocaphone/releases/tag/android/v0.1.6"),
    "hero is missing the Android release link",
  );

  const androidCard = androidInstallBlock(html);
  const uninstallAt = androidCard.indexOf("io.github.mrsunglasses.localflow");
  const tagHrefAt = androidCard.indexOf(
    "https://github.com/VocaHQ/vocaphone/releases/tag/android/v0.1.6",
  );
  const checksumAt = androidCard.indexOf("SHA256SUMS.txt");
  assert.ok(uninstallAt !== -1, "uninstall note missing from Android install block");
  assert.ok(tagHrefAt !== -1, "pinned release URL missing from Android install block");
  assert.ok(checksumAt !== -1, "checksum note missing from Android install block");
  assert.ok(uninstallAt < tagHrefAt, "uninstall line must lead the Android install block");
  assert.ok(tagHrefAt < checksumAt, "pinned release URL must precede the checksum note");

  assert.match(iphoneHtml, /The gateway is optional/);
  assert.match(iphoneHtml, /No gateway address or token\s+is needed for this mode/);
  assert.match(iphoneHtml, /iOS does not permit[\s\S]*keyboard extensions to access the microphone/);
  assert.match(iphoneHtml, /href="\/iphone\/device-setup\/"/);
  assert.match(
    iphoneHtml,
    /href="https:\/\/github\.com\/VocaHQ\/vocaphone#build-and-test"/,
  );
  assert.match(iphoneHtml, /iPhone · public TestFlight/);
  assert.doesNotMatch(iphoneHtml, /iPhone · build from source/);
  assert.match(iphoneHtml, /href="https:\/\/testflight\.apple\.com\/join\/wd85wQ3W"/);
  assert.match(iphoneHtml, /There is no App Store release yet/);
  // The guide is the path that always works, so it must keep saying why it is
  // still here now that a one-tap install exists next to it.
  assert.match(iphoneHtml, /expires after\s+90 days/);

  assert.ok(existsSync(join(siteRoot, "iphone/device-setup/index.html")));
  assert.match(deviceSetupHtml, /href="https:\/\/testflight\.apple\.com\/join\/wd85wQ3W"/);
  assert.match(deviceSetupHtml, /iOS 17 or newer/);
  assert.match(deviceSetupHtml, /keyboard extensions cannot use the microphone/);
  assert.match(deviceSetupHtml, /companion app\s+records/i);
  assert.match(deviceSetupHtml, /model still runs on the iPhone/);
  assert.match(deviceSetupHtml, /gateway is never required/);
  assert.doesNotMatch(deviceSetupHtml, /available on (the )?App Store/i);
});

test("every platform mark points at a symbol that exists", () => {
  // A <use> naming an id that is not there renders nothing at all and reports
  // no error, so a typo would be invisible until someone looked at the page.
  const defined = [...html.matchAll(/<symbol id="([^"]+)"/g)].map(m => m[1]);
  assert.ok(defined.includes("mark-android"), "android symbol missing");
  assert.ok(defined.includes("mark-apple"), "apple symbol missing");

  const used = [...html.matchAll(/<use href="#([^"]+)"/g)].map(m => m[1]);
  assert.ok(used.length >= 8, `expected the marks to be used, saw ${used.length}`);
  for (const id of new Set(used)) {
    assert.ok(defined.includes(id), `<use href="#${id}"> has no matching symbol`);
  }

  // The sprite must not be display:none, which stops <use> resolving in some
  // engines; it is taken out of the flow by size instead.
  assert.match(html, /<svg class="mark-sprite"/);
  assert.doesNotMatch(css, /\.mark-sprite\s*\{[^}]*display:\s*none/);
});

test("decorative Notes mockup stays out of the heading outline", () => {
  const notesMock = html.match(
    /<div class="note-page">[\s\S]*?<\/div>\s*<\/div>\s*<div class="speech-chip">/,
  );
  assert.ok(notesMock, "Notes mockup missing");
  assert.match(notesMock[0], /<p class="note-title">Tomorrow<\/p>/);
  assert.doesNotMatch(notesMock[0], /<h[1-6]\b/);
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

test("display headings clear the fixed menu bar", () => {
  assert.match(css, /--menu-bar-height:\s*58px;/);
  assert.match(
    css,
    /html\s*\{[\s\S]*?scroll-padding-top:\s*calc\(var\(--menu-bar-height\) \+ 18px\);/,
  );
  assert.match(
    css,
    /\.download-copy h2,[\s\S]*?\.guide-hero h1,[\s\S]*?\{[\s\S]*?padding-top:\s*calc\(var\(--menu-bar-height\) \+ 18px\);[\s\S]*?scroll-margin-top:\s*calc\(var\(--menu-bar-height\) \+ 18px\);/,
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

test("hosted privacy page covers the Play listing facts", () => {
  assert.ok(existsSync(join(siteRoot, "privacy/index.html")));
  assert.equal((privacyHtml.match(/<h1\b/g) || []).length, 1);
  assert.match(
    privacyHtml,
    /rel="canonical" href="https:\/\/vocaphone\.vocahq\.com\/privacy\/"/,
  );
  assert.match(html, /href="\/privacy\/"/);
  assert.doesNotMatch(html, /docs\/privacy\.md/);
  assert.match(sitemap, /<loc>https:\/\/vocaphone\.vocahq\.com\/privacy\/<\/loc>/);

  assert.match(privacyHtml, /no Voca account/i);
  assert.match(privacyHtml, /no analytics SDK/i);
  assert.match(privacyHtml, /on-device is the default/i);
  assert.match(
    privacyHtml,
    /Audio leaves the phone only if you deliberately set a gateway you\s+control/,
  );
  assert.match(privacyHtml, /off until you turn it on|off by default/i);
  assert.match(privacyHtml, /opt in|optional usage reporting/i);
  assert.match(privacyHtml, /telemetry\.vocahq\.com/);
  assert.match(privacyHtml, /self-hosted/);
  assert.match(privacyHtml, /Never sent:[\s\S]*transcripts[\s\S]*audio/i);
  assert.match(privacyHtml, /F-Droid[\s\S]{0,80}compil/i);
  assert.match(privacyHtml, /AGPL-3\.0/);
  assert.match(privacyHtml, /hello@vocahq\.com/);
});
