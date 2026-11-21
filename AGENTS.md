# Agent notes for Headroom

## Installing / updating the app

When the user asks you to install or update the app after making changes, run:

```sh
./scripts/install.sh
```

Never just copy a build into `/Applications` by hand. The script makes sure that:

1. The app gets a Release build with a fresh build number (`CURRENT_PROJECT_VERSION`), so WidgetKit treats it as
   a new version.
2. The running `Headroom` is quit, and so is the old widget extension process (`HeadroomWidgets.appex`).
3. `/Applications/Headroom.app` is **replaced** with the new build. There must only ever be this one installed copy.
4. The new widget extension is registered with macOS (`pluginkit -a`, `lsregister -f`).
5. `chronod` is restarted, so widgets already placed on the desktop or in Notification Center reload from the new
   build. The user should never have to remove and re-add widgets.
6. The new app is launched.

Afterwards, check that it worked:

- `pgrep -x Headroom`: the app is running.
- `pgrep -lf HeadroomWidgets`: the widget extension runs from `/Applications/Headroom.app`.
- `pluginkit -m -v -i app.headroom.mac.widgets`: exactly one registration, pointing at `/Applications`.

If the script fails, fix the cause. Don't fall back to a debug build in `build/`.

Then commit and push to `origin main` (the remote is https://github.com/Sevi-py/usage-widget).

## Project basics

- Run `xcodegen generate` after adding or removing files. `project.yml` is the source of truth, and
  `Headroom.xcodeproj` is generated from it.
- Debug builds have two diagnostic modes:
  - `Headroom --dump [--history]` prints everything the app fetched as JSON.
  - `Headroom --render <dir>` renders the panel, settings, Dashboard and widgets to PNGs in light and dark mode.
- Don't click around the user's real menu bar to test. Use `--render` or `--dump` instead.
- Never redeem a banked reset while testing.
- Never refresh the CLIs' OAuth tokens yourself. Let the CLI do it; otherwise it gets signed out.
- Claude's usage endpoint is heavily rate limited (per token, and the token is shared with other tools). Don't
  hammer it with test requests.
