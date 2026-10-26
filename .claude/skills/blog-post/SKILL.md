---
name: blog-post
description: Write a new technical blog post for this Jekyll site (joeyfaherty.github.io) in Joey's preferred style, with diagrams, verified facts and cited sources. Use when asked to write, draft or create a blog post or article on a topic.
---

# Write a blog post

Input: a topic, plus optional source material (docs, artifacts, notes) and angle.

## 1. Research first

- Read the official docs for the topic with WebFetch (vendor docs, project docs, protocol specs, release posts). Note the exact claim and its URL for every technical fact.
- Never invent a number, threshold, version or benchmark. If a fact can't be sourced, leave it out or say it is an assumption.
- Leave out scale and sizing figures unless the user asks for them.

## 2. Structure

Default outline (adapt headings to the topic, keep the flow):

1. **Opening, no heading**: 2–3 sentences on what it is and why it matters. No "Introduction", no "This post covers" list.
2. **What you get**: a benefit → "what it means in practice" table, then one short code block showing the core syntax.
3. **How it works underneath**: one `###` subsection per mechanism, numbered. Each one explains *how* a benefit is achieved, with a diagram or a small ASCII illustration.
4. **How the pieces fit**: one diagram tying the mechanisms together.
5. **When something else fits better**: situation → better fit → why table, the hard limits, then a decision flowchart.
6. **Checking it works**: 2–4 concrete verification steps.
7. **Sources**: every URL used, with what it was used for.

Style: short, plain sentences. Bold lead-ins on list items and table rows. Tables over bullet lists. Code in fenced blocks with a language. No emojis, no hype, no "It's not X, it's Y". Separate top-level sections with `---`.

## 3. Diagrams

- Use as many as genuinely explain something: aim for one per mechanism.
- Flowcharts and sequences: Mermaid inside `<pre class="mermaid"> … </pre>` (the layout loads Mermaid 11). Do NOT use ```mermaid fences; kramdown won't render them. Quote node labels containing punctuation, use `<br/>` for line breaks, and avoid a bare `<` in labels.
- Geometry Mermaid can't draw (curves, grids, file layouts): inline `<figure><svg viewBox=…>…</svg><figcaption>…</figcaption></figure>`, `max-width` ≤ 560px, `fill="currentColor"` for text, palette ink #16252b, accent #b8381f, secondary #1f5f8b, grid #c9c2b4.
- ASCII in plain ``` blocks for before/after tables of files or ranges.

## 3b. Hero image (cheat sheet)

Every post opens with a one-page cheat-sheet image in the style of `docs/reference-images/blog_slide.png`, but clean and enterprise-training in tone (no emojis, jokes or decorative clip art).

- Copy `_hero_src/2026-10-26-liquid-clustering.html` to `_hero_src/<post-date>-<slug>.html` and reuse its CSS, palette (cream #fbf6ef, orange #e8742a / #b9531a, peach, violet, mint, rose, butter) and panel components. `_hero_src/` is ignored by Jekyll.
- Panels, numbered: what it is (with a 3–4 step mini diagram and benefit → mechanism links), comparison table vs alternatives, when to use what, one full-width row of mechanism diagrams (one small SVG each), code, cost/operations, key takeaways + common mistakes, and a footer rule of thumb + how to verify.
- Diagrams teach: each one shows the mechanism (before/after, ranges, flow), not decoration. Every fact must also appear in the post.
- Export at 2×, trimming `--window-size` height to the content:
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --force-device-scale-factor=2 --window-size=1600,<height> --virtual-time-budget=5000 --user-data-dir=<scratchpad>/chrome-prof --screenshot=$PWD/assets/images/<post-date>-<slug>-hero.png "file://$PWD/_hero_src/<post-date>-<slug>.html"`
  Render at 1× to the scratchpad first and look at it (Read the PNG) to fix overlaps and empty space.
- Insert under the `# H1`, linked to the full-size file, with a descriptive `alt` that lists what the image covers.

## 4. Write the file

- Path: `_posts/YYYY-MM-DD-Title-In-Kebab-Case.md` with today's date.
- Front matter, then the title again as `# H1` (every post in this repo does this):

```yaml
---
layout: post
title: "Title"
date: YYYY-MM-DD
categories: [topic, data-engineering]
---
```

- Link related posts with `{% post_url YYYY-MM-DD-Slug %}` (the target file must exist or the build fails).

## 5. Verify

1. Diagrams: `.claude/skills/blog-post/check-mermaid.sh <post> <scratchpad>/mmd` builds a test page. Serve that directory over http (a `.claude/launch.json` entry running `python3 -m http.server`), open `test.html` in the browser pane, and wait for `window.done`; every entry in `window.results` must be `ok`. Screenshot any inline SVG. Remove the temporary launch entry afterwards. (`--cli <post>` uses mermaid-cli instead, if npx downloads are allowed.)
2. Re-read the post against your source notes: every number, version and limit must trace to a source.

## 6. Publish

Show the user the post path and a summary. Commit and push only when they ask. The site is GitHub Pages building from `master` of `git@github.com:joeyfaherty/joeyfaherty.github.io.git`; a push to `master` publishes it within a few minutes.
