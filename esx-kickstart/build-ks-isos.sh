#!/usr/bin/env bash
# build-ks-isos.sh - one kickstart ISO per host from the stock ESX ISO
#
# Usage: ./build-ks-isos.sh <stock-esx.iso> <hosts.csv> <ks-template.cfg> <out-dir> <settings.env>
#   hosts.csv    columns: name,ip,mac,bootdisk   (header line required; mac = management uplink)
#   settings.env shell assignments written by Install-EsxKickstart.ps1 from esx-settings.json:
#                KS_DOMAIN KS_NETMASK KS_GATEWAY KS_DNS (comma list) KS_NTP (comma list) KS_VLAN
#                (KS_VLAN 0 = untagged) KS_KEYBOARD KS_BOOTDISK (default model) KS_SSHKEY (public key, may be empty) KS_MTU (default 1500)
# Reads the root passwords on stdin, one "<name><TAB><password>" line per host (never written anywhere but into the ISOs).
# Needs: xorriso.
set -euo pipefail

SRC_ISO=$1; HOSTS=$2; TEMPLATE=$3; OUT=$4; SETTINGS=$5
# shellcheck source=/dev/null
source "$SETTINGS"
for v in KS_DOMAIN KS_NETMASK KS_GATEWAY KS_DNS KS_NTP KS_VLAN KS_KEYBOARD; do
  [[ -n "${!v:-}" ]] || { echo "$v is missing from $SETTINGS"; exit 1; }
done
KS_BOOTDISK=${KS_BOOTDISK:-}; KS_SSHKEY=${KS_SSHKEY:-}; KS_MTU=${KS_MTU:-1500}

command -v xorriso >/dev/null || { echo "xorriso not found (apt install xorriso)"; exit 1; }
# root passwords on stdin, one line per host: <name><TAB><password> (CR at line ends is stripped)
declare -A PW
while IFS=$'\t' read -r PNAME PPW || [[ -n "${PNAME:-}" ]]; do
  PNAME=${PNAME%$'\r'}; PPW=${PPW%$'\r'}
  [[ -n "$PNAME" ]] && PW[$PNAME]=$PPW
done

# escape characters that are special in a sed replacement (\ & |)
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
NTPARGS=""; IFS=, read -ra NTPS <<< "$KS_NTP"
for n in "${NTPS[@]}"; do NTPARGS+="--server=$n "; done
# VLAN 0 = untagged (the port group in front of the host tags it): leave --vlanid out of the kickstart
VLANOPT=" --vlanid=$KS_VLAN"; [[ "$KS_VLAN" == "0" ]] && VLANOPT=""
if [[ -n "$KS_SSHKEY" ]]; then
  SSHKEYCMD="mkdir -p /etc/ssh/keys-root; echo '$KS_SSHKEY' >> /etc/ssh/keys-root/authorized_keys; chmod 600 /etc/ssh/keys-root/authorized_keys"
else
  SSHKEYCMD="# no management PC key supplied"
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/iso"
xorriso -osirrox on -indev "$SRC_ISO" -extract / "$WORK/iso" >/dev/null 2>&1
chmod -R u+w "$WORK/iso"

tail -n +2 "$HOSTS" | while IFS=, read -r NAME IP MAC DISK; do
  NAME=${NAME%$'\r'}; MAC=${MAC%$'\r'}; DISK=${DISK%$'\r'}
  [[ -z "$NAME" ]] && continue
  ROOTPW=${PW[$NAME]:-}
  [[ -n "$ROOTPW" ]] || { echo "$NAME: no root password received"; exit 1; }
  DISK=${DISK:-$KS_BOOTDISK}
  [[ -n "$DISK" ]] || { echo "$NAME: no boot disk given and no default"; exit 1; }
  # a model with spaces is passed quoted; one without stays bare (the form proven on the R640s)
  KSDISK=$DISK; [[ "$DISK" == *" "* ]] && KSDISK="\"$DISK\""
  FQDN="$NAME.$KS_DOMAIN"
  B="$WORK/$NAME"; rm -rf "$B"; cp -a "$WORK/iso" "$B"

  sed -e "s|{{BOOTDISK}}|$(esc "$KSDISK")|g" -e "s|{{ROOTPW}}|$(esc "$ROOTPW")|g" \
      -e "s|{{KEYBOARD}}|$(esc "$KS_KEYBOARD")|g" -e "s|{{MAC}}|$MAC|g" -e "s|{{IP}}|$IP|g" \
      -e "s|{{NETMASK}}|$KS_NETMASK|g" -e "s|{{GATEWAY}}|$KS_GATEWAY|g" -e "s|{{DNS}}|$KS_DNS|g" \
      -e "s| --vlanid={{VLAN}}|$VLANOPT|g" -e "s|{{MTU}}|$KS_MTU|g" -e "s|{{FQDN}}|$FQDN|g" -e "s|{{VLAN}}|$KS_VLAN|g" -e "s|{{DOMAIN}}|$KS_DOMAIN|g" \
      -e "s|{{NTPARGS}}|$(esc "$NTPARGS")|g" -e "s|{{SSHKEYCMD}}|$(esc "$SSHKEYCMD")|g" \
      "$TEMPLATE" | tr -d '\r' > "$B/KS.CFG"

  # Point both boot loaders (legacy BIOS and UEFI) at the kickstart on the CD
  for cfg in "$B/BOOT.CFG" "$B/EFI/BOOT/BOOT.CFG"; do
    sed -i -E 's|^kernelopt=.*|kernelopt=runweasel ks=cdrom:/KS.CFG|' "$cfg"
  done

  xorriso -as mkisofs -relaxed-filenames -J -R -V "ESX-KS-${NAME^^}" \
    -o "$OUT/esx-ks-$NAME.iso" \
    -b ISOLINUX.BIN -c BOOT.CAT -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e EFIBOOT.IMG -no-emul-boot \
    "$B" >/dev/null 2>&1
  echo "Built $OUT/esx-ks-$NAME.iso  ($FQDN  $IP  VLAN $KS_VLAN  uplink $MAC  disk $DISK)"
done
echo "Done. The ISOs contain the root password and are deleted at the end of the run."
