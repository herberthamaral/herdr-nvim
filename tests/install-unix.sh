#!/usr/bin/env bash
# End-to-end check of the plugin's macOS/Linux build hook (herdr/install.sh),
# run the way `herdr plugin install` runs it, each case on a fresh copy of the
# checkout, against a stand-in release served on 127.0.0.1. The Unix twin of
# tests/install-windows.ps1. CI runs it on ubuntu-latest and macos-latest.
#   bash tests/install-unix.sh [--no-source-build]
# --no-source-build skips the one case that builds from source (minutes).
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source_build=1
[ "${1:-}" != --no-source-build ] || source_build=
failures=0
work=$(mktemp -d)
server=
cleanup() {
  [ -z "$server" ] || kill "$server" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

check() {
  local name=$1
  shift
  if "$@"; then echo "  ok    $name"; else echo "  FAIL  $name"; failures=$((failures + 1)); fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$repo/herdr-plugin.toml" | head -1)
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target=aarch64-apple-darwin ;;
  Darwin-x86_64) target=x86_64-apple-darwin ;;
  Linux-x86_64) target=x86_64-unknown-linux-gnu ;;
  Linux-aarch64) target=aarch64-unknown-linux-gnu ;;
  *) echo "no prebuilt target for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
asset=herdr-nvim-$target

# The stand-in release: what github.com/<repo>/releases/download serves.
release=$work/release/v$version
mkdir -p "$release"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server --bind 127.0.0.1 --directory "$work/release" "$port" >/dev/null 2>&1 &
server=$!
for _ in $(seq 50); do
  curl -fs -o /dev/null "http://127.0.0.1:$port/" && break
  sleep 0.1
done
export HERDR_NVIM_RELEASE_BASE=http://127.0.0.1:$port

# The stand-in binary: answers the probe like the real one (no argument:
# exit 2) and leaves a mark, so a case can tell whether it ever ran.
export HERDR_NVIM_TEST_MARKER=$work/ran
fake=$work/fake-herdr-nvim
# shellcheck disable=SC2016 # expands when the stand-in runs, not here
printf '#!/bin/sh\ntouch "$HERDR_NVIM_TEST_MARKER"\nexit 2\n' >"$fake"
chmod +x "$fake"

# Puts the stand-in binary in the release with a .sha256 of the given kind.
publish() {
  cp "$fake" "$release/$asset"
  rm -f "$release/$asset.sha256"
  [ "$1" != none ] || return 0
  local sum
  sum=$(sha256 "$release/$asset")
  case $1 in
    good) printf '%s  %s\n' "$sum" "$asset" ;;
    wrong) printf '%s  %s\n' "$(printf '0%.0s' $(seq 64))" "$asset" ;;
    upper-crlf) printf '%s  %s\r\n' "$(printf '%s' "$sum" | tr a-f A-F)" "$asset" ;;
    binary-mode) printf '%s *%s\n' "$sum" "$asset" ;;
  esac >"$release/$asset.sha256"
}

# The checkout's tracked files, uncommitted edits included.
new_checkout() {
  local dir tree
  dir=$(mktemp -d "$work/checkout.XXXXXX")
  tree=$(git -C "$repo" stash create)
  git -C "$repo" archive "${tree:-HEAD}" | tar -x -C "$dir"
  echo "$dir"
}

# PATH without any directory that has cargo in it.
path_without_cargo=
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [ -n "$d" ] && [ ! -x "$d/cargo" ] && path_without_cargo=$path_without_cargo${path_without_cargo:+:}$d
done
if ! PATH=$path_without_cargo command -v curl >/dev/null 2>&1; then
  echo "cargo shares a directory with curl ($(command -v cargo)); can't hide it" >&2
  exit 1
fi

# The exact command herdr-plugin.toml gives herdr for macOS and Linux.
# Sets $rc and $err (stderr).
run_hook() {
  local dir=$1 path=$2
  rm -f "$HERDR_NVIM_TEST_MARKER"
  rc=0
  (cd "$dir" && PATH=$path bash herdr/install.sh) >/dev/null 2>"$work/stderr" || rc=$?
  err=$(cat "$work/stderr")
  sed 's/^/    | /' "$work/stderr"
  echo "    | exit $rc"
}

ran() { [ -e "$HERDR_NVIM_TEST_MARKER" ]; }
no_tmp_left() { [ ! -e "$1/bin/herdr-nvim.tmp" ] && [ ! -e "$1/bin/herdr-nvim.tmp.sha256" ]; }
installed_is_fake() { cmp -s "$1/bin/herdr-nvim" "$fake"; }
says() { grep -q -- "$1" <<<"$err"; }

echo "== the release's binary matches its SHA-256: installed, no cargo needed"
publish good
dir=$(new_checkout)
run_hook "$dir" "$path_without_cargo"
check "exit 0" [ "$rc" -eq 0 ]
check "bin/herdr-nvim is the release's binary" installed_is_fake "$dir"
check "no source build" [ ! -e "$dir/target/release/herdr-nvim" ]
check "no download left in bin/" no_tmp_left "$dir"

for kind in upper-crlf binary-mode; do
  echo "== a .sha256 written as $kind still matches"
  publish "$kind"
  dir=$(new_checkout)
  run_hook "$dir" "$path_without_cargo"
  check "exit 0" [ "$rc" -eq 0 ]
  check "bin/herdr-nvim is the release's binary" installed_is_fake "$dir"
done

echo "== wrong SHA-256, no cargo: refused, the download never runs"
publish wrong
dir=$(new_checkout)
run_hook "$dir" "$path_without_cargo"
check "exit non-zero" [ "$rc" -ne 0 ]
check "the error names the SHA-256" says "does not match its SHA-256"
check "the download never ran" eval '! ran'
check "nothing installed" [ ! -e "$dir/bin/herdr-nvim" ]
check "no download left in bin/" no_tmp_left "$dir"

echo "== wrong SHA-256 on an upgrade, no cargo: the installed binary stays"
dir=$(new_checkout)
mkdir -p "$dir/bin"
printf 'the binary from before\n' >"$dir/bin/herdr-nvim"
before=$(sha256 "$dir/bin/herdr-nvim")
run_hook "$dir" "$path_without_cargo"
check "exit non-zero" [ "$rc" -ne 0 ]
check "the download never ran" eval '! ran'
check "bin/herdr-nvim is unchanged" [ "$(sha256 "$dir/bin/herdr-nvim")" = "$before" ]

echo "== the release has no .sha256, no cargo: refused, the download never runs"
publish none
dir=$(new_checkout)
run_hook "$dir" "$path_without_cargo"
check "exit non-zero" [ "$rc" -ne 0 ]
check "the error says there is no SHA-256" says "no SHA-256"
check "the download never ran" eval '! ran'
check "nothing installed" [ ! -e "$dir/bin/herdr-nvim" ]
check "no download left in bin/" no_tmp_left "$dir"

if [ -n "$source_build" ]; then
  echo "== wrong SHA-256 with cargo: builds from source instead"
  publish wrong
  dir=$(new_checkout)
  run_hook "$dir" "$PATH"
  check "exit 0" [ "$rc" -eq 0 ]
  check "built from source" [ -x "$dir/target/release/herdr-nvim" ]
  check "the download never ran" eval '! ran'
  check "bin/herdr-nvim is the source build" cmp -s "$dir/bin/herdr-nvim" "$dir/target/release/herdr-nvim"
else
  echo "  skip  the source build (--no-source-build)"
fi

if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures check(s)"
  exit 1
fi
echo OK
