#!/bin/bash
set -euo pipefail

# Creates a stable, self-signed code-signing identity for local freetalk builds.
# Ad-hoc signatures change their CDHash on every build, which makes macOS TCC
# treat each update as a different app. A stable certificate keeps the
# designated requirement (and therefore Accessibility / Input Monitoring grants)
# valid across rebuilds.

identity_name="freetalk Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$identity_name\""; then
  printf '%s\n' "Already available: $identity_name"
  printf '%s\n' "Build with: bash scripts/build.sh"
  exit 0
fi

printf '%s\n' "Creating code-signing identity: $identity_name"
printf '%s\n' "macOS may ask for your login password or keychain approval."

work="$(mktemp -d "${TMPDIR:-/tmp}/freetalk-signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
key="$work/key.pem"
cert="$work/cert.pem"
p12="$work/identity.p12"
pass="$(openssl rand -hex 16)"

# Reuse an existing certificate if its private key is already in the keychain.
# Trust is limited to code signing: TCC grants follow this certificate.
if security find-certificate -c "$identity_name" -p "$keychain" >"$cert" 2>/dev/null; then
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$cert" 2>/dev/null || true
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$identity_name\""; then
    printf '%s\n' "Trusted existing certificate: $identity_name"
    printf '%s\n' "Build with: bash scripts/build.sh"
    exit 0
  fi
fi

openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" -days 3650 -nodes \
  -subj "/CN=$identity_name" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

openssl pkcs12 -export -out "$p12" -inkey "$key" -in "$cert" \
  -passout "pass:$pass" -name "$identity_name" >/dev/null 2>&1

# Anything signed with this key inherits freetalk's Accessibility, Input
# Monitoring and microphone grants. Keep the private key non-extractable and
# usable by codesign only; do not add /usr/bin/security, which could export it.
security import "$p12" -k "$keychain" -P "$pass" -x -T /usr/bin/codesign >/dev/null
# When the keychain password is available non-interactively, pre-authorize
# codesign. Otherwise the first signature may show a keychain approval dialog;
# choose “Always Allow”.
if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$keychain" >/dev/null 2>&1 || true
fi
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$cert" >/dev/null 2>&1 || true

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$identity_name\""; then
  printf '%s\n' "The certificate was imported but is not trusted for code signing." >&2
  printf '%s\n' "Open Keychain Access → login → Certificates → '$identity_name' → Get Info → Trust → Code Signing: Always Trust." >&2
  printf '%s\n' "Then run this script again." >&2
  exit 1
fi

printf '%s\n' "Ready: $identity_name"
printf '%s\n' "Build with: bash scripts/build.sh"
printf '%s\n' "After the first build signed with this identity, re-grant freetalk in"
printf '%s\n' "System Settings → Privacy & Security → Accessibility / Input Monitoring:"
printf '%s\n' "remove the old entry with “−”, then add the current app with “+”."
printf '%s\n' "Later local rebuilds keep the same designated requirement and permissions."
