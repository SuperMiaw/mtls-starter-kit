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

header 'ADVANCED WORKFLOW — STEP 2/3 — TRUSTED MACHINE'
info 'Run on the TRUSTED machine. Signs a CSR received from a client.'
info 'Next: return ONLY client.crt to the client machine; run 32-adv-client-export-pkcs12.sh.'
warn 'Never transfer ca.key to the client.'
need_openssl
choose_ca
ask 'Path to received client.csr: '; CSR=$ANSWER
[ -f "$CSR" ] || fail 'CSR file not found.'
openssl req -in "$CSR" -verify -noout >/dev/null 2>&1 || fail 'CSR signature invalid.'
info 'Requested subject:'; openssl req -in "$CSR" -noout -subject
info 'Public key fingerprint:'
openssl req -in "$CSR" -pubkey -noout | openssl pkey -pubin -pubout -outform DER | openssl dgst -sha256
warn 'Verify the requester identity through a trusted channel. A valid CSR signature alone does not establish authorization.'
ask_years 2
[ "$years" -le 2 ] || warn 'Long-lived client certificates increase exposure if the client key is stolen.'
REQUEST_DAYS=$((years * 365))
max_days_for_ca "$REQUEST_DAYS"
[ "$DAYS" -eq "$REQUEST_DAYS" ] || warn "Validity reduced to $DAYS days to remain within CA expiry."
ask 'Output client.crt path (must not exist): '; DEST=$ANSWER
[ -n "$DEST" ] || fail 'Output path required.'
[ ! -e "$DEST" ] || fail 'Output already exists.'
ask_name 'Client directory name for retained public certificate: '; NAME=$ANSWER
[ "$NAME" != backup ] || fail 'Reserved client name.'
mkdir -p "$ROOT/clients"
chmod 700 "$ROOT/clients"
MANAGED="$ROOT/clients/$NAME"
if [ -e "$MANAGED" ]; then
  [ -d "$MANAGED" ] || fail 'Existing client path is not a directory.'
  warn "Client '$NAME' already exists; replacing its record does not revoke the old certificate."
  confirm_destructive "Archive and replace client '$NAME'?" || fail 'Cancelled.'
  REPLACE=yes
else
  REPLACE=no
fi
PARENT=$(dirname -- "$DEST"); [ -d "$PARENT" ] || fail 'Output parent directory does not exist.'
line
info "CA: ca/ca.crt"
info "CSR: $CSR"
info "Output: $DEST"
info "Validity: $DAYS days"
line
confirm 'Sign this CSR?' || fail 'Cancelled.'
TMP=$(mktemp -d "$PARENT/.mtls-tmp.XXXXXXXX") || fail 'Cannot create temporary directory.'
make_ext "$TMP/extensions.cnf"
openssl x509 -req -in "$CSR" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial -out "$TMP/client.crt" -days "$DAYS" -extfile "$TMP/extensions.cnf" || fail 'Signing failed.'
openssl verify -purpose sslclient -CAfile "$CA_DIR/ca.crt" "$TMP/client.crt" >/dev/null || fail 'Verification failed.'
[ ! -e "$DEST" ] || fail 'Output appeared concurrently.'
mv "$TMP/client.crt" "$DEST" || fail 'Unable to save certificate.'
chmod 644 "$DEST"
# Keep the public certificate on the CA machine, even though the key stays with the client.
MANAGED_TMP=$(mktemp -d "$ROOT/clients/.tmp.XXXXXXXX") || fail 'Cannot stage client record.'
cp "$DEST" "$MANAGED_TMP/client.crt" || fail 'Cannot retain public certificate.'
chmod 644 "$MANAGED_TMP/client.crt"
if [ "$REPLACE" = yes ]; then
  archive_path "$ROOT/clients/backup" "$NAME"
  mv "$MANAGED" "$ARCHIVE_PATH" || fail 'Unable to archive previous client.'
fi
if ! mv "$MANAGED_TMP" "$MANAGED"; then
  if [ "$REPLACE" = yes ]; then mv "$ARCHIVE_PATH" "$MANAGED" || warn 'Restore archived client manually.'; fi
  fail 'Unable to install client record.'
fi
line; success "Certificate signed: $DEST"
info 'Transfer client.crt to the CLIENT machine (alongside client.key).'
info 'Then run: 32-adv-client-export-pkcs12.sh on the CLIENT machine.'
