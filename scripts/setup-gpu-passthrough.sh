#!/usr/bin/env bash
# Configure GPU PCI passthrough (VFIO) on a KVM compute node.
# Run once on each GPU compute node before adding it to OpenStack.
# Supports Intel and AMD IOMMU.
#
# Usage: sudo ./scripts/setup-gpu-passthrough.sh

set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }

[[ $EUID -ne 0 ]] && fail "Run as root: sudo $0"

# ── Detect GPU ───────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Detecting NVIDIA GPUs${NC}"
GPU_INFO=$(lspci -nn | grep -i nvidia || true)
[[ -z "$GPU_INFO" ]] && fail "No NVIDIA GPU found"
echo "$GPU_INFO"
GPU_IDS=$(echo "$GPU_INFO" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | sort -u | tr '\n' ',' | sed 's/,$//')
ok "GPU PCI IDs: $GPU_IDS"

# ── Check IOMMU ──────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Checking IOMMU${NC}"
GRUB_FILE=/etc/default/grub

CPU_VENDOR=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
  IOMMU_PARAM="intel_iommu=on iommu=pt"
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
  IOMMU_PARAM="amd_iommu=on iommu=pt"
else
  fail "Unknown CPU vendor: $CPU_VENDOR"
fi

if dmesg | grep -q "IOMMU enabled"; then
  ok "IOMMU already enabled"
else
  warn "IOMMU not enabled — adding to GRUB"
  sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${IOMMU_PARAM} /" "$GRUB_FILE"
  update-grub
  ok "GRUB updated — reboot required after this script"
fi

# ── Blacklist nouveau ────────────────────────────────────────────────────────
echo -e "\n${BOLD}Blacklisting nouveau driver${NC}"
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
ok "nouveau blacklisted"

# ── Bind GPU to vfio-pci ─────────────────────────────────────────────────────
echo -e "\n${BOLD}Binding GPU to vfio-pci${NC}"
cat > /etc/modprobe.d/vfio.conf << EOF
options vfio-pci ids=${GPU_IDS}
softdep nvidia pre: vfio-pci
EOF

# Load vfio modules at boot
cat > /etc/modules-load.d/vfio.conf << 'EOF'
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF

modprobe vfio_pci 2>/dev/null || warn "vfio_pci module not loaded yet (will load after reboot)"
ok "vfio-pci configured for IDs: ${GPU_IDS}"

# ── Update initramfs ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}Updating initramfs${NC}"
if command -v update-initramfs &>/dev/null; then
  update-initramfs -u
elif command -v dracut &>/dev/null; then
  dracut --force
fi
ok "initramfs updated"

# ── Verify IOMMU groups ──────────────────────────────────────────────────────
echo -e "\n${BOLD}IOMMU groups for NVIDIA devices${NC}"
find /sys/kernel/iommu_groups -name "*/devices/*" 2>/dev/null | while read path; do
  dev=$(basename "$path")
  desc=$(lspci -s "$dev" 2>/dev/null || echo "unknown")
  if echo "$desc" | grep -qi nvidia; then
    group=$(echo "$path" | grep -oP 'iommu_groups/\K[0-9]+')
    echo "  Group $group: $dev — $desc"
  fi
done || warn "IOMMU groups not visible yet — reboot required"

echo
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Reboot the node:       sudo reboot"
echo "  2. Verify after reboot:   dmesg | grep -i iommu"
echo "  3. Verify vfio binding:   lspci -nnk | grep -A2 NVIDIA"
echo "  4. Add nova.conf PCI passthrough config and restart nova-compute"
