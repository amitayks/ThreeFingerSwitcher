#!/bin/bash
# Create a stable self-signed code-signing identity so macOS TCC permission grants
# (Accessibility, Screen Recording) persist across rebuilds. Ad-hoc signing changes the
# app's identity (CDHash) on every build, which silently invalidates previously-granted
# permissions; a stable identity fixes that. Reversible: delete the cert in Keychain Access.
set -euo pipefail

CERT_CN="ThreeFingerSwitcher Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_CN"; then
    echo "✓ signing identity '$CERT_CN' already exists"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $CERT_CN
[ v3 ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "▸ generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

# Legacy PBE algorithms + a real password: required for macOS `security` to import a p12
# produced by modern OpenSSL 3 (otherwise: "MAC verification failed").
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -name "$CERT_CN" -passout pass:devpass \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

echo "▸ importing into login keychain"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P devpass -A -T /usr/bin/codesign

echo "✓ created signing identity '$CERT_CN'"
echo "  Tip: run ./scripts/allow-codesign-key.sh once to stop codesign from prompting"
echo "  for your keychain password on every build (or click 'Always Allow' on the prompts)."
security find-identity -p codesigning "$KEYCHAIN" | grep "$CERT_CN" || true
