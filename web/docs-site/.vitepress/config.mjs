import { defineConfig } from 'vitepress';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const webNodeModules = fileURLToPath(new URL('../../node_modules/', import.meta.url));

export default defineConfig({
  lang: 'en-US',
  title: 'VocaPhone docs',
  description: 'Build, use, deploy, and understand VocaPhone.',
  base: '/docs/',
  srcDir: '../../docs',
  outDir: '../docs',
  cleanUrls: true,
  lastUpdated: true,
  appearance: true,
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
        text: 'Start here',
        items: [
          { text: 'Documentation home', link: '/' },
          { text: 'Architecture', link: '/architecture' },
          { text: 'Privacy and threat model', link: '/privacy' },
          { text: 'Troubleshooting', link: '/troubleshooting' },
        ],
      },
      {
        text: 'Set up and deploy',
        items: [
          { text: 'Device setup', link: '/device-setup' },
          { text: 'Gateway deployment', link: '/deployment' },
          { text: 'Tailscale', link: '/tailscale' },
        ],
      },
      {
        text: 'Ship and maintain',
        items: [
          { text: 'Releasing', link: '/releasing' },
          { text: 'TestFlight', link: '/testflight' },
          { text: 'Google Play', link: '/play-store' },
          { text: 'Dependency maintenance', link: '/dependency-maintenance' },
          { text: 'Starter contributions', link: '/starter-contributions' },
        ],
      },
      {
        text: 'Project context',
        collapsed: true,
        items: [
          { text: 'Decisions', link: '/decisions' },
          { text: 'iOS plan', link: '/Plan' },
          { text: 'Android plan', link: '/Plan-Android' },
          { text: 'Android keyboard UX plan', link: '/Plan-Android-Keyboard-UX' },
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
});
