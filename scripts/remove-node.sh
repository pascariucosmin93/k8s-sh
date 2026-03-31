#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

DEFAULT_SSH_USER="root"
WORKER_ASN="${WORKER_ASN:-65001}"

MASTER_IP=""
NODE_NAME=""
NODE_HOST=""
SSH_USER="$DEFAULT_SSH_USER"
FORCE_DELETE="false"
ROUTER1_IP=""
ROUTER2_IP=""
CONFIGURE_BGP="true"

usage() {
  cat <<EOF
Usage:
  $0 --master <MASTER_IP> --node-name <K8S_NODE_NAME> --node-host <SSH_HOST> [options]

Options:
  --ssh-user <USER>
  --force
  --router1 <IP>
  --router2 <IP>
  --skip-bgp
EOF
}

log() { echo -e "${GREEN}[+] $*${NC}" >&2; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }
fail() { echo -e "${RED}[x] $*${NC}" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master) MASTER_IP="${2:-}"; shift 2 ;;
    --node-name) NODE_NAME="${2:-}"; shift 2 ;;
    --node-host) NODE_HOST="${2:-}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --force) FORCE_DELETE="true"; shift ;;
    --router1) ROUTER1_IP="${2:-}"; shift 2 ;;
    --router2) ROUTER2_IP="${2:-}"; shift 2 ;;
    --skip-bgp) CONFIGURE_BGP="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$MASTER_IP" ]] || fail "--master is required"
[[ -n "$NODE_NAME" ]] || fail "--node-name is required"
[[ -n "$NODE_HOST" ]] || fail "--node-host is required"

run_remote() {
  local host=$1
  shift
  ssh -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "$@"
}

drain_node() {
  log "Draining ${NODE_NAME}"
  run_remote "$MASTER_IP" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl drain '${NODE_NAME}' --ignore-daemonsets --delete-emptydir-data --force"
}

delete_node() {
  log "Deleting node object ${NODE_NAME}"
  run_remote "$MASTER_IP" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete node '${NODE_NAME}'"
}

reset_node() {
  log "Resetting kubeadm state on ${NODE_HOST}"
  run_remote "$NODE_HOST" "sudo bash -s" <<'REMOTE_EOF'
set -euo pipefail
kubeadm reset -f
rm -rf /etc/cni/net.d
systemctl restart containerd || true
systemctl restart kubelet || true
REMOTE_EOF
}

configure_router_cleanup() {
  local router_ip=$1
  [[ -n "$router_ip" ]] || return 0
  log "Removing BGP neighbor ${NODE_HOST} from router ${router_ip}"
  ssh -o StrictHostKeyChecking=no "root@${router_ip}" \
    "if vtysh -c 'show running-config' | grep -q 'neighbor ${NODE_HOST} remote-as ${WORKER_ASN}'; then vtysh -c 'configure terminal' -c 'router bgp 65000' -c 'no neighbor ${NODE_HOST} remote-as ${WORKER_ASN}' -c 'end' -c 'write memory' >/dev/null; fi; vtysh -c 'show bgp summary' | grep -E '^Neighbor|^${NODE_HOST}[[:space:]]' || true"
}

drain_node
delete_node

if [[ "$FORCE_DELETE" != "true" ]]; then
  reset_node
else
  warn "Skipping remote reset because --force was requested"
fi

if [[ "$CONFIGURE_BGP" == "true" ]]; then
  configure_router_cleanup "$ROUTER1_IP"
  configure_router_cleanup "$ROUTER2_IP"
fi

log "Node ${NODE_NAME} was removed from the cluster"

