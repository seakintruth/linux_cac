#!/usr/bin/env bash
# cac_setup.sh
# Description: Setup a Linux environment for Common Access Card use.

set -euo pipefail

main ()
{
    EXIT_SUCCESS=0
    E_NOTROOT=86
    E_CERTS=89
    DWNLD_DIR="$(mktemp -d)"
    trap 'rm -rf "$DWNLD_DIR"' EXIT

    chrome_exists=false
    ff_exists=false
    snap_ff=false
    ff_profile_dir=""

    ORIG_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    DB_FILENAME="cert9.db"
    DL_BASE="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip"
    WORK_DIR="$DWNLD_DIR/linux_cac_certs"
    PEM_DIR="$WORK_DIR/pems"
    UNIQUE_DIR="$WORK_DIR/unique"

    root_check
    select_bundles
    browser_check
    mapfile -t databases < <(find "$ORIG_HOME" -name "$DB_FILENAME" 2>/dev/null | grep "firefox\|pki" | grep -v "Trash")
    SKIP_CERT_IMPORT=false
    if [ "${#databases[@]}" -eq 0 ]
    then
        print_warn "No valid databases located. Try running, then closing Firefox, then start this script again."
        print_warn "Continuing without importing certificates into any browser profile."
        SKIP_CERT_IMPORT=true
    fi

    print_info "Installing middleware and essential utilities..."
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y libpcsclite1 pcscd libccid libpcsc-perl pcsc-tools libnss3-tools unzip wget openssl opensc
    print_info "Done"

    rm -rf "$WORK_DIR"
    mkdir -p "$PEM_DIR" "$UNIQUE_DIR"

    local key
    for key in "${SELECTED_BUNDLES[@]}"
    do
        fetch_and_extract_bundle "$key"
    done
    dedupe_pems

    if [ "$SKIP_CERT_IMPORT" != true ]
    then
        for db in "${databases[@]}"
        do
            if [ -n "$db" ]
            then
                import_certs "$db"
            fi
        done
    else
        print_warn "Skipping certificate import (no usable browser database)."
    fi

    print_info "Enabling pcscd service to start on boot..."
    systemctl enable pcscd.socket
    print_info "Done"

    if [ "$snap_ff" == true ]
    then
        print_info "Connecting snapped Firefox to the pcscd socket..."
        if ! snap connect firefox:pcscd
        then
            print_warn "Failed to connect. Try upgrading with 'apt upgrade' and 'snap refresh' first."
            print_warn "Continuing without the pcscd snap connection."
        fi
        print_info "Registering the pkcs11 module..."
        sudo -H -u "$SUDO_USER" modutil -dbdir "sql:$ff_profile_dir" \
            -add "CAC Module" -libfile /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so -force
    else
        print_info "Registering CAC module with PKSC11..."
        pkcs11-register
        print_info "Done"
    fi

    print_info "Done. A reboot may be required."
    exit "$EXIT_SUCCESS"
}

print_err ()
{
    ERR_COLOR='\033[0;31m'
    NO_COLOR='\033[0m'
    echo -e "${ERR_COLOR}[ERROR]${NO_COLOR} $1"
}

print_info ()
{
    INFO_COLOR='\033[0;33m'
    NO_COLOR='\033[0m'
    echo -e "${INFO_COLOR}[INFO]${NO_COLOR} $1"
}

print_warn ()
{
    WARN_COLOR='\033[1;33m'
    NO_COLOR='\033[0m'
    echo -e "${WARN_COLOR}[WARN]${NO_COLOR} $1"
}

root_check ()
{
    local ROOT_UID=0
    if [ "${EUID:-$(id -u)}" -ne "$ROOT_UID" ]n    then
        print_err "This script must run as root to install packages and import trusted certificates."
        print_warn "Re-run with sudo."
        exit "$E_NOTROOT"
    fi
}

bundle_filename ()
{
    case "$1" in
        dod) echo "unclass-certificates_pkcs7_DoD.zip" ;;
        eca) echo "unclass-certificates_pkcs7_ECA.zip" ;;
        wcf) echo "certificates_pkcs7_WCF.zip" ;;
        external) echo "unclass-dod_approved_external_pkis_trust_chains.zip" ;;
        *) echo "" ;;
    esac
}

select_bundles ()
{
    SELECTED_BUNDLES=(dod)
    local choice raw item

    if [ -n "${CAC_BUNDLES:-}" ]
    then
        raw="$(echo "$CAC_BUNDLES" | tr '[:upper:]' '[:lower:]' | tr ',' ' ')"
        for item in $raw
        do
            case "$item" in
                dod) ;;
                eca|wcf|external) SELECTED_BUNDLES+=("$item") ;;
                all) SELECTED_BUNDLES=(dod eca wcf external) ;;
            esac
        done
        print_info "Bundles from CAC_BUNDLES: ${SELECTED_BUNDLES[*]}"
        return
    fi

    if [ ! -r /dev/tty ]
    then
        print_info "No TTY; installing DoD PKI only. Set CAC_BUNDLES=all (or eca,external,wcf) to add more."
        return
    fi

    echo
    echo "linux_cac: choose CA bundles first."
    echo "DoD PKI CAs are always installed (required for CAC)."
    echo "Also install other public Cyber Exchange CA bundles?"
    echo "  [1] No - DoD only (default)"
    echo "  [2] ECA (contractor External Certification Authority)"
    echo "  [3] External partner trust chains (federal / approved PKIs)"
    echo "  [4] WCF B&I"
    echo "  [5] All public CA zips (DoD + ECA + External + WCF)"
    echo "JITC test PKI is not offered."
    echo "Close Firefox and Chrome if they are open, then answer."
    echo
    printf "Enter 1-5, or a comma list (e.g. 2,3): " > /dev/tty
    IFS= read -r choice < /dev/tty || choice="1"
    choice="${choice:-1}"

    raw="$(echo "$choice" | tr ',' ' ')"
    for item in $raw
    do
        case "$item" in
            1|dod) ;;
            2|eca) SELECTED_BUNDLES+=(eca) ;;
            3|external) SELECTED_BUNDLES+=(external) ;;
            4|wcf) SELECTED_BUNDLES+=(wcf) ;;
            5|all) SELECTED_BUNDLES=(dod eca wcf external) ;;
        esac
    done
    print_info "Bundles selected: ${SELECTED_BUNDLES[*]}"
}

download_zip ()
{
    local url="$1"
    local dest="$2"
    print_info "Downloading $url"
    if wget -qO "$dest" "$url"
    then
        :
    else
        print_info "TLS check failed. Retrying this bootstrap download without certificate verification."
        wget --no-check-certificate -qO "$dest" "$url" || return 1
    fi
    [ -s "$dest" ]
}

fetch_and_extract_bundle ()
{
    local key="$1"
    local zip_name dest extract_dir combined inform p7
    zip_name="$(bundle_filename "$key")"
    if [ -z "$zip_name" ]
    then
        print_err "Unknown bundle key: $key"
        return
    fi
    dest="$WORK_DIR/$zip_name"
    extract_dir="$WORK_DIR/$key"
    mkdir -p "$extract_dir"

    if ! download_zip "$DL_BASE/$zip_name" "$dest"
    then
        print_err "Failed to download $key bundle; skipping."
        return
    fi

    unzip -qo "$dest" -d "$extract_dir"
    combined="$extract_dir/combined.pem"
    : > "$combined"

    mapfile -t p7s < <(find "$extract_dir" -type f \( -iname '*.p7b' -o -iname '*.p7c' \) | sort)
    if [ "${#p7s[@]}" -eq 0 ]
    then
        print_err "No PKCS#7 files in $key zip; skipping."
        return
    fi

    print_info "Extracting ${#p7s[@]} PKCS#7 file(s) from $key..."
    for p7 in "${p7s[@]}"
    do
        inform="PEM"
        if ! grep -q "BEGIN" "$p7" 2>/dev/null
        then
            inform="DER"
        fi
        openssl pkcs7 -in "$p7" -inform "$inform" -print_certs >> "$combined" 2>/dev/null \
            || print_info "Skipping unreadable PKCS#7: $p7"
    done

    awk -v out="$PEM_DIR" -v prefix="$key" '
        /-----BEGIN CERTIFICATE-----/ { n++; f=sprintf("%s/%s-%03d.pem", out, prefix, n) }
        f { print > f }
    ' "$combined"
}

dedupe_pems ()
{
    local cert fp dest count_in count_out
    count_in="$(find "$PEM_DIR" -name '*.pem' | wc -l)"
    for cert in "$PEM_DIR"/*.pem
    do
        [ -f "$cert" ] || continue
        fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//;s/://g')"
        if [ -z "$fp" ]
        then
            continue
        fi
        dest="$UNIQUE_DIR/${fp}.pem"
        if [ ! -f "$dest" ]
        then
            cp "$cert" "$dest"
        fi
    done
    count_out="$(find "$UNIQUE_DIR" -name '*.pem' | wc -l)"
    print_info "Deduped $count_in extracted PEMs down to $count_out unique certificates."
    if [ "$count_out" -eq 0 ]
    then
        print_err "No unique certificates to import."
        exit "$E_CERTS"
    fi
}

run_firefox ()
{
    print_info "Starting Firefox silently to complete post-install actions..."
    sudo -H -u "$SUDO_USER" firefox --headless --first-startup >/dev/null 2>&1 &
    FF_PID=$!
    sleep 3
    stop_browser "$FF_PID"
    sleep 1
}

stop_browser ()
{
    local pid=$1
    local waited=0
    local GRACE_SECONDS=10
    if [ -z "${pid:-}" ]; then
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null
    then
        kill -TERM "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$GRACE_SECONDS" ]
        do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null
        then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
}

run_chrome ()
{
    print_info "Running Chrome to ensure it has completed post-install actions..."
    sudo -H -u "$SUDO_USER" google-chrome --headless --disable-gpu >/dev/null 2>&1 &
    CHROME_PID=$!
    sleep 3
    stop_browser "$CHROME_PID"
    sleep 1
    print_info "Done."
}

browser_check ()
{
    print_info "Checking for Firefox and Chrome..."
    check_for_firefox
    check_for_chrome
    if [ "$ff_exists" == false ] && [ "$chrome_exists" == false ]
    then
        print_warn "No version of Mozilla Firefox OR Google Chrome has been detected."
        print_warn "Certificate import will be skipped for browsers. Continuing with middleware install."
    fi
}

check_for_firefox ()
{
    if command -v firefox >/dev/null
        then
            print_info "Running Firefox to generate profile directory..."
            run_firefox
            print_info "Done."
            ff_exists=true
            db_location="$(find "$ORIG_HOME" -name "$DB_FILENAME" 2>/dev/null | grep "firefox" | grep -v "Trash")"
            ff_profile_dir="$(dirname "$db_location")"
            print_info "Found Firefox with profile in ${ff_profile_dir}"
            if command -v firefox | grep snap >/dev/null
            then
                snap_ff=true
                print_info "This version of Firefox was installed as a snap package"
            elif command -v firefox | xargs grep -Fq "exec /snap/bin/firefox"
            then
                snap_ff=true
                print_info "This version of Firefox was installed as a snap package with a launch script"
            else
                print_info "This is not a snap-installed version of Firefox."
            fi
        else
            print_info "Firefox not found."
        fi
}

check_for_chrome ()
{
    if command -v google-chrome >/dev/null
    then
        chrome_exists=true
        print_info "Found Google Chrome."
        run_chrome
    else
        print_info "Chrome not found."
    fi
}

import_certs ()
{
    db=$1
    db_root="$(dirname "$db")"
    if [ -n "$db_root" ]
    then
        case "$db_root" in
            *"pki"*)
                print_info "Importing unique certificates for Chrome..."
                echo
                ;;
            *"firefox"*)
                print_info "Importing unique certificates for Firefox..."
                echo
                ;;
        esac
        print_info "Loading certificates into $db_root "
        echo
        local cert nick added skipped
        added=0
        skipped=0
        for cert in "$UNIQUE_DIR"/*.pem
        do
            [ -f "$cert" ] || continue
            nick="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')"
            if [ -z "$nick" ]
            then
                nick="$(basename "$cert")"
            fi
            if certutil -d sql:"$db_root" -L -n "$nick" >/dev/null 2>&1
            then
                skipped=$((skipped + 1))
                continue
            fi
            if certutil -d sql:"$db_root" -A -t TC -n "$nick" -i "$cert" 2>/dev/null
            then
                echo "Imported $nick"
                added=$((added + 1))
            else
                print_info "Skipped $nick"
                skipped=$((skipped + 1))
            fi
        done
        print_info "Imported $added, skipped $skipped (already present or failed)."
    fi
    print_info "Done."
    echo
}

main
