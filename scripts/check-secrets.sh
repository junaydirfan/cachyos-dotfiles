#!/usr/bin/env bash
# Fails if personal values or credential-like strings appear in the repo.
# Personal values are read from this machine at run time, so this public script
# never contains them. Extra strings can go in .secrets-local, one per line.
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo" || exit 2

needles=()
add() { [ "${#1}" -ge 4 ] && needles+=("$1"); return 0; }

add "$(id -un)"
add "$HOME"
add "$(cat /etc/hostname 2>/dev/null)"
add "$(git config user.email)"
add "$(findmnt -no UUID / 2>/dev/null)"
add "$(findmnt -no PARTUUID / 2>/dev/null)"
for f in /sys/class/net/*/address; do
    mac="$(cat "$f" 2>/dev/null)"
    [ "$mac" = "00:00:00:00:00:00" ] || add "$mac"
done
if command -v edid-decode >/dev/null; then
    for f in /usr/lib/firmware/edid/*; do
        [ -f "$f" ] || continue
        while read -r serial; do add "$serial"; done < <(
            edid-decode "$f" 2>/dev/null |
                sed -nE "s/.*Serial Number: '?([^']+)'?.*/\1/Ip"
        )
    done
fi
if [ -f .secrets-local ]; then
    while IFS= read -r line; do add "$line"; done < .secrets-local
fi

files=()
while IFS= read -r -d '' f; do
    [ -f "$f" ] && files+=("$f")
done < <(git ls-files -z --cached --others --exclude-standard)
[ "${#files[@]}" -gt 0 ] || { echo "no files to check"; exit 0; }

status=0
for needle in "${needles[@]}"; do
    hits="$(grep -IlF -i -- "$needle" "${files[@]}" 2>/dev/null)"
    if [ -n "$hits" ]; then
        echo "personal value found (${#needle} chars) in:"
        printf '  %s\n' $hits
        status=1
    fi
done

patterns=(
    'gh[pousr]_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'sk-[A-Za-z0-9_-]{20,}'
    'AKIA[0-9A-Z]{16}'
    'AIza[0-9A-Za-z_-]{30,}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    '(^|[^0-9.])(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?([^0-9.]|$)'
)
for pattern in "${patterns[@]}"; do
    hits="$(grep -InE -- "$pattern" "${files[@]}" 2>/dev/null | grep -v '^scripts/check-secrets.sh:' | cut -d: -f1,2)"
    if [ -n "$hits" ]; then
        echo "suspicious pattern '$pattern' at:"
        printf '  %s\n' $hits
        status=1
    fi
done

[ "$status" -eq 0 ] && echo "clean: ${#files[@]} files, ${#needles[@]} personal values checked"
exit "$status"
