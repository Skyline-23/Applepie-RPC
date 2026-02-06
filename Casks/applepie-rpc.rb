cask "applepie-rpc" do
  version "0.1.13"
  sha256 "dd62d6074f41d67e45db57f79c6c5c612f4b3cbe037dceaf936c6ef847bfe8de"

  url "https://github.com/Skyline-23/Applepie-RPC/releases/download/v#{version}/Applepie-RPC-v#{version}.dmg",
      verified: "github.com/Skyline-23/Applepie-RPC/"
  name "Applepie-RPC"
  desc "macOS menu bar app that publishes now-playing info to Discord Rich Presence"
  homepage "https://github.com/Skyline-23/Applepie-RPC"

  livecheck do
    url "https://github.com/Skyline-23/Applepie-RPC/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  app "Applepie-RPC.app"

  zap trash: [
    "~/Library/Application Support/Applepie-RPC",
    "~/Library/Preferences/com.skyline23.Applepie-RPC.plist",
  ]
end

