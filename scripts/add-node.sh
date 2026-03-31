#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

K8S_VERSION="${K8S_VERSION:-1.31}"
DEFAULT_SSH_USER="root"
WORKER_ASN="${WORKER_ASN:-65001}"

MASTER_IP=""
NODE_IP=""
SSH_USER="$DEFAULT_SSH_USER"
NODE_NAME=""
TOPOLOGY_REGION=""
TOPOLOGY_ZONE=""
ROUTER1_IP=""
ROUTER2_IP=""
CONFIGURE_BGP="true"

usage() {
  cat <<EOF
Usage:
  $0 --master <MASTER_IP> --node <NODE_IP> [options]

Options:
  --ssh-user <USER>
  --node-name <NAME>
  --topology-region <REGION>
  --topology-zone <ZONE>
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
    --node) NODE_IP="${2:-}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --node-name) NODE_NAME="${2:-}"; shift 2 ;;
    --topology-region) TOPOLOGY_REGION="${2:-}"; shift 2 ;;
    --topology-zone) TOPOLOGY_ZONE="${2:-}"; shift 2 ;;
    --router1) ROUTER1_IP="${2:-}"; shift 2 ;;
    --router2) ROUTER2_IP="${2:-}"; shift 2 ;;
    --skip-bgp) CONFIGURE_BGP="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$MASTER_IP" ]] || fail "--master is required"
[[ -n "$NODE_IP" ]] || fail "--node is required"

run_remote() {
  local host=$1
  shift
  ssh -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "$@"
}

prepare_node() {
  log "Preparing node ${NODE_IP}"
  run_remote "$NODE_IP" "sudo K8S_VERSION='${K8S_VERSION}' NODE_NAME='${NODE_NAME}' bash -s" <<'REMOTE_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ -n "${NODE_NAME:-}" ]]; then
  hostnamectl set-hostname "${NODE_NAME}"
fi

swapoff -a
sed -i '/swap/d' /etc/fstab

tee /etc/modules-load.d/k8s.conf >/dev/null <<MOD
overlay
br_netfilter
MOD

modprobe overlay
modprobe br_netfilter

tee /etc/sysctl.d/k8s.conf >/dev/null <<SYSCTL
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL

sysctl --system >/dev/null

apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release conntrack xfsprogs >/dev/null

apt-get remove -y containerd 2>/dev/null || true
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | tee /etc/apt/keyrings/docker.asc >/dev/null
chmod a+r /etc/apt/keyrings/docker.asc

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" >/etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq containerd.io >/dev/null

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd >/dev/null

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet >/dev/null

mkdir -p /var/lib/kubelet/plugins_registry

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  kubeadm reset -f >/dev/null || true
  rm -rf /etc/cni/net.d
fi

systemctl restart containerd
systemctl restart kubelet || true
REMOTE_EOF
}

get_join_command() {
  run_remote "$MASTER_IP" "sudo kubeadm token create --print-join-command"
}

join_node() {
  local join_cmd=$1
  log "Joining ${NODE_IP} to the cluster"
  run_remote "$NODE_IP" "sudo ${join_cmd}"
}

discover_joined_node_name() {
  if [[ -n "$NODE_NAME" ]]; then
    echo "$NODE_NAME"
    return 0
  fi
  run_remote "$MASTER_IP" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide --no-headers | awk '\$6 == \"${NODE_IP}\" {print \$1; exit}'"
}

wait_for_node() {
  local node_name=$1
  run_remote "$MASTER_IP" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl wait --for=condition=Ready node/${node_name} --timeout=300s"
}

label_node() {
  local node_name=$1
  if [[ -z "$TOPOLOGY_REGION" || -z "$TOPOLOGY_ZONE" ]]; then
    warn "Skipping topology labels because region/zone were not provided"
    return 0
  fi
  run_remote "$MASTER_IP" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node '${node_name}' topology.kubernetes.io/region='${TOPOLOGY_REGION}' topology.kubernetes.io/zone='${TOPOLOGY_ZONE}' --overwrite"
}

configure_router_neighbor() {
  local router_ip=$1
  [[ -n "$router_ip" ]] || return 0
  log "Adding BGP neighbor ${NODE_IP} on router ${router_ip}"
  ssh -o StrictHostKeyChecking=no "root@${router_ip}" \
    "vtysh -c 'configure terminal' -c 'router bgp 65000' -c 'neighbor ${NODE_IP} remote-as ${WORKER_ASN}' -c 'end' -c 'write memory' >/dev/null && vtysh -c 'show bgp summary' | grep -E '^Neighbor|^${NODE_IP}[[:space:]]' || true"
}

prepare_node
JOIN_CMD="$(get_join_command)"
join_node "$JOIN_CMD"
JOINED_NODE_NAME="$(discover_joined_node_name)"
[[ -n "$JOINED_NODE_NAME" ]] || fail "Could not determine the joined node name"
wait_for_node "$JOINED_NODE_NAME"
label_node "$JOINED_NODE_NAME"

if [[ "$CONFIGURE_BGP" == "true" ]]; then
  configure_router_neighbor "$ROUTER1_IP"
  configure_router_neighbor "$ROUTER2_IP"
fi

log "Node ${JOINED_NODE_NAME} (${NODE_IP}) was prepared and joined successfully"

