#!/bin/bash
set -euo pipefail

CERT_NAME="Rewrite Development"

# Check if cert already exists
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists."
    exit 0
fi

TMPDIR=$(mktemp -d)
CERT_CONFIG="$TMPDIR/cert.config"

cat > "$CERT_CONFIG" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
prompt             = no
[ req_dn ]
CN = $CERT_NAME
[ extensions ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
EOF

# Generate self-signed certificate
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" \
    -days 3650 \
    -config "$CERT_CONFIG" \
    -extensions extensions \
    2>/dev/null

# Convert to p12
openssl pkcs12 -export \
    -out "$TMPDIR/cert.p12" \
    -inkey "$TMPDIR/key.pem" \
    -in "$TMPDIR/cert.pem" \
    -passout pass: \
    2>/dev/null

# Import into keychain and trust for code signing
security import "$TMPDIR/cert.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -P "" \
    -T /usr/bin/codesign

# Set the certificate as trusted for code signing
security add-trusted-cert -d -r trustRoot \
    -p codeSign \
    -k ~/Library/Keychains/login.keychain-db \
    "$TMPDIR/cert.pem"

rm -rf "$TMPDIR"

echo "Certificate '$CERT_NAME' created and trusted for code signing."
echo "You may need to restart Keychain Access or run 'security find-identity -v -p codesigning' to verify."
