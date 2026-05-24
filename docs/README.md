# VM4A documentation site

This folder is the source for the VM4A GitHub Pages site (the tutorials).
It's a [just-the-docs](https://just-the-docs.com/) Jekyll site.

## Enable it (one-time, repo settings)

**Settings → Pages → Build and deployment → Source: "Deploy from a branch"**, then
pick **`main`** / **`/docs`**. GitHub builds it with the `github-pages` gem
(which resolves `remote_theme` and the listed plugins). The site publishes at:

```
https://<owner>.github.io/vm4a/
```

If the repo isn't named `vm4a`, update `baseurl` in `_config.yml` to match.

## Structure

```
docs/
├── _config.yml          # Jekyll + just-the-docs config
├── Gemfile              # only needed for local preview
├── index.md             # Home
├── getting-started.md   # Install + first VM
├── troubleshooting.md
└── tutorials/           # progressive, comprehensive tutorials
    ├── index.md         # Tutorials landing (parent)
    └── 01..10-*.md      # one tutorial per major feature area
```

Navigation order is driven by `nav_order` in each page's front matter, and
nesting by `parent:` (just-the-docs convention) — not by folder layout.

## Preview locally

```bash
cd docs
bundle install
bundle exec jekyll serve     # http://127.0.0.1:4000/vm4a/
```

## Editing

Each tutorial is self-contained: goal → prerequisites → steps → "what you
learned" → link to the next one. Keep examples copy-pasteable and prefer
`--output json` where the machine-readable shape matters. These pages
summarize and link to the canonical references at the repo root
(`Usage.md`, `Cookbook.md`).

> Translations: the site is English-first. A Chinese mirror can be added under
> `docs/zh/` with its own `nav` entries when ready.
