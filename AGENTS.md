# Agent notes for Hangtime

## Installing / updating the app

When the user asks you to install or update the app after making changes, run:

```sh
./scripts/install.sh
```

Never just copy a build into `/Applications` by hand. The script makes sure that:

1. The app gets a Release build with a fresh build number (`CURRENT_PROJECT_VERSION`), so WidgetKit treats it as
   a new version.
2. The running `Hangtime` is quit, and so is the old widget extension process (`HangtimeWidgets.appex`).
3. `/Applications/Hangtime.app` is **replaced** with the new build. There must only ever be this one installed copy.
4. The new widget extension is registered with macOS (`pluginkit -a`, `lsregister -f`).
5. `chronod` is restarted, so widgets already placed on the desktop or in Notification Center reload from the new
   build. The user should never have to remove and re-add widgets.
6. The new app is launched.

Afterwards, check that it worked:

- `pgrep -x Hangtime`: the app is running.
- `pgrep -lf HangtimeWidgets`: the widget extension runs from `/Applications/Hangtime.app`.
- `pluginkit -m -v -i app.hangtime.mac.widgets`: exactly one registration, pointing at `/Applications`.

If the script fails, fix the cause. Don't fall back to a debug build in `build/`.

Then commit and push to `origin main` (the remote is https://github.com/Sevi-py/hangtime).

## Project basics

- Run `xcodegen generate` after adding or removing files. `project.yml` is the source of truth, and
  `Hangtime.xcodeproj` is generated from it.
- Debug builds have two diagnostic modes:
  - `Hangtime --dump [--history]` prints everything the app fetched as JSON.
  - `Hangtime --render <dir>` renders the panel, settings, Dashboard and widgets to PNGs in light and dark mode.
- Don't click around the user's real menu bar to test. Use `--render` or `--dump` instead.
- Never redeem a banked reset while testing.
- Never refresh the CLIs' OAuth tokens yourself. Let the CLI do it; otherwise it gets signed out.
- Claude's usage endpoint is heavily rate limited (per token, and the token is shared with other tools). Don't
  hammer it with test requests.

## Releases

- `./scripts/release.sh <x.y.z>` is a dry run (signed, notarized artifacts in `dist/`); add `--publish` to ship.
  Only publish when the user asks for a release.
- Signing team is `8XX544GLPH` (Flarely e.U.). The app group is team-prefixed, so changing the team changes where
  widget-shared settings live.
- The in-app updater (`App/Support/Updater.swift`) only accepts updates signed by that team and notarized.
- Settings and the setup-assistant flags live in `UserDefaults` for `app.hangtime.mac`; never move them, or updates
  would look like first launches.
- Don't change the bundle IDs (`app.hangtime.mac*`), the app group, Keychain services or cache paths: users would
  lose their settings and placed widgets.
