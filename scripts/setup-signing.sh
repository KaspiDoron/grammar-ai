#!/bin/bash
# One-time setup: creates a free, local, self-signed code signing identity
# named "Grammar AI Local Dev" in your login keychain.
#
# Why: macOS ties the Accessibility permission to the app's code signature.
# An ad-hoc signature changes on every build, so after each rebuild the
# permission silently stops working (the toggle still looks ON). Signing with
# a stable identity keeps the permission across rebuilds.
#
# This identity is only trusted on your own Mac. It is NOT a substitute for an
# Apple Developer ID and cannot be used to distribute the app to others.
#
# macOS will ask for your login password once, to trust the certificate for
# code signing. To undo everything: open Keychain Access, search for
# "Grammar AI Local Dev", delete the certificate and its private key.
set -euo pipefail

NAME="Grammar AI Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "'$NAME' already exists and is valid. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(uuidgen)"

cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = v3_codesign
prompt             = no
[ dn ]
CN = $NAME
[ v3_codesign ]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
CNF

# /usr/bin/openssl is the LibreSSL that ships with macOS. It writes a PKCS#12
# file that `security import` accepts; OpenSSL 3 would need -legacy.
echo "==> Generating key and certificate"
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

echo "==> Importing into the login keychain (codesign may use the key)"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo "==> Trusting the certificate for code signing (macOS asks for your password)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "==> Done. scripts/bundle-app.sh will now sign with '$NAME'."
    echo "    The first build may show a keychain prompt: choose Always Allow."
else
    echo "error: the identity was imported but is not listed as valid." >&2
    exit 1
fi
