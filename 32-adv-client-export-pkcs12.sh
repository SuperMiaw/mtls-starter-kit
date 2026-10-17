#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=config.sh
. "$ROOT/config.sh"
# shellcheck source=_common.sh
. "$ROOT/_common.sh"

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

header 'ADVANCED WORKFLOW — STEP 3/3 — CLIENT MACHINE'
info 'Run on the CLIENT machine, after receiving client.crt from the CA.'
info 'Packages client.key + client.crt into client.pfx for import into applications.'
info 'This step is optional if your application accepts key and certificate files directly.'
need_openssl
ask 'Client directory containing client.key and client.crt: '; DIR=$ANSWER
[ -f "$DIR/client.key" ] && [ -f "$DIR/client.crt" ] || fail 'Missing client.key or client.crt.'
verify_client_pair "$DIR/client.key" "$DIR/client.crt" || fail 'Client key does not match certificate.'
openssl x509 -in "$DIR/client.crt" -noout -checkend 0 >/dev/null 2>&1 || fail 'Client certificate expired or invalid.'
ask 'Optional CA certificate path (Enter to skip): '; CACRT=$ANSWER
if [ -n "$CACRT" ]; then
  [ -f "$CACRT" ] || fail 'CA certificate not found.'
  openssl verify -purpose sslclient -CAfile "$CACRT" "$DIR/client.crt" >/dev/null || fail 'Certificate is not verified by this CA.'
fi
DEST="$DIR/client.pfx"
[ ! -e "$DEST" ] || fail 'client.pfx already exists. Remove it manually before retrying.'
line
info "Output: $DEST"
line
confirm 'Create PKCS#12 bundle?' || fail 'Cancelled.'
TMP=$(mktemp -d "$DIR/.mtls-tmp.XXXXXXXX") || fail 'Cannot create temporary directory.'
ask_pfx_password "$TMP/pfx-password"
if [ -n "$CACRT" ]; then
  openssl pkcs12 -export -out "$TMP/client.pfx" -inkey "$DIR/client.key" -in "$DIR/client.crt" -certfile "$CACRT" -passout file:"$TMP/pfx-password" || fail 'Export failed.'
else
  openssl pkcs12 -export -out "$TMP/client.pfx" -inkey "$DIR/client.key" -in "$DIR/client.crt" -passout file:"$TMP/pfx-password" || fail 'Export failed.'
fi
rm -f "$TMP/pfx-password"
# Check that the exported file is well-formed ASN.1 without exposing the password.
openssl asn1parse -inform DER -in "$TMP/client.pfx" -noout >/dev/null 2>&1 || fail 'Invalid PKCS#12 structure.'
chmod 600 "$TMP/client.pfx"
[ ! -e "$DEST" ] || fail 'Output appeared concurrently.'
mv "$TMP/client.pfx" "$DEST" || fail 'Unable to install PFX.'
line; success "PKCS#12 bundle ready: $DEST"
info 'Next: import client.pfx into your browser, operating system, or application.'
warn 'client.pfx contains the private key; protect it and transfer it securely.'
