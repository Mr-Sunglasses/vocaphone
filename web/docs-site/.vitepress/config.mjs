import { defineConfig } from 'vitepress';
import { withMermaid } from 'vitepress-plugin-mermaid';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const webNodeModules = fileURLToPath(new URL('../../node_modules/', import.meta.url));

export default withMermaid(defineConfig({
  lang: 'en-US',
  title: 'VocaPhone docs',
  description: 'Build, use, deploy, and understand VocaPhone.',
  base: '/docs/',
  srcDir: '../../docs',
  outDir: '../docs',
  cleanUrls: true,
  lastUpdated: true,
  appearance: true,
  mermaid: {
    // Use SVG <text> instead of HTML foreignObject labels. The latter measures
    // correctly in the page but can clip when the SVG is copied into the
    // zoomable viewer. Native SVG labels scale with the diagram in both views.
    flowchart: {
      htmlLabels: false,
    },
  },
  vite: {
    // The Markdown source intentionally stays in the repository-level docs/
    // directory. Point Vue's SSR entry back at web/node_modules because Vite
    // resolves imports relative to that external source directory first.
    resolve: {
      alias: [
        {
          find: 'vue/server-renderer',
          replacement: resolve(webNodeModules, '@vue/server-renderer/dist/server-renderer.esm-bundler.js'),
        },
        {
          find: 'vue',
          replacement: resolve(webNodeModules, 'vue/dist/vue.runtime.esm-bundler.js'),
        },
        {
          // Mermaid imports Day.js as an ES module in the browser. Resolve the
          // package root to its ESM entry so Vite dev does not serve the
          // CommonJS dayjs.min.js file without a default export.
          find: /^dayjs$/,
          replacement: resolve(webNodeModules, 'dayjs/esm/index.js'),
        },
        {
          // Mermaid imports this CommonJS package as a named ESM export. Keep
          // the browser dev build on a small ESM-compatible sanitizer.
          find: /^@braintree\/sanitize-url$/,
          replacement: fileURLToPath(new URL('./sanitize-url.mjs', import.meta.url)),
        },
        {
          // VitePress's browser-side Markdown parser imports debug's CommonJS
          // entry during dev. A no-op ESM facade keeps that optional logger
          // from preventing the documentation app from mounting.
          find: /^debug$/,
          replacement: fileURLToPath(new URL('./debug.mjs', import.meta.url)),
        },
      ],
    },
  },
  themeConfig: {
    logo: 'https://vocaphone.vocahq.com/assets/vocaphone-logo.svg',
    siteTitle: 'vocaphone / docs',
    nav: [
      { text: 'Home', link: '/' },
      { text: 'VocaPhone', link: 'https://vocaphone.vocahq.com/' },
      { text: 'GitHub', link: 'https://github.com/VocaHQ/vocaphone' },
    ],
    sidebar: [
      {
        text: 'Learn',
        items: [
          { text: 'Documentation home', link: '/' },
          { text: 'Get started', link: '/tutorials/getting-started' },
          { text: 'What VocaPhone is', link: '/explanation/product-overview' },
          { text: 'How VocaPhone works', link: '/explanation/architecture' },
          { text: 'Privacy and data handling', link: '/reference/privacy' },
        ],
      },
      {
        text: 'Use and operate',
        items: [
          { text: 'Physical iPhone setup', link: '/how-to/device-setup' },
          { text: 'Deploy a gateway', link: '/how-to/deploy-gateway' },
          { text: 'Connect through Tailscale', link: '/how-to/tailscale' },
          { text: 'Troubleshoot VocaPhone', link: '/how-to/troubleshooting' },
        ],
      },
      {
        text: 'Ship and contribute',
        items: [
          { text: 'Development setup', link: '/how-to/development-setup' },
          { text: 'Release VocaPhone', link: '/how-to/release' },
          { text: 'Ship to TestFlight', link: '/how-to/testflight' },
          { text: 'Ship to Google Play', link: '/how-to/google-play' },
          { text: 'Find a starter contribution', link: '/how-to/contribute' },
        ],
      },
      {
        text: 'Reference',
        collapsed: true,
        items: [
          { text: 'Project decisions', link: '/reference/decisions' },
          { text: 'Dependency maintenance', link: '/reference/dependency-maintenance' },
        ],
      },
    ],
    search: {
      provider: 'local',
    },
    editLink: {
      pattern: 'https://github.com/VocaHQ/vocaphone/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/VocaHQ/vocaphone' },
    ],
    footer: {
      message: 'VocaPhone is open source and on-device first.',
      copyright: 'Copyright © VocaHQ',
    },
  },
}));
