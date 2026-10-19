#!/usr/bin/env bash
# Create (once) a local self-signed code-signing identity so rebuilt apps keep their
# macOS privacy permissions (Microphone, Screen & System Audio Recording).
#
# macOS ties those permissions to the app's code signature. Ad-hoc signatures change on every
# build, so permissions reset; a fixed certificate keeps the designated requirement stable.
# The identity lives in its own keychain (the login keychain is not modified; the new keychain is
# appended to the user keychain search list), unlocked with a random password stored in
# ~/.config/meeting-notes/signing-keychain.pass (mode 600).
#
# Usage: scripts/setup-signing.sh            (idempotent; prints the identity hash)
set -euo pipefail

NAME="MeetingNotes Local Signing"
KEYCHAIN="$HOME/Library/Keychains/meetingnotes-signing.keychain-db"
PASS_FILE="$HOME/.config/meeting-notes/signing-keychain.pass"

add_to_search_list() {
  # codesign only finds identities in the user search list; keep every existing entry.
  local current
  current="$(security list-keychains -d user | tr -d ' "')"
  if ! grep -qxF "$KEYCHAIN" <<<"$current"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $current "$KEYCHAIN"
  fi
}

identity_hash() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}'
}

if [[ -f "$KEYCHAIN" && -f "$PASS_FILE" ]]; then
  security unlock-keychain -p "$(cat "$PASS_FILE")" "$KEYCHAIN"
  add_to_search_list
  if [[ -n "$(identity_hash)" ]]; then
    identity_hash
    exit 0
  fi
fi

mkdir -p "$(dirname "$PASS_FILE")"
umask 077
if [[ ! -f "$PASS_FILE" ]]; then
  /usr/bin/openssl rand -hex 16 > "$PASS_FILE"
fi
PASS="$(cat "$PASS_FILE")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12_PASS="$(/usr/bin/openssl rand -hex 12)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$P12_PASS" 2>/dev/null

[[ -f "$KEYCHAIN" ]] || security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
add_to_search_list
identity_hash
