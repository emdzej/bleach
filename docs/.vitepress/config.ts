import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'bleach',
  description: 'Find and safely reclaim orphaned application state on macOS.',
  lang: 'en-GB',

  // Custom domain (docs/public/CNAME), so the site is served from the root
  // rather than a /repo/ subpath.
  base: '/',
  cleanUrls: true,
  lastUpdated: true,

  head: [
    ['link', { rel: 'icon', href: '/favicon.svg', type: 'image/svg+xml' }],
    ['meta', { name: 'theme-color', content: '#3b7ea1' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'bleach — reclaim orphaned app state on macOS' }],
    ['meta', {
      property: 'og:description',
      content: 'Evidence-based cleanup for ~/Library. Reversible by default, confined to $HOME.',
    }],
    ['meta', { property: 'og:url', content: 'https://bleach.emdzej.pl/' }],
  ],

  themeConfig: {
    siteTitle: 'bleach',

    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'CLI', link: '/guide/cli' },
      { text: 'Plugins', link: '/guide/plugins' },
      {
        text: 'Links',
        items: [
          { text: 'Source on GitHub', link: 'https://github.com/emdzej/bleach' },
          { text: 'Releases', link: 'https://github.com/emdzej/bleach/releases' },
          { text: 'Issues', link: 'https://github.com/emdzej/bleach/issues' },
          { text: 'emdzej.pl', link: 'https://emdzej.pl' },
        ],
      },
    ],

    sidebar: [
      {
        text: 'Getting started',
        items: [
          { text: 'Install & first scan', link: '/guide/getting-started' },
          { text: 'Full Disk Access', link: '/guide/full-disk-access' },
        ],
      },
      {
        text: 'Understanding the output',
        items: [
          { text: 'How it works', link: '/guide/how-it-works' },
          { text: 'Tiers', link: '/guide/tiers' },
          { text: 'Scope & safety', link: '/guide/scope' },
        ],
      },
      {
        text: 'Cleaning up',
        items: [
          { text: 'The TUI', link: '/guide/tui' },
          { text: 'Plans & applying', link: '/guide/plans' },
          { text: 'Disposal modes', link: '/guide/disposal-modes' },
          { text: 'Quarantine & restore', link: '/guide/quarantine' },
        ],
      },
      {
        text: 'Extending',
        items: [
          { text: 'Rules', link: '/guide/rules' },
          { text: 'Writing a plugin', link: '/guide/plugins' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'CLI reference', link: '/guide/cli' },
          { text: 'Limitations', link: '/guide/limitations' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/emdzej/bleach' },
      {
        icon: {
          svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="currentColor" d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm6.93 6h-2.95a15.6 15.6 0 0 0-1.38-3.56A8.03 8.03 0 0 1 18.93 8ZM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96ZM4.26 14a7.98 7.98 0 0 1 0-4h3.38a16.6 16.6 0 0 0 0 4H4.26Zm.81 2h2.95c.32 1.25.78 2.45 1.38 3.56A8.03 8.03 0 0 1 5.07 16Zm2.95-8H5.07a8.03 8.03 0 0 1 4.33-3.56A15.6 15.6 0 0 0 8.02 8ZM12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82a13.6 13.6 0 0 1-1.91 3.96ZM14.34 14H9.66a14.5 14.5 0 0 1 0-4h4.68a14.5 14.5 0 0 1 0 4Zm.26 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95a8.03 8.03 0 0 1-4.33 3.56ZM16.36 14a16.6 16.6 0 0 0 0-4h3.38a7.98 7.98 0 0 1 0 4h-3.38Z"/></svg>',
        },
        link: 'https://emdzej.pl',
        ariaLabel: 'emdzej.pl',
      },
    ],

    editLink: {
      pattern: 'https://github.com/emdzej/bleach/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },

    search: { provider: 'local' },

    footer: {
      message:
        'Released under the MIT License · '
        + '<a href="https://github.com/emdzej/bleach">Source</a> · '
        + '<a href="https://github.com/emdzej/bleach/releases">Releases</a>',
      copyright:
        'Built by <a href="https://emdzej.pl">emdzej.pl</a>',
    },

    outline: { level: [2, 3] },
  },
})
