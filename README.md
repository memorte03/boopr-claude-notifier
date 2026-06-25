<h1 align="center">Boopr</h1>

<p align="center"><b>Desktop notifications for Claude Code.</b></p>

<p align="center">
  <img src="docs/hero.png" width="560"
       alt="Boopr showing a Claude Code permission prompt with a diff, an Approve/Deny choice, and a jump-to-session button">
</p>

Boopr is a native macOS menu-bar app that pops a notification when
[Claude Code](https://claude.com/claude-code) **finishes**, **needs your input**,
or **asks for permission** — on whatever Space you're currently on. Approve or
deny right there, see the diff, and jump straight to the session.

> [!IMPORTANT]
> **Boopr is a work in progress.** It's vibecoded on weekends, so issues and PRs
> may get sporadic attention — I'll gradually polish the code quality by hand as
> the project matures. 🙂

## Features

- 🔔 **On-screen alerts** the moment Claude Code finishes, waits, or asks permission — wherever you are.
- ✅ **Approve / Deny inline**, with a diff preview for file edits — no window switching.
- 🎯 **Jump to session** — one click focuses the exact terminal window and tmux pane.
- 📌 **Missed-action pills** — notifications you don't catch wait at the top of the screen until you deal with them.
- 🖼️ **Per-project icons** — give each project its own logo so you know what fired at a glance.
- 🔊 **Subtle chimes** per event kind, all toggleable.

## Installation

### Requirements

- macOS 14 (Sonoma) or newer
- [Claude Code](https://claude.com/claude-code)
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq`
- *Optional, for the best jump-to-session:* tmux + [Ghostty](https://ghostty.org) 1.3+

### Download the `.dmg` (recommended)

1. Grab the latest `Boopr-*.dmg` from the
   [**Releases**](https://github.com/memorte03/boopr-claude-notifier/releases/latest) page.
2. Open it and drag **Boopr** into your Applications folder.
3. Launch Boopr. On first run it installs its Claude Code hooks for you.

The build is Developer-ID-signed and Apple-notarized, so it opens with no
Gatekeeper warning. Grant **Accessibility** and **Automation** when prompted —
they're needed for jump-to-session.

### Build from source

```sh
git clone https://github.com/memorte03/boopr-claude-notifier
cd boopr-claude-notifier
scripts/install.sh
```

This builds Boopr, installs it into `/Applications`, and wires its Claude
Code hooks for you — same first-launch permission prompts as above.

Uninstall any time with `scripts/uninstall.sh`.

## Usage

Just keep working in Claude Code. When it finishes, waits, or asks permission, a
card slides in on your current Space:

- **Approve / Deny** permission prompts right from the card (edits show a diff).
- Click the **↗ jump** button to focus that terminal session.
- Missed it? It becomes a **pill** at the top of the screen — click to jump, **✕** to dismiss. Pills also clear themselves once you visit the session.

Everything is configurable from the menu-bar bell → **Settings**: which events
notify you, chime volume, and per-project icons.

## Development

Built with **Swift 6** (macOS 14+), SwiftUI + AppKit + AVFoundation + Network —
no third-party dependencies.

```sh
swift build && .build/debug/Boopr   # build & run from the repo
scripts/install.sh                       # build + install into /Applications
scripts/make-dmg.sh                      # build the drag-to-install .dmg
```

The app lives in `Sources/Boopr/`, the Claude Code hook scripts in `hooks/`,
and packaging/signing helpers in `scripts/`.

## Contributing

Issues and pull requests are welcome — bug reports, feature ideas, and
terminal/Ghostty compatibility notes especially. Please open an issue to discuss
anything substantial before a large PR.

## License

[MIT](LICENSE) © memorte03
