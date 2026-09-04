# VocaPhone website

The public VocaPhone website is a dependency-free static site.

```sh
cd web
npm run check
npm run dev
```

Then open `http://127.0.0.1:4173/`. The iPhone setup guide is available at
`http://127.0.0.1:4173/iphone/`. The consumer privacy page is at
`http://127.0.0.1:4173/privacy/`.

The site uses only local brand assets and system fonts. The Android install and
download CTAs point at a pinned release tag (`android/v0.1.6`), where the release
includes the APK and its verification files. New Android tags are `android/v*`;
**move the pin when you cut the next Android release people should install**
(see [releasing.md](../docs/releasing.md)). `npm run check` asserts the tag the
install block links to, so a stale pin fails there rather than on the live
site.

They deliberately do not use `/releases/latest`, which the check forbids.
GitHub resolves it to the newest release that is not a prerelease, so while
this project ships prereleases between releases it can land on the releases
index rather than on a page carrying an APK.

## Deployment

GitHub Actions deploys `web/` to Pages on every push to `main` that touches
this directory (see `.github/workflows/pages.yml`). Set Pages source to
**GitHub Actions**, then add the custom domain in repo Settings → Pages.

- Site directory: `web`
- Check command: `npm run check`
- Publish directory: `web`, minus the files that exist for developers rather
  than visitors
- Canonical URL expected by metadata: `https://vocaphone.vocahq.com/`

`.github/actions/stage-site` drops `README.md`, `package.json`, `tests/` and
`.htmlvalidate.json` before the upload; the first three used to be reachable on
the live site. It removes named exceptions rather than listing what to publish,
so a new asset ships by default: a stray file on the site is a better failure
than a 404 on a page someone is reading. `CNAME`, `robots.txt` and `sitemap.xml`
stay — Pages needs the first for the custom domain and crawlers want the others,
so "nothing links to it" does not decide this.

`/`, `/iphone/`, `/iphone/device-setup/`, and `/privacy/` must resolve as HTML
routes.

The Android product images in `assets/screenshots/` are 576×1280 captures
from a physical device running the current Android beta. The website frames
them with CSS and does not load media from GitHub at runtime.

The Open Graph card is `assets/og-image.png` (1200×630), drawn from
`assets/og/src/og-default.html` in the same paper language as VocaMac and
VocaHQ: warm paper, one green accent, editorial type, and iPhone plus Android
mocks with SVG keyboards. Serve the site and open `/assets/og/src/og-default.html`
to proof the source at native size before re-rasterizing the PNG.

## Product screenshots and walkthrough

The hero and explorer explicitly label both Android and iPhone images as real
app screenshots. The iPhone originals are August 2026 beta captures; the page
states that screens may vary by version. PNG source pixels remain unchanged.
The screenshot explorer works without JavaScript by displaying every figure.
With JavaScript it exposes platform and screen selectors plus an accessible
native image dialog (Escape closes it and restores focus).

| Asset | Original capture | Content |
| --- | --- | --- |
| `iphone-keyboard.png` | `IMG_9359.PNG` | Keyboard listening in Notes |
| `iphone-dictate.png` | `IMG_9358.PNG` | App with a finished sample transcript |
| `iphone-models.png` | `IMG_9360.PNG` | On-device transcription settings |
| `iphone-handoff.png` | `IMG_9410.PNG` | App recording and return instructions |
| `iphone-inserted.png` | `IMG_9362.PNG` | Notes with inserted sample text |

`assets/demo/iphone-walkthrough.mp4` is a **screenshot walkthrough**, not a live
screen recording or a latency benchmark. It is 15 seconds, H.264/yuv420p,
1280×720, silent, and encoded with fast start. Playback is user initiated with
`preload="none"`; a local poster, English WebVTT captions, and an HTML text
alternative accompany it. No microphone audio or personal chat recording is
included. The screenshots use demonstration text already present in the
selected captures.

To rebuild: serve the site, open `assets/demo/src/walkthrough.html?step=1`
(and `step=2`, `step=3`) at exactly 1280×720 with device scale factor 1, then
capture PNGs named `slide-0.png` through `slide-2.png` in a temporary directory.
Encode with FFmpeg (replace the input path with that directory):

```sh
ffmpeg -framerate 1/5 -i /tmp/vocaphone-frames/slide-%d.png -t 15 -r 24 \
  -c:v libx264 -preset slow -crf 21 -pix_fmt yuv420p \
  -movflags +faststart -an assets/demo/iphone-walkthrough.mp4
cp /tmp/vocaphone-frames/slide-0.png assets/demo/iphone-walkthrough-poster.png
```

Update the captions and HTML text alternative if the sequence changes. Recheck
all six platform/screen combinations, image dialog focus and dismissal, video
playback, and mobile navigation. Verify the homepage, iPhone guide, device setup,
and privacy routes at desktop and narrow mobile widths before delivery.
