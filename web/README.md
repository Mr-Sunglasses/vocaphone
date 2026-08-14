# VocaPhone website

The public VocaPhone website is a dependency-free static site.

```sh
cd web
npm run check
npm run dev
```

Then open `http://127.0.0.1:4173/`. The iPhone setup guide is available at
`http://127.0.0.1:4173/iphone/`.

The site uses only local brand assets and system fonts. Android beta links open
the repository's GitHub Releases page, where each release includes the APK and
its verification files.

## Deployment

GitHub Actions deploys `web/` to Pages on every push to `main` that touches
this directory (see `.github/workflows/pages.yml`). Set Pages source to
**GitHub Actions**, then add the custom domain in repo Settings → Pages.

- Site directory: `web`
- Check command: `npm run check`
- Publish directory: `web`
- Canonical URL expected by metadata: `https://vocaphone.vocahq.com/`

Both `/` and `/iphone/` must resolve as HTML routes.

The Android product images are the original 576×1280 screenshots from
[VocaPhone PR #70](https://github.com/VocaHQ/vocaphone/pull/70). The website
frames them with CSS and does not load media from GitHub at runtime.
