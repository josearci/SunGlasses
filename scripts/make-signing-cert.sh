#!/bin/bash
# One-time setup: creates the "SunGlasses Signing" certificate every build is signed with, puts it in your
# login keychain for local builds, and stores it in the GitHub repo's secrets for releases.
#
# macOS ties the Accessibility grant to the app's signing certificate, so every build anyone runs must carry
# the same one. Run this again only if the certificate is lost: a new certificate means every user has to
# allow SunGlasses in Accessibility once more after their next update.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="SunGlasses Signing"
REPO=$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "A '$NAME' certificate is already in your keychain. Delete it in Keychain Access first if you really want a new one." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -addext keyUsage=digitalSignature -addext extendedKeyUsage=codeSigning \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$PASS" -out "$TMP/cert.p12"

security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
gh secret set SIGNING_P12 --repo "$REPO" --body "$(base64 < "$TMP/cert.p12")"
gh secret set SIGNING_PASSWORD --repo "$REPO" --body "$PASS"

echo "'$NAME' is in your login keychain and in github.com/$REPO's secrets (SIGNING_P12, SIGNING_PASSWORD)."
echo "The first local build asks whether codesign may use the key: choose Always Allow."
