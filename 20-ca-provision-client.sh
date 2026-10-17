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

header 'PROVISION CLIENT — SIMPLE WORKFLOW'
info 'Run on the TRUSTED machine. This creates a client private key here.'
need_openssl
choose_ca
ask_name 'Client directory name: '; NAME=$ANSWER
mkdir -p "$ROOT/clients"
chmod 700 "$ROOT/clients"
[ "$NAME" != backup ] || fail 'Reserved client name.'
DEST="$ROOT/clients/$NAME"
if [ -e "$DEST" ]; then
  [ -d "$DEST" ] || fail 'Existing client path is not a directory.'
  warn "Client '$NAME' exists. A new certificate does not revoke the old one."
  confirm_destructive "Regenerate and archive client '$NAME'?" || fail 'Cancelled.'
  REPLACE=yes
else
  REPLACE=no
fi
ask_cn
CN=$ANSWER
ask_years 2
[ "$years" -le 2 ] || warn 'Long-lived client certificates increase exposure if a client key is stolen.'
REQUEST_DAYS=$((years * 365))
max_days_for_ca "$REQUEST_DAYS"
[ "$DAYS" -eq "$REQUEST_DAYS" ] || warn "Validity reduced to $DAYS days to remain within CA expiry."
ask 'Password-protect client.key? [y/N]: '
case "$ANSWER" in y|Y|yes|YES) ENCRYPT=yes;; *) ENCRYPT=no;; esac
line
info "CA: ca/ca.crt"
info "Client CN: $CN"
info "Destination: clients/$NAME"
info "Validity: $DAYS days"
info "Private key encryption: $ENCRYPT"
line
confirm 'Generate client certificate and PFX?' || fail 'Cancelled.'
TMP=$(mktemp -d "$ROOT/clients/.tmp.XXXXXXXX") || fail 'Cannot create temporary directory.'
chmod 700 "$TMP"
generate_key "$TMP/client.key" "$ENCRYPT" || fail 'Key generation failed.'
openssl req -new -key "$TMP/client.key" -out "$TMP/client.csr" -subj "/CN=$CN" || fail 'CSR generation failed.'
make_ext "$TMP/extensions.cnf"
openssl x509 -req -in "$TMP/client.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial -out "$TMP/client.crt" -days "$DAYS" -extfile "$TMP/extensions.cnf" || fail 'Signing failed.'
verify_client_pair "$TMP/client.key" "$TMP/client.crt" || fail 'Client key/certificate mismatch.'
openssl verify -purpose sslclient -CAfile "$CA_DIR/ca.crt" "$TMP/client.crt" >/dev/null || fail 'Client certificate verification failed.'
ask_pfx_password "$TMP/pfx-password"
openssl pkcs12 -export -out "$TMP/client.pfx" -inkey "$TMP/client.key" -in "$TMP/client.crt" -certfile "$CA_DIR/ca.crt" -passout file:"$TMP/pfx-password" || fail 'PKCS#12 export failed.'
rm -f "$TMP/extensions.cnf" "$TMP/pfx-password"
chmod 600 "$TMP/client.key" "$TMP/client.pfx"
chmod 644 "$TMP/client.csr" "$TMP/client.crt"
if [ "$REPLACE" = yes ]; then
  archive_path "$ROOT/clients/backup" "$NAME"
  mv "$DEST" "$ARCHIVE_PATH" || fail 'Unable to archive previous client.'
fi
if ! mv "$TMP" "$DEST"; then
  if [ "$REPLACE" = yes ]; then mv "$ARCHIVE_PATH" "$DEST" || warn 'Restore the client from backup manually.'; fi
  fail 'Unable to install client directory.'
fi
TMP=''
line; success "Client created: clients/$NAME"
info 'Import client.pfx on the client device (use the chosen export password, if any).'
warn 'client.key and client.pfx contain sensitive private key material. Transfer securely.'
