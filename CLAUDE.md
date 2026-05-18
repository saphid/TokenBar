# TokenBar

Swift macOS menu bar app tracking token usage and spending across AI coding tools.

Status: Mature / Maintenance + Pre-launch

@~/Personal/.claude/skills/ios-dev/SKILL.md

## Repos
| Repo | Branch | Purpose |
|------|--------|---------|
| TokenBar | main | macOS app source |

## Key Info
- Tech: Swift 5.10, SwiftUI, macOS 14+, Keychain
- Tracks: Cursor, Claude Code, OpenAI, GitHub Copilot, Codex, Kilo Code, OpenCode
- Auto-detects installed tools
- GitHub repo: `saphid/TokenBar`

## Key Artifacts
| File | Purpose |
|------|---------|
| planning/LAUNCH_GUIDE.md | Pre-launch checklist, image asset specs, social preview instructions |
| notes/README.md | App description and badge links (HTML README content) |

## Principles
1. State the invariant before you code — the fix shape falls out of it.
2. Look for existing primitives before building new ones.
3. Write the dumbest version that works; require a reason to add any layer.
4. A trivial change shouldn't need a cascade of CI fixes — that's a shape problem, not a CI problem.
5. Match process weight to problem size; don't orchestrate a one-shot fix.
6. Before shipping, ask explicitly: "is there a simpler version?"
