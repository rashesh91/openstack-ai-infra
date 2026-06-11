#!/usr/bin/env bash
# Create Nova GPU flavors with PCI passthrough resource specs.
# Source admin-openrc.sh before running.

set -euo pipefail
GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓ $1${NC}"; }

[[ -z "${OS_AUTH_URL:-}" ]] && { echo "Source admin-openrc.sh first"; exit 1; }

echo -e "\n${BOLD}Creating GPU Nova flavors${NC}\n"

# ── NVIDIA A100 flavors ──────────────────────────────────────────────────────
openstack flavor create gpu.a100.1x \
  --ram 131072 --vcpus 16 --disk 100 \
  --public 2>/dev/null || openstack flavor set gpu.a100.1x
openstack flavor set gpu.a100.1x \
  --property "pci_passthrough:alias"="nvidia-a100:1" \
  --property "hw:cpu_policy"="dedicated" \
  --property "hw:mem_page_size"="large" \
  --property "hw:numa_nodes"="1"
ok "gpu.a100.1x — 16 vCPU / 128 GB RAM / 1x A100"

openstack flavor create gpu.a100.2x \
  --ram 262144 --vcpus 32 --disk 200 \
  --public 2>/dev/null || true
openstack flavor set gpu.a100.2x \
  --property "pci_passthrough:alias"="nvidia-a100:2" \
  --property "hw:cpu_policy"="dedicated" \
  --property "hw:mem_page_size"="large" \
  --property "hw:numa_nodes"="2"
ok "gpu.a100.2x — 32 vCPU / 256 GB RAM / 2x A100"

# ── NVIDIA T4 flavors (inference) ────────────────────────────────────────────
openstack flavor create gpu.t4.1x \
  --ram 65536 --vcpus 8 --disk 100 \
  --public 2>/dev/null || true
openstack flavor set gpu.t4.1x \
  --property "pci_passthrough:alias"="nvidia-t4:1" \
  --property "hw:cpu_policy"="dedicated" \
  --property "hw:mem_page_size"="large"
ok "gpu.t4.1x  — 8 vCPU / 64 GB RAM / 1x T4 (inference)"

# ── Bare metal flavor (for Ironic nodes) ─────────────────────────────────────
openstack flavor create baremetal.gpu.a100 \
  --ram 524288 --vcpus 64 --disk 1000 \
  --public 2>/dev/null || true
openstack flavor set baremetal.gpu.a100 \
  --property "capabilities:boot_option"="local" \
  --property "resources:CUSTOM_BAREMETAL_GPU_A100"="1" \
  --property "resources:VCPU"="0" \
  --property "resources:MEMORY_MB"="0" \
  --property "resources:DISK_GB"="0"
ok "baremetal.gpu.a100 — 64 vCPU / 512 GB RAM / full bare-metal GPU node (Ironic)"

echo
echo -e "${BOLD}GPU flavors created:${NC}"
openstack flavor list --long | grep gpu
