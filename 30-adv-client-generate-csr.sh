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

header 'ADVANCED WORKFLOW — STEP 1/3 — CLIENT MACHINE'
info 'Run on the CLIENT machine. Generates client.key and client.csr.'
info 'Next: transfer ONLY client.csr to the TRUSTED machine; run 31-adv-ca-sign-client-csr.sh.'
warn 'Never transfer client.key to the TRUSTED machine.'
need_openssl
ask 'New destination directory (must not exist): '; DEST=$ANSWER
[ -n "$DEST" ] || fail 'Destination required.'
[ ! -e "$DEST" ] || fail 'Destination already exists.'
ask_cn
CN=$ANSWER
ask 'Password-protect client.key? [y/N]: '
case "$ANSWER" in y|Y|yes|YES) ENCRYPT=yes;; *) ENCRYPT=no;; esac
line
info "Destination: $DEST"
info "CN: $CN"
info "Private key encryption: $ENCRYPT"
line
confirm 'Generate key and CSR?' || fail 'Cancelled.'
# Stage in destination parent to keep final installation atomic.
PARENT=$(dirname -- "$DEST"); [ -d "$PARENT" ] || fail 'Destination parent directory does not exist.'
TMP=$(mktemp -d "$PARENT/.mtls-tmp.XXXXXXXX") || fail 'Cannot create temporary directory.'
chmod 700 "$TMP"
generate_key "$TMP/client.key" "$ENCRYPT" || fail 'Key generation failed.'
openssl req -new -key "$TMP/client.key" -out "$TMP/client.csr" -subj "/CN=$CN" || fail 'CSR generation failed.'
openssl req -in "$TMP/client.csr" -verify -noout >/dev/null 2>&1 || fail 'CSR verification failed.'
chmod 600 "$TMP/client.key"
chmod 644 "$TMP/client.csr"
[ ! -e "$DEST" ] || fail 'Destination appeared concurrently.'
mv "$TMP" "$DEST" || fail 'Unable to install client directory.'
TMP=''
line; success 'Client key and CSR generated.'
info "Transfer: $DEST/client.csr → TRUSTED machine"
info 'Then run: 31-adv-ca-sign-client-csr.sh on TRUSTED machine.'
warn 'Keep client.key private on this machine.'
