#!/usr/bin/env bash
# Creates the self-signed code signing identity that build-client.sh signs the app with, once per machine
# The keychain then keeps its "Always Allow" for VibeRDP across builds, docs/manuals/devSetup.md
# Only for this machine: other Macs still see an app from an unidentified developer
#
# Environment:
#   VIBERDP_SIGN_IDENTITY  the name of the identity (default: "VibeRDP Self-Signed")

set -euo pipefail

IDENTITY=${VIBERDP_SIGN_IDENTITY:-"VibeRDP Self-Signed"}
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Ten years: the certificate is checked by nobody but this keychain, and a new one would ask for the password again
DAYS=3650

if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
    echo "The keychain already holds \"$IDENTITY\""
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# codesign sees the identity only with the codeSigning purpose
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
    -keyout "$work/key.pem" -out "$work/cert.pem" -subj "/CN=$IDENTITY/O=VibeBrains" \
    -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# The key leaves the disk inside the keychain only: the files go with the temporary folder
password=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -out "$work/identity.p12" -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$IDENTITY" -passout "pass:$password"
security import "$work/identity.p12" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign

security find-identity -p codesigning | grep -qF "\"$IDENTITY\"" || {
    echo "\"$IDENTITY\" is not among the code signing identities" >&2
    exit 1
}
echo "Created \"$IDENTITY\": build-client.sh signs the app with it"
