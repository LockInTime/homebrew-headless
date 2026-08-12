#!/bin/bash
set -euo pipefail

VERSION="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REPOSITORY="LockInTime/headless"
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/headless-cask-update.XXXXXX")"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

curl_release() {
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$1"
}

if [[ -z "$VERSION" ]]; then
  VERSION="$(curl_release "https://api.github.com/repos/$REPOSITORY/releases/latest" | jq -r '.tag_name')"
  VERSION="${VERSION#v}"
fi
if ! printf '%s\n' "$VERSION" | grep -Eq "$SEMVER_PATTERN"; then
  echo "Homebrew update: invalid semantic version: $VERSION" >&2
  exit 64
fi

ASSET="Headless-${VERSION}-macos.zip"
BASE_URL="https://github.com/$REPOSITORY/releases/download/v${VERSION}"
curl_release "$BASE_URL/SHA256SUMS" > "$TEMP_DIRECTORY/SHA256SUMS"
curl_release "$BASE_URL/$ASSET" > "$TEMP_DIRECTORY/$ASSET"

EXPECTED_SHA256="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$TEMP_DIRECTORY/SHA256SUMS")"
if [[ "$(printf '%s\n' "$EXPECTED_SHA256" | sed '/^$/d' | wc -l | tr -d ' ')" != 1 ]] \
  || ! printf '%s\n' "$EXPECTED_SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "Homebrew update: release manifest must contain one exact checksum for $ASSET" >&2
  exit 65
fi
ACTUAL_SHA256="$(shasum -a 256 "$TEMP_DIRECTORY/$ASSET" | awk '{ print $1 }')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
  echo "Homebrew update: checksum mismatch for $ASSET" >&2
  exit 65
}

ditto -x -k "$TEMP_DIRECTORY/$ASSET" "$TEMP_DIRECTORY/unpacked"
APP="$TEMP_DIRECTORY/unpacked/Headless.app"
[[ -d "$APP" ]] || { echo "Homebrew update: archive does not contain Headless.app" >&2; exit 65; }
codesign --verify --deep --strict "$APP"
CODESIGN_DETAILS="$(codesign --display --verbose=4 "$APP" 2>&1)"
printf '%s\n' "$CODESIGN_DETAILS" | grep -q '^Authority=Developer ID Application:' \
  || { echo "Homebrew update: app is not Developer ID signed" >&2; exit 65; }
printf '%s\n' "$CODESIGN_DETAILS" | grep -q 'flags=.*runtime' \
  || { echo "Homebrew update: hardened runtime is missing" >&2; exit 65; }
for executable in \
  "$APP/Contents/MacOS/Headless" \
  "$APP/Contents/Resources/bin/headless" \
  "$APP/Contents/Resources/bin/headless-mcp"; do
  ARCHITECTURES="$(lipo -archs "$executable")"
  for architecture in arm64 x86_64; do
    printf '%s\n' "$ARCHITECTURES" | grep -Eq "(^| )$architecture( |$)" \
      || { echo "Homebrew update: $executable is missing $architecture" >&2; exit 65; }
  done
done
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

mkdir -p "$ROOT/Casks"
TEMP_CASK="$ROOT/Casks/.headless.rb.tmp"
cat > "$TEMP_CASK" <<CASK
cask "headless" do
  version "$VERSION"
  sha256 "$ACTUAL_SHA256"

  url "https://github.com/LockInTime/headless/releases/download/v#{version}/Headless-#{version}-macos.zip",
      verified: "github.com/LockInTime/headless/"
  name "Headless"
  desc "Persistent safety-enforced browser control for AI agents"
  homepage "https://github.com/LockInTime/headless"

  depends_on macos: ">= :ventura"

  app "Headless.app"
  binary "#{appdir}/Headless.app/Contents/Resources/bin/headless", target: "headless"
  binary "#{appdir}/Headless.app/Contents/Resources/bin/headless-mcp", target: "headless-mcp"

  zap trash: [
    "~/Library/Application Support/com.headless.app",
    "~/Library/Preferences/com.headless.app.plist",
  ]
end
CASK
mv "$TEMP_CASK" "$ROOT/Casks/headless.rb"

echo "Rendered Headless $VERSION cask after distribution verification"
