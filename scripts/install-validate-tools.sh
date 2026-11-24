#!/usr/bin/env bash
# Usage: install-validate-tools.sh
#
# Installs the pinned flux and kubeconform that scripts/validate.sh runs into
# $SANDBOX_VALIDATE_CACHE/bin, by default
# ${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-validate/bin. Each archive is
# checked against its SHA-256 constant below before anything is installed,
# and a tool whose installed copy reports the pinned version is not
# downloaded again. Only Linux on x86_64 is supported. yq, jq, git, curl,
# tar, sha256sum and bats come from the host.
set -euo pipefail

readonly FLUX_VERSION=2.10.0
readonly FLUX_URL=https://github.com/fluxcd/flux2/releases/download/v$FLUX_VERSION/flux_${FLUX_VERSION}_linux_amd64.tar.gz
readonly FLUX_SHA256=208dd7012c04fedeed5b2d0b6e63df3b15b1c34a381527811685c098bc9f8659

readonly KUBECONFORM_VERSION=0.8.0
readonly KUBECONFORM_URL=https://github.com/yannh/kubeconform/releases/download/v$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz
readonly KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883

say() { printf 'install-validate-tools: %s\n' "$*"; }
fail() {
	printf 'install-validate-tools: error: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -gt 0 ]; then
	echo "usage: scripts/install-validate-tools.sh" >&2
	exit 2
fi
platform=$(uname -sm)
[ "$platform" = "Linux x86_64" ] || fail "only Linux x86_64 is supported (found $platform)"

cache=${SANDBOX_VALIDATE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-validate}
mkdir -p -- "$cache/bin"
dl=$(mktemp -d)
trap 'rm -rf -- "$dl"' EXIT

# installed_version <tool>: prints the version the installed copy of the
# tool reports, or nothing when there is none.
installed_version() {
	local bin=$cache/bin/$1
	[ -x "$bin" ] || return 0
	case $1 in
	flux) "$bin" version --client ;;
	kubeconform) "$bin" -v ;;
	esac 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || :
}

# install_tool <tool> <version> <url> <sha256>: installs the binary of the
# tool from the .tar.gz archive at the URL.
install_tool() {
	local tool=$1 version=$2 url=$3 sum=$4 file got
	if [ "$(installed_version "$tool")" = "$version" ]; then
		say "$tool $version already installed"
		return
	fi
	file=${url##*/}
	curl -fsSL --retry 3 -o "$dl/$file" "$url" 2>"$dl/err" ||
		fail "downloading $url failed: $(grep '[^[:space:]]' "$dl/err" | tail -n 1)"
	got=$(sha256sum "$dl/$file" | cut -d ' ' -f 1)
	[ "$got" = "$sum" ] || fail "$file: checksum mismatch (expected $sum, got $got)"
	tar -xzf "$dl/$file" -C "$dl" "$tool" 2>"$dl/err" ||
		fail "$file: extracting $tool failed: $(grep '[^[:space:]]' "$dl/err" | tail -n 1)"
	install -m 0755 "$dl/$tool" "$cache/bin/$tool"
	say "$tool $version installed"
}

install_tool flux "$FLUX_VERSION" "$FLUX_URL" "$FLUX_SHA256"
install_tool kubeconform "$KUBECONFORM_VERSION" "$KUBECONFORM_URL" "$KUBECONFORM_SHA256"
