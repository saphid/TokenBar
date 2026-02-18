# TokenBar Launch & Promotion Guide

## Pre-Launch Checklist

- [ ] README with badges, architecture diagram, provider table
- [ ] Screenshots / GIF of the app in action (use Pika or Shots.so for beautification)
- [ ] Social preview image uploaded (1280x640, use Socialify or Canva)
- [ ] LICENSE, CONTRIBUTING.md, issue templates in place
- [ ] GitHub repo description and topics set
- [ ] At least one GitHub Release published

## Image Assets To Create

1. **Social preview** (1280x640px): Use https://socialify.git.ci for quick auto-generation, or Canva for custom design
2. **README hero banner**: Use Canva (1200x400) -- dark gradient with app name and tagline
3. **App screenshot**: Take a screenshot of the menu bar popover, then beautify with https://pika.style (add macOS device frame + gradient background)
4. **Badges**: Already in README via shields.io

### Light/Dark Mode Banner

Use HTML `<picture>` tags (already in README template):
```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/tokenbar-banner-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/tokenbar-banner-light.png">
  <img alt="TokenBar" src="docs/assets/tokenbar-banner-light.png" width="600">
</picture>
```

Create both variants in Canva or Figma and save to `docs/assets/`.

## Launch Sequence

### Week -2: Build Anticipation
- Start posting #buildinpublic updates on X/Twitter
- Engage in target subreddits (comment, help others, don't just lurk)

### Week -1: Prepare Assets
- Polish all screenshots, GIF, taglines
- Set up Product Hunt "Coming Soon" page
- Optionally reach out to a PH Hunter
- Draft all Reddit/HN posts

### Day 1 (Sunday): Hacker News
- **Show HN: TokenBar -- Open-source macOS menu bar app for tracking AI token usage**
- Link directly to GitHub repo (HN prefers this over marketing sites)
- Post a detailed first comment explaining what you built, why, and the tech approach
- Use modest, precise language -- no superlatives
- Best time: ~12 PM Pacific

### Day 2 (Monday): Reddit Wave 1
- Post to **r/macOS** first (learn from feedback)
- Publish technical blog on **Dev.to**: "How I Built a macOS Menu Bar App to Track AI Token Usage"
- Cross-post to Lemmy (!opensource, !programming)

### Day 3 (Tuesday): Product Hunt + Reddit Wave 2
- **Product Hunt launch** (goes live 12:01 AM PT)
  - Tagline (60 chars, starts with verb): "Track AI token usage across all your coding tools"
  - Post first comment immediately, reply to every comment
  - Share across all social channels throughout the day
- Post to **r/macapps**

### Day 4 (Wednesday): AI Communities
- Post to **r/ClaudeAI**, **r/cursor**, **r/SideProject**
- Share in Discord servers (Cursor Discord, Claude Developers Discord)

### Day 5 (Thursday): Open Source Communities
- Post to **r/opensource**, **r/coolgithubprojects**, **r/LocalLLaMA**
- Submit PR to awesome-open-source-mac-os-apps list

### Day 6+: Long Tail
- Post to **r/ChatGPT**
- Share on **Indie Hackers**
- Submit to newsletters: Console.dev, Changelog, TLDR

## Channel Details

### Reddit (space posts 1-2 days apart)

| Subreddit | Members | Angle |
|-----------|---------|-------|
| r/macOS | ~700K | "I was spending too much on AI tools..." |
| r/macapps | ~208K | Showcase post with screenshot/GIF |
| r/ClaudeAI | ~497K | "Track your Claude Code token usage" |
| r/cursor | Large | "See how many tokens Cursor uses" |
| r/SideProject | ~500K | "I built..." seeking feedback |
| r/opensource | ~210K | Emphasize MIT license, contribution |
| r/coolgithubprojects | ~60K | Link directly to repo |
| r/LocalLLaMA | ~626K | Open-source, local-first angle |
| r/ChatGPT | ~9M | "Track OpenAI spending" |

**Rules**: Follow 90/10 ratio (90% genuine participation, 10% promotion). Respond to every comment. Include visuals. Never cross-post simultaneously.

### Twitter/X

**Hashtags** (use 1-2 per tweet):
- Primary: `#buildinpublic`, `#opensource`, `#devtools`
- Secondary: `#macOS`, `#AI`, `#indiehacker`, `#swiftlang`
- Tool-specific: `#CursorAI`, `#ClaudeCode`, `#GitHubCopilot`

**Format**: Thread works well. Tweet 1 = problem, Tweet 2 = demo/screenshot, Tweet 3 = repo link.

### Discord

| Server | Where to post |
|--------|--------------|
| Cursor Discord | #showcase or #community-projects |
| Claude Developers | #showcase or #projects |
| OpenAI Discord | Developer channels |

Engage in discussions first, then share when relevant. Never DM-spam.

### Hacker News

- Title: `Show HN: TokenBar -- Open-source macOS menu bar app for tracking AI token usage`
- Link: GitHub repo URL
- First comment: Why you built it, tech stack, what's next
- Best days: Weekends (less competition)
- Expected: ~121 GitHub stars in 24h (average for Show HN)

### Product Hunt

- Best days: Tuesday or Wednesday
- Tagline: "Track AI token usage across all your coding tools" (under 60 chars)
- Category: Developer Tools, Open Source
- First comment ready, reply to everything quickly
- Monitor with hunted.space

### Other Channels

- **Dev.to**: Technical blog post with `#opensource #macos #ai #devtools` tags
- **Lobste.rs**: Invitation-only. Keep self-promo < 25% of activity
- **Indie Hackers**: Post in Open Source group
- **Lemmy**: Cross-post Reddit content to !opensource, !programming
- **awesome-open-source-mac-os-apps**: Submit PR to add TokenBar
- **Newsletters**: Console.dev, Changelog, TLDR, Hacker Newsletter
