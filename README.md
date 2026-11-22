# Headroom

A native macOS menu bar app that shows how much of your AI coding subscriptions you have **left**, for
**Claude Code**, **OpenAI Codex**, **xAI Grok CLI** and **Google Antigravity CLI** (`agy`). It also has desktop widgets, Control Center controls,
banked-reset management and usage history charts.

## Install

Requires macOS 26 (Tahoe) or later.

**Homebrew**

```sh
brew tap sevi-py/headroom https://github.com/Sevi-py/usage-widget
brew install --cask sevi-py/headroom/headroom
```

**Direct download**: get `Headroom-<version>.dmg` (or `.zip`) from
[Releases](https://github.com/Sevi-py/usage-widget/releases/latest) and move Headroom to Applications.
Builds are signed with Developer ID and notarized by Apple.

**Updates**: Headroom checks GitHub Releases every few hours. It installs updates the same way it was installed:
`brew upgrade` for Homebrew installs, otherwise it downloads the release, verifies its signature and notarization,
and replaces itself. Settings, the setup state and placed widgets are kept. Turn off automatic checks or installs
in Settings → General → Updates.

## Features

- **Menu bar status item**: what's left, per provider or just the most constrained limit, shown as text or mini
  rings. Click it for a panel (no window) with every limit, banked resets, sign-in and history, plus menu-style
  options: Refresh, Dashboard, Open at Login (on by default), Settings, About and Quit.
- **Dashboard window**: large chart, a year-long heatmap (color selectable) and a per-model cost/token breakdown.
- **Every limit the CLI reports**:
  - Claude: session (5h), weekly, and per-model weekly limits such as **Fable**.
  - Codex: session/weekly windows plus any per-model buckets.
  - Grok: the plan's credit window.
  - Antigravity: the weekly Gemini quota, plus the shared Claude & GPT model quota.
  - Limits are discovered dynamically, so plans without a session window (or with new limits) just work.
- **Even-pace marker**: a tick on every bar or ring shows how much would be left if you spread your usage evenly
  over the window. Halfway through the week, the tick sits in the middle.
- **Banked resets**: lists available resets with their expiry and lets you redeem them (with confirmation).
  - Claude: `cedar_ember` grants (what `/limit-reset` uses) and the weekly "reset 5-hour limit" allowance.
  - Codex: reset credits via `codex app-server`.
  - Grok and Antigravity have no banked resets.
- **Notifications**:
  - When a used-up limit resets, either per limit from the panel or always.
  - When a limit drops below a threshold.
  - A day before a banked reset expires.
  - When a CLI gets signed out.
- **Sign in without a terminal**: if a CLI is logged out, the panel shows a warning and a **Sign In…** button that
  runs the CLI's own login flow in your browser.
- **CLI detection**: only installed CLIs are shown. Each CLI is found through your login shell's `PATH` plus the
  usual install locations. The command is customizable per provider (path, alias or wrapper like
  `npx -y @openai/codex`).
- **History**:
  - Daily cost and token charts, and a GitHub-style activity heatmap.
  - Uses **T3 Code**'s usage service when T3 Code is installed and running (all providers, priced with LiteLLM
    rates). Access is a read-only T3 session that you can connect, renew or revoke in Settings → History.
  - Otherwise parses the CLIs' own session logs incrementally (`~/.claude/projects`, `~/.codex/sessions`,
    `~/.grok/sessions`).
- **Widgets** (all configurable via *Edit Widget*): Provider Limits (rings or bars, S/M/L), All Providers (S/M/L),
  Single Limit gauge (S), Usage Chart (S–XL), Activity heatmap (S–XL).
- **Control Center / menu bar control**: shows a provider's remaining limit; tapping it refreshes.

## How data is fetched

| Provider | Credentials | Limits | Resets |
| --- | --- | --- | --- |
| Claude Code | The CLI's own login (Keychain item `Claude Code-credentials`, read via `/usr/bin/security`; falls back to `~/.claude/.credentials.json`) | `GET api.anthropic.com/api/oauth/usage` (same endpoint as `/usage`), generic `limits[]` array | `cedar_ember` grants → `POST /api/organizations/{org}/reset_rate_limits` |
| Codex | Handled by the CLI | `codex app-server` → `account/rateLimits/read` | `account/rateLimitResetCredit/consume` |
| Grok | `~/.grok/auth.json` | `GET cli-chat-proxy.grok.com/v1/billing?format=credits` | n/a |
| Antigravity (`agy`) | The CLI's login (Keychain item `gemini` / `antigravity`, read via `/usr/bin/security`) | `POST daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` (per-model `quotaInfo`) | n/a |

How it stays robust to CLI updates:

- Headroom never refreshes OAuth tokens itself. The CLIs rotate refresh tokens, so doing that would sign them out.
  When a token is stale, Headroom asks the CLI to do something authenticated, and the CLI refreshes the token
  itself.
- Codex is queried through the CLI's own JSON-RPC protocol.
- All payloads are parsed leniently. Unknown limit types still show up, with a readable title.
- Claude's usage endpoint is heavily rate limited. Headroom honors `Retry-After` across launches, polls at most
  every 2.5 minutes, and otherwise shows the freshest of its own cache and Claude Code's
  `cachedUsageUtilization`.

## Building

Requirements: Xcode 26+, macOS 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
./scripts/install.sh   # build, replace /Applications/Headroom.app, reload placed widgets, relaunch
```

Or manually:

```sh
xcodegen generate
xcodebuild -project Headroom.xcodeproj -scheme Headroom -configuration Release -derivedDataPath build -allowProvisioningUpdates build
cp -R build/Build/Products/Release/Headroom.app /Applications/
```

To sign with a different team, change `DEVELOPMENT_TEAM` in `project.yml`. The app group is derived from the
team ID.

Debug builds include diagnostics:

- `Headroom --dump [--history]` prints everything it fetched as JSON.
- `Headroom --render <dir>` renders the panel, settings and widgets to PNGs in light and dark mode.

Provider logos come from [LobeHub Icons](https://github.com/lobehub/lobe-icons) (MIT). The logos are trademarks of
their owners.

## Releasing

```sh
./scripts/release.sh 1.2.0            # dry run: Developer ID sign, notarize, staple, package into dist/1.2.0
./scripts/release.sh 1.2.0 --publish  # also bump project.yml, tag v1.2.0, create the GitHub release, update the cask
```

One-time setup on the release Mac:

- Xcode signed in with an account on team `8XX544GLPH` (Flarely e.U.). Xcode uses the cloud-managed
  Developer ID certificate.
- Notarization credentials in the Keychain:
  `xcrun notarytool store-credentials headroom-notary --apple-id <id> --team-id 8XX544GLPH --password <app-specific>`
- `gh` signed in with push access.

The Homebrew cask lives in [`Casks/headroom.rb`](Casks/headroom.rb), so this repo doubles as the tap. Releases
and the tap only work for others once the repo is public.
