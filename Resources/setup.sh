#!/bin/bash
set -e

clear
printf '%s\n' "=============================================="
printf '%s\n' " SSTP Client GUI — dependency setup"
printf '%s\n' "=============================================="
printf '\n'

if [ -x /opt/homebrew/bin/brew ]; then
  BREW="/opt/homebrew/bin/brew"
elif [ -x /usr/local/bin/brew ]; then
  BREW="/usr/local/bin/brew"
else
  echo "Homebrew not found. Starting the official installer..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [ -x /opt/homebrew/bin/brew ]; then
    BREW="/opt/homebrew/bin/brew"
  elif [ -x /usr/local/bin/brew ]; then
    BREW="/usr/local/bin/brew"
  else
    echo "ERROR: Homebrew installation was not detected."
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
  fi
fi

printf '\n[1/3] Homebrew\n'
"$BREW" --version | head -1

printf '\n[2/3] SSTP Client GUI components\n'
echo "Installing the private SSTP build with password and certificate fixes."
echo "The existing Homebrew sstp-client installation will remain available."
"$BREW" tap tolabzik/sstp-client-gui https://github.com/tolabzik/sstp_client_gui_mac_os.git
FORMULA=tolabzik/sstp-client-gui/sstp-client-gui
"$BREW" install "$FORMULA"

printf '\n[3/3] PPP\n'
sudo mkdir -p /etc/ppp
sudo touch /etc/ppp/options

SSTPC="$("$BREW" --prefix "$FORMULA")/sbin/sstpc"

printf '\nVerification:\n'
VERSION_OUTPUT="$("$SSTPC" --version 2>&1)"
printf '%s\n' "$VERSION_OUTPUT"
# The GUI copies this script to a standalone .command file in /tmp. Keep the
# capability check self-contained rather than sourcing a neighboring resource.
if ! printf '%s\n' "$VERSION_OUTPUT" | /usr/bin/grep -Eq '(^|[[:space:]])sstp-gui-fixes-1([[:space:]]|$)'; then
  echo "ERROR: the installed SSTP component does not include the required GUI fixes."
  exit 1
fi
ls -l /usr/sbin/pppd /etc/ppp/options

printf '\nSetup completed. Return to the app and press Check again.\n\n'
read -n 1 -s -r -p "Press any key to close..."
