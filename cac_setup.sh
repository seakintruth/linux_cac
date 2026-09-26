#!/usr/bin/env bash

# cac_setup.sh
# Description: Setup a Linux environment for Common Access Card use.

main ()
{
    EXIT_SUCCESS=0                      # Success exit code
    E_NOTROOT=86                        # Non-root exit error
    E_BROWSER=87                        # Browser-related error (e.g. no browser installed)
    E_DATABASE=88                       # No database located
    E_CERTS=89                          # Certificate download/extract error
    DWNLD_DIR="/tmp"                    # Location to place artifacts

    chrome_exists=false                 # Google Chrome is installed
    ff_exists=false                     # Firefox is installed
    snap_ff=false                       # Snapped Firefox
    ff_profile_dir=""                   # Firefox profile directory

    ORIG_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    DB_FILENAME="cert9.db"
    # Public Cyber Exchange PKCS#7 zip (version is inside the archive, not the URL).
    # Catalog: https://www.cyber.mil/pki-pke/tools-configuration-files
    CERT_FILENAME="DoD_PKCS7"
    BUNDLE_FILENAME="unclass-certificates_pkcs7_DoD.zip"
    CERT_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/${BUNDLE_FILENAME}"
    PEM_DIR="$DWNLD_DIR/$CERT_FILENAME/pems"

    root_check
    browser_check
    mapfile -t databases < <(find "$ORIG_HOME" -name "$DB_FILENAME" 2>/dev/null | grep "firefox\|pki" | grep -v "Trash")
    # Check if databases were found properly
    if [ "${#databases[@]}" -eq 0 ]
    then
        print_err "No valid databases located. Try running, then closing Firefox, then start this script again."
        echo -e "\tExiting..."

        exit "$E_DATABASE"
    fi

    # Install middleware and necessary utilities
    print_info "Installing middleware and essential utilities..."
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y libpcsclite1 pcscd libccid libpcsc-perl pcsc-tools libnss3-tools unzip wget openssl opensc
    print_info "Done"

    download_dod_bundle
    extract_dod_pems

    # Import certificates into cert9.db databases for browsers
    for db in "${databases[@]}"
    do
        if [ -n "$db" ]
        then
            import_certs "$db"
        fi
    done

    print_info "Enabling pcscd service to start on boot..."
    systemctl enable pcscd.socket
    print_info "Done"

    # Handle snapped firefox
    if [ "$snap_ff" == true ]
    then
        print_info "Connecting snapped Firefox to the pcscd socket..."
        if ! snap connect firefox:pcscd
        then
            print_err "Failed to connect. Try upgrading with 'apt upgrade' and 'snap refresh' first."
            exit "$E_BROWSER"
        fi

        print_info "Registering the pkcs11 module..."
        sudo -H -u "$SUDO_USER" modutil -dbdir "sql:$ff_profile_dir" \
            -add "CAC Module" -libfile /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so -force
    else
        print_info "Registering CAC module with PKSC11..."
        pkcs11-register
        print_info "Done"
    fi


    # Remove artifacts
    print_info "Removing artifacts..."
    rm -rf "${DWNLD_DIR:?}"/{"$BUNDLE_FILENAME","$CERT_FILENAME"} 2>/dev/null
    if [ "$?" -ne "$EXIT_SUCCESS" ]
    then
        print_err "Failed to remove artifacts. Artifacts were stored in ${DWNLD_DIR}."
    else
        print_info "Done. A reboot may be required."
    fi

    exit "$EXIT_SUCCESS"
} # main


# Prints message with red [ERROR] tag before the message
print_err ()
{
    ERR_COLOR='\033[0;31m'  # Red for error messages
    NO_COLOR='\033[0m'      # Revert terminal back to no color
    echo -e "${ERR_COLOR}[ERROR]${NO_COLOR} $1"
} # print_err


# Prints message with yellow [INFO] tag before the message
print_info ()
{
    INFO_COLOR='\033[0;33m' # Yellow for notes
    NO_COLOR='\033[0m'      # Revert terminal back to no color
    echo -e "${INFO_COLOR}[INFO]${NO_COLOR} $1"
} # print_info


# Check to ensure the script is executed as root
root_check ()
{
    # Only users with $UID 0 have root privileges
    local ROOT_UID=0

    # Ensure the script is ran as root
    if [ "${EUID:-$(id -u)}" -ne "$ROOT_UID" ]
    then
        print_err "Please run this script as root."
        exit "$E_NOTROOT"
    fi
} # root_check


download_dod_bundle ()
{
    print_info "Downloading DoD PKCS#7 bundle from Cyber Exchange..."
    print_info "$CERT_URL"
    if ! wget -qO "$DWNLD_DIR/$BUNDLE_FILENAME" "$CERT_URL"
    then
        print_info "TLS check failed (host may use DoD PKI). Retrying without certificate verification for this bootstrap download only."
        if ! wget --no-check-certificate -qO "$DWNLD_DIR/$BUNDLE_FILENAME" "$CERT_URL"
        then
            print_err "Failed to download $CERT_URL"
            exit "$E_CERTS"
        fi
    fi
    if [ ! -s "$DWNLD_DIR/$BUNDLE_FILENAME" ]
    then
        print_err "Downloaded bundle is empty."
        exit "$E_CERTS"
    fi
    print_info "Done."
} # download_dod_bundle


# Convert DISA PKCS#7 files into individual PEM certs for certutil.
extract_dod_pems ()
{
    mkdir -p "$DWNLD_DIR/$CERT_FILENAME" "$PEM_DIR"
    unzip -qo "$DWNLD_DIR/$BUNDLE_FILENAME" -d "$DWNLD_DIR/$CERT_FILENAME"

    local p7 combined inform
    combined="$DWNLD_DIR/$CERT_FILENAME/combined.pem"
    : > "$combined"

    mapfile -t p7s < <(find "$DWNLD_DIR/$CERT_FILENAME" -type f \( -iname '*.p7b' -o -iname '*.p7c' \) | sort)
    if [ "${#p7s[@]}" -eq 0 ]
    then
        print_err "No PKCS#7 files found in the DoD zip."
        exit "$E_CERTS"
    fi

    print_info "Extracting certificates from ${#p7s[@]} PKCS#7 file(s)..."
    for p7 in "${p7s[@]}"
    do
        inform="PEM"
        if ! grep -q "BEGIN" "$p7" 2>/dev/null
        then
            inform="DER"
        fi
        if ! openssl pkcs7 -in "$p7" -inform "$inform" -print_certs >> "$combined" 2>/dev/null
        then
            print_info "Skipping unreadable PKCS#7: $p7"
        fi
    done

    if ! grep -q "BEGIN CERTIFICATE" "$combined"
    then
        print_err "openssl produced no certificates from the DoD bundle."
        exit "$E_CERTS"
    fi

    # Split concatenated PEM into cert-000.pem, cert-001.pem, ...
    awk -v out="$PEM_DIR" '
        /-----BEGIN CERTIFICATE-----/ { n++; f=sprintf("%s/cert-%03d.pem", out, n) }
        f { print > f }
    ' "$combined"

    local count
    count="$(find "$PEM_DIR" -name 'cert-*.pem' | wc -l)"
    print_info "Prepared $count PEM certificates."
    if [ "$count" -eq 0 ]
    then
        exit "$E_CERTS"
    fi
} # extract_dod_pems


# Run Firefox to ensure the profile directory has been created
run_firefox ()
{
    print_info "Starting Firefox silently to complete post-install actions..."
    sudo -H -u "$SUDO_USER" firefox --headless --first-startup >/dev/null 2>&1 &
    sleep 3
    pkill -9 firefox
    sleep 1
} # run_firefox


# Run Chrome to ensure .pki directory has been created
run_chrome ()
{
    print_info "Running Chrome to ensure it has completed post-install actions..."
    sudo -H -u "$SUDO_USER" google-chrome --headless --disable-gpu >/dev/null 2>&1 &
    sleep 3
    pkill -9 google-chrome
    sleep 1
    print_info "Done."
} # run_chrome


# Discovery of browsers installed on the user's system
# Sets appropriate flags to control the flow of the installation, depending on
# what is needed for the individual user
browser_check ()
{
    print_info "Checking for Firefox and Chrome..."
    check_for_firefox
    check_for_chrome

    # Browser check results
    if [ "$ff_exists" == false ] && [ "$chrome_exists" == false ]
    then
        print_err "No version of Mozilla Firefox OR Google Chrome has been detected."
        print_info "Please install either or both to proceed."
        exit "$E_BROWSER"
    fi
} # browser_check


# Attempt to find an installed version of Firefox on the user's system
# Determines whether the version is installed via snap or apt
check_for_firefox ()
{
    if command -v firefox >/dev/null
        then
            # Run Firefox to ensure .mozilla directory has been created
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
} # check_for_firefox


# Attempt to find a version of Google Chrome installed on the user's system
check_for_chrome ()
{
    # Check to see if Chrome exists
    if command -v google-chrome >/dev/null
    then
        chrome_exists=true
        print_info "Found Google Chrome."
        # Run Chrome to ensure .pki directory has been created
        run_chrome
    else
        print_info "Chrome not found."
    fi
} # check_for_chrome


# Integrate all certificates into the databases for existing browsers
import_certs ()
{
    db=$1
    db_root="$(dirname "$db")"
    if [ -n "$db_root" ]
    then
        case "$db_root" in
            *"pki"*)
                print_info "Importing certificates for Chrome..."
                echo
                ;;
            *"firefox"*)
                print_info "Importing certificates for Firefox..."
                echo
                ;;
        esac

        print_info "Loading certificates into $db_root "
        echo

        local cert nick
        for cert in "$PEM_DIR"/cert-*.pem
        do
            [ -f "$cert" ] || continue
            nick="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')"
            if [ -z "$nick" ]
            then
                nick="$(basename "$cert")"
            fi
            echo "Importing $nick"
            certutil -d sql:"$db_root" -A -t TC -n "$nick" -i "$cert" || print_info "Already present or skipped: $nick"
        done
    fi

    print_info "Done."
    echo
} # import_certs


main
