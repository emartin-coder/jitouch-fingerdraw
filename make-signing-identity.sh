#!/bin/zsh
# One-time: creates a self-signed "Jitouch Local Signing" code-signing identity in your login keychain.
# build.sh uses it automatically, so the Accessibility permission survives rebuilds (re-grant once after the first build with it).
# Undo: Keychain Access > login > My Certificates > delete "Jitouch Local Signing".
set -euo pipefail
T=$(mktemp -d)
cat > $T/cs.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Jitouch Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config $T/cs.cnf -keyout $T/key.pem -out $T/cert.pem 2>/dev/null
PW=$(/usr/bin/openssl rand -hex 12)
/usr/bin/openssl pkcs12 -export -inkey $T/key.pem -in $T/cert.pem -name "Jitouch Local Signing" -out $T/id.p12 -passout pass:$PW
security import $T/id.p12 -k ~/Library/Keychains/login.keychain-db -P $PW -T /usr/bin/codesign
rm -rf $T
security find-identity -p codesigning | grep "Jitouch Local Signing"
