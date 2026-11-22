# How Hangtime gets its data

Hangtime has no server and no analytics. It reuses the login of each CLI you already have, asks the provider
for your limits the same way the CLI does, and keeps everything on your Mac.

## Limits and resets

| Provider | Credentials | Limits | Banked resets |
| --- | --- | --- | --- |
| Claude Code | The CLI's own login: Keychain item `Claude Code-credentials` (read with `/usr/bin/security`), falling back to `~/.claude/.credentials.json` | `GET api.anthropic.com/api/oauth/usage`, the same endpoint as `/usage` | `cedar_ember` grants → `POST /api/organizations/{org}/reset_rate_limits`, plus the weekly "reset 5-hour limit" allowance |
| Codex | Handled by the CLI | `codex app-server` → `account/rateLimits/read` (JSON-RPC) | `account/rateLimitResetCredit/consume` |
| Grok | `~/.grok/auth.json` | `GET cli-chat-proxy.grok.com/v1/billing?format=credits` | — |
| Antigravity (`agy`) | The CLI's login: Keychain item `gemini` / `antigravity` (read with `/usr/bin/security`) | `POST daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` (per-model `quotaInfo`) | — |

Redeeming a banked reset always asks for confirmation first.

## Usage history

The Dashboard, the panel chart and the chart/heatmap widgets show daily cost and tokens. Hangtime gets them from:

1. **T3 Code**, when it's installed and running: its usage service covers every provider and prices usage with
   LiteLLM rates. Hangtime uses a read-only T3 session that you can connect, renew or revoke in
   Settings → History.
2. **The CLIs' session logs** otherwise, parsed incrementally: `~/.claude/projects`, `~/.codex/sessions` and
   `~/.grok/sessions`. Costs use [LiteLLM's price list](https://github.com/BerriAI/litellm).

Costs are API-equivalent estimates, not what your subscription charges.

## Staying compatible with the CLIs

- **Hangtime never refreshes OAuth tokens itself.** The CLIs rotate their refresh tokens, so refreshing them
  elsewhere would sign the CLI out. When a token is stale, Hangtime asks the CLI to do something authenticated,
  and the CLI refreshes its own token.
- **Codex is queried through its own JSON-RPC protocol** (`codex app-server`), not a private HTTP API.
- **Payloads are parsed leniently.** New or unknown limit types still show up, with a readable title, and plans
  without a session window just work.
- **Claude's usage endpoint is heavily rate limited** (per token, and the token is shared with Claude Code and
  other tools). Hangtime honors `Retry-After` across launches, polls at most every 2.5 minutes, and otherwise
  shows the freshest of its own cache and Claude Code's `cachedUsageUtilization`.

## Finding the CLIs

Only installed CLIs are shown. Each one is looked up through your login shell's `PATH` plus the usual install
locations (Homebrew, npm, pnpm, …). You can set a custom command per provider in Settings → Providers, for
example a full path, an alias or a wrapper like `npx -y @openai/codex`.

## Network access

Besides the provider endpoints above, Hangtime only talks to:

- `api.github.com` / `github.com`, to check for and download updates.
- `raw.githubusercontent.com`, for LiteLLM's model prices.

The widget extension is sandboxed without network access. It reads what the app shares through an app group.
