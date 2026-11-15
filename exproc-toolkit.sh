#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
cd /

usage() {
  echo 'Usage: sudo bash exproc-toolkit.sh [usb-reset | change-password | change-master-password]'
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help && $# == 1 ]]; then
  usage
  exit 0
fi
(( $# <= 1 )) || { usage; exit 2; }
(( EUID == 0 )) || die 'Run this toolkit with sudo.'

action=${1:-}
if [[ -z $action ]]; then
  printf '%s\n' '1. Reset USB access after an exam' '2. Change proctor password' '3. Change master password'
  read -r -p 'Choose an option: ' choice </dev/tty
  case "$choice" in
    1) action=usb-reset ;;
    2) action=change-password ;;
    3) action=change-master-password ;;
    *) die 'Choose 1, 2, or 3.' ;;
  esac
fi
case "$action" in
  usb-reset|change-password|change-master-password) ;;
  *) usage; exit 2 ;;
esac

conf=/etc/exam-suite
[[ -d $conf ]] || die 'Install the exam suite with setup.sh first.'
exec 9>"$conf/lock"
flock -n 9 || die 'Another exam command is running.'

if [[ $action == usb-reset ]]; then
  [[ ! -e /var/lib/exam-suite/active ]] ||
    die 'End the exam with sudo exam-stop before resetting USB access.'
  for unit in exam-lockdown.service exam-monitor.service; do
    if systemctl is-active --quiet "$unit"; then
      die "End the active lockdown before resetting USB access ($unit)."
    fi
  done
  systemctl disable --now usbguard.service
  # Set defaults first so devices connected during recovery are authorized too.
  found=no
  for setting in /sys/bus/usb/devices/usb*/authorized_default; do
    [[ -f $setting ]] || continue
    printf '1\n' >"$setting" || die "Could not reset $setting."
    interface_default=${setting%/*}/interface_authorized_default
    if [[ -f $interface_default ]]; then
      printf '1\n' >"$interface_default" || die "Could not reset $interface_default."
    fi
    found=yes
  done
  [[ $found == yes ]] || die 'No USB controllers were found.'
  failed=no
  for setting in /sys/bus/usb/devices/*/authorized; do
    [[ -f $setting ]] || continue
    # Skip interface attributes. The device-level authorization configures them.
    device=${setting%/authorized}
    [[ ${device##*/} != *:* ]] || continue
    if ! printf '1\n' >"$setting" && [[ -e $setting ]]; then
      failed=yes
    fi
  done
  [[ $failed == no ]] || die 'Some connected USB devices could not be authorized. Reconnect them.'
  echo 'Connected USB devices are authorized and new devices are allowed by default.'
  exit 0
fi

[[ -t 0 ]] || die 'Open a terminal to change the password.'
/usr/bin/python3 -I - "$action" "$conf/passwords" <<'PYTHON'
import getpass
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile

action, credentials = sys.argv[1:]
path = Path(credentials)
entries = path.read_text(encoding="ascii").splitlines()
if len(entries) != 2 or not all(
    re.fullmatch(r"[0-9a-f]{32} [0-9a-f]{64}", entry) for entry in entries
):
    sys.exit("Expected the two-password format created by setup.sh.")

index, label = (0, "proctor") if action == "change-password" else (1, "master")
password = getpass.getpass(f"New {label} password: ")
if not password or len(password) > 4096 or password != getpass.getpass("Confirm new password: "):
    sys.exit("Enter matching, nonempty passwords of at most 4096 characters.")

salt = os.urandom(16)
digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 600_000)
entries[index] = f"{salt.hex()} {digest.hex()}"
output = tempfile.NamedTemporaryFile(
    mode="w", encoding="ascii", dir=path.parent, prefix=".passwords-", delete=False
)
temporary = Path(output.name)
try:
    with output:
        output.write("\n".join(entries) + "\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
finally:
    temporary.unlink(missing_ok=True)
print(f"The {label} password was updated.")
PYTHON
sync -f "$conf"
