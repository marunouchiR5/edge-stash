# Homebrew cask. Copy into your tap repo (github.com/<owner>/homebrew-tap/Casks/edgestash.rb);
# Scripts/release.sh keeps version and sha256 up to date.
cask "edgestash" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/marunouchiR5/EdgeStash/releases/download/v#{version}/EdgeStash-#{version}.zip"
  name "EdgeStash"
  desc "Stash an app window at a screen edge and slide it out on hover"
  homepage "https://github.com/marunouchiR5/EdgeStash"

  depends_on macos: ">= :sonoma"

  app "EdgeStash.app"

  uninstall quit: "io.github.marunouchir5.EdgeStash"

  zap trash: "~/Library/Preferences/io.github.marunouchir5.EdgeStash.plist"
end
