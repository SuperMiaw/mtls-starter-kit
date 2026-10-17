#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$ROOT/config.sh"
. "$ROOT/_common.sh"
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

header 'CREATE CERTIFICATE AUTHORITY (CA)'
need_openssl
mkdir -p "$ROOT/ca" "$ROOT/clients"
chmod 700 "$ROOT/ca" "$ROOT/clients"
CA_DIR="$ROOT/ca"
if [ -e "$CA_DIR/ca.key" ] || [ -e "$CA_DIR/ca.crt" ]; then
  [ -f "$CA_DIR/ca.key" ] && [ -f "$CA_DIR/ca.crt" ] || fail 'Incomplete CA files; resolve manually.'
  warn 'Replacing this CA changes the trust identity. Existing clients must be reissued after Nginx trusts the new CA.'
  warn 'The previous CA and all managed clients will be archived together.'
  confirm_destructive 'Replace the existing CA?' || fail 'Cancelled.'
  REPLACE=yes
else
  REPLACE=no
fi
ask_cn 'Certificate Authority name (CN): '
CN=$ANSWER
ask 'Password-protect CA private key? (recommended) [Y/n]: '
case "$ANSWER" in n|N|no|NO) ENCRYPT=no;; *) ENCRYPT=yes;; esac
ask_years 10
DAYS=$((years * 365))
line
info "CA CN: $CN"
info "Key encryption: $ENCRYPT"
info "Validity: $years years ($DAYS days)"
confirm 'Proceed with CA generation?' || fail 'Cancelled.'
TMP=$(mktemp -d "$ROOT/.mtls-ca-tmp.XXXXXXXX") || fail 'Cannot create temporary directory.'
chmod 700 "$TMP"
generate_key "$TMP/ca.key" "$ENCRYPT" || fail 'Key generation failed.'
openssl req -new -x509 -key "$TMP/ca.key" -out "$TMP/ca.crt" -days "$DAYS" -subj "/CN=$CN" -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -addext 'subjectKeyIdentifier=hash' || fail 'CA certificate generation failed.'
chmod 600 "$TMP/ca.key"
chmod 644 "$TMP/ca.crt"
verify_pair "$TMP/ca.key" "$TMP/ca.crt" || fail 'CA key/certificate mismatch.'
openssl verify -CAfile "$TMP/ca.crt" "$TMP/ca.crt" >/dev/null || fail 'CA verification failed.'
if [ "$REPLACE" = yes ]; then
  archive_path "$CA_DIR/backup" ca
  CA_BACKUP=$ARCHIVE_PATH
  mkdir "$CA_BACKUP" || fail 'Unable to create CA archive.'
  chmod 700 "$CA_BACKUP"
  # The corresponding clients are stored under the same generation identifier.
  CLIENT_BACKUP="$ROOT/clients/backup/${CA_BACKUP##*/}"
  mkdir -p "$ROOT/clients/backup"
  chmod 700 "$ROOT/clients/backup"
  mkdir "$CLIENT_BACKUP" || fail 'Unable to create client archive.'
  chmod 700 "$CLIENT_BACKUP"
  for f in "$CA_DIR/ca.key" "$CA_DIR/ca.crt" "$CA_DIR/ca.srl"; do
    [ ! -e "$f" ] || mv "$f" "$CA_BACKUP/" || fail 'Unable to archive CA file.'
  done
  for d in "$ROOT"/clients/*; do
    [ -e "$d" ] || continue
    [ "${d##*/}" = backup ] && continue
    mv "$d" "$CLIENT_BACKUP/" || fail 'Unable to archive clients.'
  done
fi
# Roll back the CA on installation failure; client archive is retained for recovery.
if ! mv "$TMP/ca.key" "$CA_DIR/ca.key" || ! mv "$TMP/ca.crt" "$CA_DIR/ca.crt"; then
  if [ "$REPLACE" = yes ]; then
    rm -f "$CA_DIR/ca.key" "$CA_DIR/ca.crt"
    for f in "$CA_BACKUP"/*; do [ ! -e "$f" ] || mv "$f" "$CA_DIR/" || :; done
    for d in "$CLIENT_BACKUP"/*; do [ ! -e "$d" ] || mv "$d" "$ROOT/clients/" || :; done
  fi
  fail 'Unable to install CA.'
fi
rmdir -- "$TMP" || fail 'Unable to remove empty CA temporary directory.'
TMP=''
line
success 'CA created: ca/ca.crt'
[ "$REPLACE" != yes ] || info "Previous generation archived: ca/backup/${CA_BACKUP##*/} and clients/backup/${CA_BACKUP##*/}"
info 'Copy ca/ca.crt to servers that trust this CA; never distribute ca/ca.key.'
