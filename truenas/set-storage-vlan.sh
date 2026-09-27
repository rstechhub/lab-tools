#!/bin/bash
# Puts a TrueNAS SCALE (25.x) box on a tagged storage VLAN over one physical NIC, with jumbo
# frames, and makes that VLAN the management and default-gateway network.
# Uses the TrueNAS middleware (midclt) so the config is stored properly and survives reboots.
#
# WARNING: this commits with rollback disabled. Have the IPMI / iDRAC / iLO console open.
# If you were managing the box on another NIC with DHCP, TrueNAS stops configuring that NIC
# once any interface is saved. Moving the gateway in the same run keeps you reachable on the
# new address.
# Written up at https://rstechhub.com/truenas-scale-dell-r620-part-5-storage-vlan-dac-certificate/
set -euo pipefail

PARENT=eno2               # physical NIC plugged into a trunk port carrying the VLAN tagged
VLAN_ID=48
VLAN_IF="vlan${VLAN_ID}"
IP=192.168.48.100
PREFIX=24
GATEWAY=192.168.48.1
DOMAIN=example.internal
MTU=9000

echo "Parent $PARENT MTU $MTU, no DHCP, no IPv6 autoconfig"
sudo midclt call interface.update "$PARENT" "{\"mtu\": $MTU, \"ipv4_dhcp\": false, \"ipv6_auto\": false}" > /dev/null

echo "Creating $VLAN_IF (tag $VLAN_ID) with $IP/$PREFIX"
sudo midclt call interface.create "{\"type\":\"VLAN\",\"name\":\"$VLAN_IF\",\"vlan_parent_interface\":\"$PARENT\",\"vlan_tag\":$VLAN_ID,\"mtu\":$MTU,\"ipv4_dhcp\":false,\"ipv6_auto\":false,\"aliases\":[{\"type\":\"INET\",\"address\":\"$IP\",\"netmask\":$PREFIX}]}" > /dev/null

echo "Gateway $GATEWAY, domain $DOMAIN"
sudo midclt call network.configuration.update "{\"ipv4gateway\": \"$GATEWAY\", \"domain\": \"$DOMAIN\"}" > /dev/null

echo "Committing (no rollback). The session may drop for a few seconds."
sudo midclt call interface.commit '{"rollback": false}'

sleep 5
ip -br addr show "$VLAN_IF"
ip route | grep default
ping -c 3 -M "do" -s $((MTU - 28)) "$GATEWAY"
