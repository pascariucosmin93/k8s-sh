#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <neighbor_ip> <remote_as>" >&2
  exit 1
fi

NEIGHBOR_IP=$1
REMOTE_AS=$2

if vtysh -c "show running-config" | grep -q "neighbor ${NEIGHBOR_IP} remote-as ${REMOTE_AS}"; then
  echo "Neighbor ${NEIGHBOR_IP} already exists"
  exit 0
fi

vtysh -c "configure terminal" \
  -c "router bgp 65000" \
  -c "neighbor ${NEIGHBOR_IP} remote-as ${REMOTE_AS}" \
  -c "end" \
  -c "write memory"

vtysh -c "show bgp summary" | grep -E "^Neighbor|^${NEIGHBOR_IP}[[:space:]]" || true

