#!/bin/zsh
# Creates a self-signed code signing identity for release builds, once per maintainer.
#
# Without a Developer ID, releases are signed with this certificate instead. macOS then sees every release as coming
# from the same signer, so permissions such as Full Disk Access carry over from one version to the next, and XCleaner's
# updater accepts only releases signed with it. The identity lives in a keychain of its own, never in the login
# keychain, and nothing here changes trust settings or asks for a password.
#
# Back up both files it prints at the end: a lost identity means users grant Full Disk Access again after the next
# release, and the updater can't install that release by itself.
set -euo pipefail

name=${1:-"$(git config user.name) Code Signing"}
keychain=${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/self-signed-codesign.keychain-db}
password_file=${keychain%.keychain-db}.password

if [[ -e $keychain ]]; then
    echo "A signing keychain already exists at $keychain" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077

cat > "$work/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $name
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

# Twenty years, so no release outlives its certificate.
openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" \
    -config "$work/cert.cnf" 2>/dev/null
password=$(openssl rand -hex 32)
# The older encryption, which the security tool can read.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/identity.p12" -passout "pass:$password" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

print -r -- "$password" > "$password_file"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without asking.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null

echo "Created the signing identity “$name”:"
security find-identity -p codesigning "$keychain" | awk '/1\)/ {print "  " $2}'
echo "Back up these two files:"
echo "  $keychain"
echo "  $password_file"
