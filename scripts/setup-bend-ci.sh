#!/bin/sh
set -eu
# CI-only, project-owned installation. Never alters ~/.bend or shell profiles.
# Archive hashes are from https://bend-lang.com/install.sh for Bend 2.0.34.
[ "${CI:-}" = true ] || { echo 'This setup script is CI-only.' >&2; exit 1; }
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64; sum=a60c820c0ced758d8ace839507ff6c508a204ce4ef0f45e1089ed7bc73e8c267 ;;
  Darwin-x86_64) platform=darwin-x64; sum=066d4a07a1871a2946be8f42f926582bfda5f13ff728c234ffe79635bd240650 ;;
  Linux-aarch64) platform=linux-arm64; sum=416a17d282a9fd05ab9637a238b51d5ca508114d9773c37d1c11cad595440ed1 ;;
  Linux-x86_64) platform=linux-x64; sum=78106a97af242429dcc057258eb8d10f69cddebcd5e263022185a52d003e09bf ;;
  *) echo 'Unsupported native CI platform.' >&2; exit 1 ;;
esac
root="${RUNNER_TEMP:?}/jev-bend-2.0.34"
mkdir -p "$root"
archive="$root/compiler.tar.gz"
trap 'rm -f "$archive"' EXIT
release='https://github.com/bendlang/bend/releases/download/v2.0.34'
curl --proto '=https' --tlsv1.2 -fsSL "$release/bend-2.0.34-$platform.tar.gz" -o "$archive"
if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$sum" "$archive" | sha256sum -c -
else
  printf '%s  %s\n' "$sum" "$archive" | shasum -a 256 -c -
fi
tar -xzf "$archive" -C "$root"
case "$platform" in
  darwin-*)
    codesign --verify --strict "$root/bend/bin/bend" || {
      echo 'Upstream compiler signature is invalid.' \
        'Use a trusted local build; do not bypass macOS signature checks.' >&2
      exit 1
    }
    ;;
esac
printf '%s\n' "$root/bend/bin" >> "${GITHUB_PATH:?}"
