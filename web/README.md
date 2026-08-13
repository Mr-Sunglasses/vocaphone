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
its verification files. No hosting provider configuration is committed here.

## Deployment handoff

- Site directory: `web`
- Build command: `npm run check`
- Publish directory: `web`
- Canonical URL expected by metadata: `https://vocaphone.vocahq.com/`

The deployment owner should configure HTTPS, redirects/pretty URLs, caching,
security headers, and the production domain in the selected hosting platform.
Both `/` and `/iphone/` must resolve as HTML routes.

The Android product images are the original 576×1280 screenshots from
[VocaPhone PR #70](https://github.com/VocaHQ/vocaphone/pull/70). The website
frames them with CSS and does not load media from GitHub at runtime.
