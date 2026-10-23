#!/usr/bin/env bash
# CI only: print the codesign identity for scripts/release.sh (CODESIGN_IDENTITY).
# With the repo secrets MACOS_SIGNING_P12_BASE64 + MACOS_SIGNING_P12_PASSWORD (the stable self-signed identity
# exported from the release Mac, docs/release.md) it imports the identity into a throwaway keychain under
# $RUNNER_TEMP and prints its SHA-1 hash; without them it prints "-" (ad-hoc: users re-grant Microphone and
# Screen & System Audio after every update). Never prints the secrets.
#
# Usage: CODESIGN_IDENTITY="$(scripts/ci-signing.sh)"
set -euo pipefail

if [[ -z "${MACOS_SIGNING_P12_BASE64:-}" || -z "${MACOS_SIGNING_P12_PASSWORD:-}" ]]; then
  echo "signing: no identity secrets, ad-hoc" >&2
  echo "-"
  exit 0
fi

TMP="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN="$TMP/mn-signing.keychain-db"
P12="$TMP/mn-signing.p12"
KC_PASS="$(/usr/bin/openssl rand -hex 16)"
trap 'rm -f "$P12"' EXIT

printf '%s' "$MACOS_SIGNING_P12_BASE64" | base64 --decode > "$P12"
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$MACOS_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
hash="$(security find-identity -p codesigning "$KEYCHAIN" | awk '$1 ~ /^[0-9]+\)$/ && $2 ~ /^[0-9A-F]+$/ {print $2; exit}')"
if [[ -z "$hash" ]]; then
  echo "signing: the p12 holds no code-signing identity, falling back to ad-hoc" >&2
  echo "-"
  exit 0
fi
echo "signing: stable self-signed identity $hash" >&2
echo "$hash"
