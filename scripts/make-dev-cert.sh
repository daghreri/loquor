#!/usr/bin/env bash
# One-time, per developer Mac: create a self-signed "Loquor Dev" code-signing
# certificate in the login keychain. build-app.sh signs with it, so every rebuild
# keeps the same identity and macOS keeps the Microphone/Accessibility grants.
# (Ad-hoc signing changes identity on every build, so the grants are lost.)
# Remove it with: security delete-identity -c "Loquor Dev"
set -euo pipefail
NAME="Loquor Dev"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "'$NAME' already exists."; exit 0
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.conf" <<CONF
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
CONF
# /usr/bin/openssl (LibreSSL) writes a PKCS#12 that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.conf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$NAME" -passout "pass:$pass" -out "$tmp/id.p12"
security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Created '$NAME' in the login keychain."
