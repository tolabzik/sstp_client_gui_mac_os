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

printf '\n[2/3] sstp-client\n'
"$BREW" install sstp-client

printf '\n[3/3] PPP\n'
sudo mkdir -p /etc/ppp
sudo touch /etc/ppp/options

SSTPC="$($BREW --prefix)/sbin/sstpc"

printf '\nVerification:\n'
"$SSTPC" --version
ls -l /usr/sbin/pppd /etc/ppp/options

printf '\nSetup completed. Return to the app and press Check again.\n\n'
read -n 1 -s -r -p "Press any key to close..."
