#!/usr/bin/env bash
# Create isolated AI training network on OpenStack.
# High MTU (9000) for jumbo frames — critical for NCCL collective operations
# in distributed training (AllReduce, AllGather).

set -euo pipefail
GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓ $1${NC}"; }

[[ -z "${OS_AUTH_URL:-}" ]] && { echo "Source admin-openrc.sh first"; exit 1; }

echo -e "\n${BOLD}Creating AI training network${NC}\n"

# ── Provider VLAN network (physnet-ai, VLAN 200) ──────────────────────────────
openstack network create \
  --provider-physical-network physnet-ai \
  --provider-network-type vlan \
  --provider-segment 200 \
  --mtu 9000 \
  --share \
  ai-training-net 2>/dev/null || true
ok "Network: ai-training-net (VLAN 200, MTU 9000)"

# ── Subnet — /16 for large distributed training clusters ─────────────────────
openstack subnet create \
  --network ai-training-net \
  --subnet-range 10.200.0.0/16 \
  --gateway 10.200.0.1 \
  --dns-nameserver 8.8.8.8 \
  --no-dhcp \
  ai-training-subnet 2>/dev/null || true
ok "Subnet: 10.200.0.0/16 (DHCP disabled — static IPs for stable NCCL endpoints)"

# ── Security group: allow all traffic within subnet for NCCL ─────────────────
openstack security group create ai-training 2>/dev/null || true
openstack security group rule create ai-training \
  --protocol any --remote-ip 10.200.0.0/16 2>/dev/null || true
openstack security group rule create ai-training \
  --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0 2>/dev/null || true
ok "Security group: ai-training (all traffic within subnet + SSH from anywhere)"

# ── Aggregate: pin GPU instances to GPU compute nodes ────────────────────────
openstack aggregate create gpu-nodes 2>/dev/null || true
openstack aggregate set --property "gpu"="true" gpu-nodes 2>/dev/null || true
for host in compute-gpu01 compute-gpu02 compute-gpu03 compute-gpu04; do
  openstack aggregate add host gpu-nodes "$host" 2>/dev/null || true
done
ok "Aggregate: gpu-nodes (GPU compute hosts pinned)"

echo
echo -e "${BOLD}AI training network ready:${NC}"
echo "  Network:        ai-training-net (VLAN 200)"
echo "  Subnet:         10.200.0.0/16 (MTU 9000)"
echo "  Security group: ai-training"
echo "  Host aggregate: gpu-nodes"
echo
echo "Launch GPU instance:"
echo "  openstack server create \\"
echo "    --flavor gpu.a100.1x \\"
echo "    --image Ubuntu-22.04-CUDA \\"
echo "    --network ai-training-net \\"
echo "    --security-group ai-training \\"
echo "    --availability-zone nova:compute-gpu01 \\"
echo "    gpu-training-job-01"
