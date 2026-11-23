# TEMPLATE: the Homebrew cask, as scripts/bump-tap.sh writes it to optionull/homebrew-tap on every release, with the
# version and the zip's sha256 filled in. Change it here, not in the tap. (bump-tap.sh replaces this header.)
cask "trim" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/optionull/trim/releases/download/v#{version}/Trim-arm64.zip"
  name "Trim"
  desc "A trimmed IDE around Neovim, and Shim, a lightweight native Neovim for single files"
  homepage "https://trim.optionull.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia
  # Always the latest nvim, from Homebrew. The apps also carry one as a fallback for installs that are not through brew.
  depends_on formula: "neovim"

  app "Trim.app"
  app "Shim.app"

  uninstall quit: [
    "io.github.mpdreamz.trim",
    "io.github.mpdreamz.shim",
  ]

  zap trash: [
    "~/Library/Application Support/trim",
    "~/Library/Caches/io.github.mpdreamz.trim",
    "~/Library/Caches/trim",
    "~/Library/Preferences/io.github.mpdreamz.trim.plist",
    "~/Library/Preferences/io.github.mpdreamz.shim.plist",
    "~/.config/trim",
    "~/.local/share/trim",
    "~/.local/state/trim",
  ]
end
