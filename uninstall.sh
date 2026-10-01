#!/usr/bin/env bash
# Removes what setup.sh installed (recorded in .installed) and the build outputs.
# Entries that fail to uninstall (e.g. sudo without a password) stay in .installed for the next run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALLED="$ROOT/.installed"

if [ -f "$INSTALLED" ]; then
	left=""
	while IFS=: read -r kind name; do
		ok=1
		case "$kind" in
		brew)   echo "brew uninstall $name"; brew uninstall "$name" || ok=0 ;;
		apt)    echo "apt-get remove $name"; sudo apt-get remove -y "$name" || ok=0 ;;
		pacman) echo "pacman -Rs $name"; sudo pacman -Rs --noconfirm "$name" || ok=0 ;;
		rustup) echo "rustup toolchain uninstall $name"; rustup toolchain uninstall "$name" || ok=0 ;;
		esac
		[ $ok = 1 ] || left="$left$kind:$name"$'\n'
	done < <(sort -u "$INSTALLED")
	if [ -n "$left" ]; then
		printf '%s' "$left" > "$INSTALLED"
		echo "Not removed, still listed in .installed:"
		cat "$INSTALLED"
	else
		rm -f "$INSTALLED"
	fi
fi
rm -rf "$ROOT/third_party" "$ROOT/env.sh" "$ROOT/rust-toolchain.pinned" "$ROOT/setup.log" "$ROOT"/poc/*/target
echo "Removed. Packages that were installed before setup.sh ran were left alone."
