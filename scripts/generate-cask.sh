#!/usr/bin/env bash
# Usage: bash scripts/generate-cask.sh VERSION DMG_SHA256 OWNER/REPO [signed|unsigned]
set -euo pipefail

version="${1:?version}"
sha256="${2:?sha256 of the DMG}"
repository="${3:?owner/repo}"
signing="${4:-signed}"

[[ "${version}" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Invalid version" >&2; exit 1; }
[[ "${sha256}" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid SHA-256" >&2; exit 1; }
[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid repository" >&2; exit 1; }
[[ "${signing}" == signed || "${signing}" == unsigned ]] || { echo "Invalid signing mode" >&2; exit 1; }

cat <<CASK
cask "sift" do
  version "${version}"
  sha256 "${sha256}"

  url "https://github.com/${repository}/releases/download/v#{version}/Sift-#{version}.dmg"
  name "Sift"
  desc "Safely reclaim developer storage from your menu bar"
  homepage "https://github.com/${repository}"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Sift.app"
CASK

if [[ "${signing}" == unsigned ]]; then
cat <<'CASK'

  caveats <<~EOS
    Sift isn't notarized by Apple. After trying to open it, approve it in
    System Settings → Privacy & Security → Open Anyway.
  EOS
CASK
fi

cat <<'CASK'

  uninstall quit: "com.dominikbura.sift"

  zap trash: [
    "~/Library/Application Support/com.dominikbura.sift",
    "~/Library/Preferences/com.dominikbura.sift.plist",
  ]
end
CASK
