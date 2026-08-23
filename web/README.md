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
download CTAs point at a pinned release tag (`android/v0.1.2`), where the release
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
VocaHQ: warm paper, one green accent, editorial type, and a real Android
keyboard screenshot. Serve the site and open `/assets/og/src/og-default.html`
to proof the source at native size before re-rasterizing the PNG.
