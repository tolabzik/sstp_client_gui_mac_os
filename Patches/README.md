# SSTP dependency fixes

`sstp-client-1.0.20-gui.patch` applies to the official sstp-client 1.0.20 release
archive, SHA-256 `6c84b6cdcc21ebea6daeb8c5356dcdfd8681f4981a734f8485ed0b31fc30aadd`.
The same patch is embedded in `Formula/sstp-client-gui.rb`; tests enforce equality.

The patch escapes only the pppd options-file representation of the password,
uses a dynamically sized buffer, and handles short writes and file errors.
The original password remains the input to MPPE key derivation. It also enables
both chain and hostname verification on the certificate from the SSTP TLS
connection, using OpenSSL DNS/IP SAN matching. The app recognizes this build
by the exact `sstp-gui-fixes-1` token in `sstpc --version`.

Source: [sstp-client upstream](https://gitlab.com/sstp-project/sstp-client/-/tree/1.0.20).
The dependency and this derivative patch are distributed under GPL-2.0-or-later;
the upstream license is included as `COPYING`. This notice applies to the
dependency patch, not a relicensing of unrelated application files.

## Validation

```bash
bash Tests/run.sh
bash Tests/upstream.sh
```

The second command downloads and verifies the source archive, applies the patch
in a temporary directory, then tests the actual modified C functions. It needs
Python 3, a C compiler and OpenSSL 3 (`OPENSSL_PREFIX` can override its location).
An existing archive can be supplied as the first argument for offline use.
It does not connect to a VPN or modify routes. TLS handshakes use memory BIOs.
CI also builds and tests the Homebrew formula from the current checkout.

Two live connect/disconnect cycles passed, including traffic and DNS/route cleanup.
Dedicated live tests for quoted/backslash passwords, a nonstandard server port,
verified TLS and watchdog cleanup remain in [issue #3](https://github.com/tolabzik/sstp_client_gui_mac_os/issues/3),
along with investigation of one intermittent Full Tunnel route-check failure.

## Test a development checkout

For dependency development, use a local checkout as the tap source (replace the path below):

```bash
brew tap --custom-remote tolabzik/sstp-client-gui /absolute/path/to/sstp_client_gui_mac_os
brew install tolabzik/sstp-client-gui/sstp-client-gui
brew test tolabzik/sstp-client-gui/sstp-client-gui
```

After testing, switch the tap back to its normal remote:

```bash
brew tap --custom-remote tolabzik/sstp-client-gui https://github.com/tolabzik/sstp_client_gui_mac_os.git
```

This is a separate keg; the standard Homebrew `sstp-client` remains installed.
The app falls back to it with protective restrictions if the fixed component
is unavailable. Installing a development formula is separate from building the app.
