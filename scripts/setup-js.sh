#!/usr/bin/env sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installation=${1:?Provide an absolute, dedicated installation directory}
case "$installation" in
    /*) ;;
    *) echo "Installation directory must be absolute" >&2; exit 1 ;;
esac
node_version=$(cat "$project_root/.node-version")
pnpm_version=$(sed -n 's/.*"packageManager": "pnpm@\([^"]*\)".*/\1/p' "$project_root/package.json")
case "$(uname -s)" in
    Linux) platform=linux ;;
    Darwin) platform=darwin ;;
    *) echo "Only Linux and macOS are supported" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64) architecture=x64 ;;
    arm64 | aarch64) architecture=arm64 ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
esac
node_root="$installation/node-$node_version"
pnpm_root="$installation/pnpm-$pnpm_version"
[ ! -e "$node_root" ] && [ ! -e "$pnpm_root" ] || {
    echo "Use a fresh installation directory; existing tools are never overwritten" >&2
    exit 1
}
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT HUP INT TERM
archive="node-v$node_version-$platform-$architecture.tar.gz"
base="https://nodejs.org/dist/v$node_version"
curl --fail --location --silent --show-error --connect-timeout 15 --max-time 180 --retry 3 --retry-all-errors "$base/$archive" -o "$staging/$archive"
curl --fail --location --silent --show-error --connect-timeout 15 --max-time 180 --retry 3 --retry-all-errors "$base/SHASUMS256.txt" -o "$staging/SHASUMS256.txt"
(cd "$staging" && awk -v file="$archive" '$2 == file' SHASUMS256.txt > selected.sha256 && test -s selected.sha256 && shasum -a 256 -c selected.sha256)
mkdir -p "$node_root/bin" "$pnpm_root"
# Extract only the runtime and license; the official archive also contains npm.
tar -xzf "$staging/$archive" -C "$node_root" --strip-components=1 \
    "node-v$node_version-$platform-$architecture/bin/node" \
    "node-v$node_version-$platform-$architecture/LICENSE"
pnpm_archive="pnpm-$platform-$architecture.tar.gz"
curl --fail --location --silent --show-error --connect-timeout 15 --max-time 180 --retry 3 --retry-all-errors \
    "https://github.com/pnpm/pnpm/releases/download/v$pnpm_version/$pnpm_archive" \
    -o "$staging/$pnpm_archive"
awk -v file="$pnpm_archive" '$2 == file' "$project_root/scripts/pnpm-$pnpm_version.sha256" > "$staging/pnpm.sha256"
(cd "$staging" && test -s pnpm.sha256 && shasum -a 256 -c pnpm.sha256)
tar -xzf "$staging/$pnpm_archive" -C "$pnpm_root"
chmod +x "$pnpm_root/pnpm"
export PATH="$node_root/bin:$pnpm_root:$PATH"
(cd "$project_root" && sh scripts/assert-js-version.sh)
printf 'export PATH="%s/bin:%s:$PATH"\n' "$node_root" "$pnpm_root"
if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n%s\n' "$node_root/bin" "$pnpm_root" >>"$GITHUB_PATH"
fi
