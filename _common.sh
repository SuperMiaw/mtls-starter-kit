#!/bin/sh
# Shared interactive helpers. Sourced by the five entry-point scripts.

if [ -t 1 ] && [ -z "${NO_COLOR+x}" ]; then
    BLUE=$(printf '\033[34m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    RED=$(printf '\033[31m')
    RESET=$(printf '\033[0m')
else
    BLUE= GREEN= YELLOW= RED= RESET=
fi

line() { printf '%s\n' '--------------------------------------------------'; }
header() { line; printf '%s%s%s\n' "$BLUE" "$1" "$RESET"; line; }
info() { printf '%s\n' "$*"; }
warn() { printf '%sWARNING: %s%s\n' "$YELLOW" "$*" "$RESET"; }
success() { printf '%sSUCCESS: %s%s\n' "$GREEN" "$*" "$RESET"; }
fail() { printf '%sERROR: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

ask() {
    printf '%s' "$1"
    IFS= read -r ANSWER || fail 'Input cancelled.'
}

# Ordinary actions default to yes; destructive actions require explicit yes.
confirm() {
    printf '%s [Y/n]: ' "$1"
    IFS= read -r ANSWER || return 1
    case "$ANSWER" in
        ''|y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_destructive() {
    printf '%s [y/N]: ' "$1"
    IFS= read -r ANSWER || return 1
    case "$ANSWER" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

need_openssl() {
    command -v openssl >/dev/null 2>&1 || fail 'OpenSSL is required.'
    case "$RSA_BITS" in
        ''|*[!0-9]*) fail 'RSA_BITS must be a positive integer.' ;;
    esac
    [ "$RSA_BITS" -ge 2048 ] 2>/dev/null || fail 'RSA_BITS must be at least 2048.'
}

# Generate an RSA key for CA or client use.
generate_key() {
    output=$1
    encrypt=$2
    if [ "$encrypt" = yes ]; then
        openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$RSA_BITS" -aes-256-cbc -out "$output"
    else
        openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$RSA_BITS" -out "$output"
    fi
}

# One CA per checkout; generated material lives directly under ca/.
choose_ca() {
    CA_DIR="$ROOT/ca"
    [ -f "$CA_DIR/ca.key" ] && [ -f "$CA_DIR/ca.crt" ] ||
        fail 'No usable CA. Run 10-ca-create.sh first.'
    openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend 0 >/dev/null 2>&1 ||
        fail 'CA certificate expired or invalid.'
}

# Create a collision-resistant, timestamped archive path.
archive_path() {
    base=$1
    name=$2
    mkdir -p "$base"
    chmod 700 "$base"
    stamp=$(date '+%Y-%m-%d_%H-%M-%S')
    candidate="$base/${stamp}_${name}"
    n=1
    while [ -e "$candidate" ]; do
        candidate="$base/${stamp}_${name}_$n"
        n=$((n + 1))
    done
    ARCHIVE_PATH=$candidate
}

# OpenSSL permits an empty export password, but some iOS imports reject it.
# Read a password twice without echoing it; an empty password is permitted after warning.
ask_pfx_password() {
    password_file=$1
    [ -t 0 ] || fail 'A terminal is required to enter the PFX password.'
    old_stty=$(stty -g) || fail 'Cannot read terminal settings.'
    stty -echo || fail 'Cannot disable terminal echo.'
    while :; do
        printf 'PFX export password (Enter for none): '
        if ! IFS= read -r pass1; then
            stty "$old_stty"; printf '\n'; fail 'Password input cancelled.'
        fi
        printf '\nConfirm PFX export password: '
        if ! IFS= read -r pass2; then
            stty "$old_stty"; printf '\n'; fail 'Password input cancelled.'
        fi
        printf '\n'
        if [ "$pass1" != "$pass2" ]; then
            warn 'Passwords do not match.'
        elif [ -z "$pass1" ]; then
            warn 'An empty PFX password offers no password-based protection and may be rejected by some clients.'
            confirm 'Export PFX without a password?' && break
        else
            break
        fi
    done
    stty "$old_stty"
    (umask 077; printf '%s\n' "$pass1" > "$password_file") || fail 'Cannot save temporary password.'
    unset pass1 pass2
}

valid_name() {
    case "$1" in
        ''|.|..|*[!a-zA-Z0-9_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

ask_name() {
    while :; do
        ask "$1"
        valid_name "$ANSWER" && return
        warn 'Use letters, digits, dots, underscores or hyphens (not . or ..).'
    done
}

ask_cn() {
    while :; do
        ask "${1:-Client Common Name (CN), the identity exposed to the remote server: }"
        if [ -n "$ANSWER" ] && [ "${#ANSWER}" -le 128 ]; then
            case "$ANSWER" in
                *[!a-zA-Z0-9_.@-]*) ;;
                *) return ;;
            esac
        fi
        warn 'Use 1-128 letters, digits, dots, underscores, hyphens or @.'
    done
}

ask_years() {
    default=$1
    while :; do
        ask "Validity in years [$default]: "
        years=${ANSWER:-$default}
        case "$years" in
            ''|*[!0-9]*) warn 'Enter a positive whole number.' ;;
            *)
                if [ "$years" -ge 1 ] 2>/dev/null && [ "$years" -le 100 ]; then
                    return
                fi
                warn 'Enter a value from 1 to 100.'
                ;;
        esac
    done
}

verify_pair() {
    a=$(openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | openssl dgst -sha256) || return 1
    b=$(openssl x509 -in "$2" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -pubout -outform DER 2>/dev/null | openssl dgst -sha256) || return 1
    [ "$a" = "$b" ]
}

verify_client_pair() { verify_pair "$1" "$2"; }

max_days_for_ca() {
    # Limit the requested lifetime to whole days remaining on the CA.
    max=$1
    while [ "$max" -gt 0 ]; do
        secs=$((max * 86400))
        if openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend "$secs" >/dev/null 2>&1; then
            break
        fi
        max=$((max - 1))
    done
    [ "$max" -ge 1 ] || fail 'CA expires in less than one day. Renew the CA first.'
    DAYS=$max
}

make_ext() {
    cat > "$1" <<'EOF'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
}

cleanup() {
    [ -z "${TMP:-}" ] || rm -rf -- "$TMP"
}
