cask "hangtime" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Sevi-py/usage-widget/releases/download/v#{version}/Hangtime-#{version}.zip"
  name "Hangtime"
  desc "Menu bar app and widgets showing what's left of your AI coding subscriptions"
  homepage "https://github.com/Sevi-py/usage-widget"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "Hangtime.app"

  # Make placed widgets load the new extension after an install or `brew upgrade`.
  postflight do
    system_command "/usr/bin/pluginkit",
                   args:         ["-a", "#{appdir}/Hangtime.app/Contents/PlugIns/HangtimeWidgets.appex"],
                   must_succeed: false
    system_command "/usr/bin/killall", args: ["chronod"], must_succeed: false
  end

  # No `uninstall quit:`/`login_item:` on purpose: `brew upgrade` runs them, which would quit Hangtime while it
  # is the one running the upgrade and drop the user's Open at Login choice. Hangtime restarts itself instead.

  zap trash: [
    "~/Library/Application Support/Headroom",
    "~/Library/Caches/app.headroom.mac",
    "~/Library/Containers/app.headroom.mac.widgets",
    "~/Library/Group Containers/8XX544GLPH.app.headroom.shared",
    "~/Library/HTTPStorages/app.headroom.mac",
    "~/Library/Preferences/app.headroom.mac.plist",
  ]
end
