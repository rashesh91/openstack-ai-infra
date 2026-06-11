#!/usr/bin/env bash
# Enroll a bare-metal GPU node into OpenStack Ironic.
# Registers the node, sets PXE boot driver, and makes it available for provisioning.
#
# Usage:
#   ./scripts/enroll-ironic-node.sh \
#     --name  ironic-gpu01 \
#     --ipmi  192.168.1.101 \
#     --user  admin \
#     --pass  secretpassword \
#     --mac   AA:BB:CC:DD:EE:FF \
#     --cpu   64 \
#     --ram   524288 \     # MiB
#     --disk  4096         # GiB

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
NODE_NAME=""
IPMI_ADDRESS=""
IPMI_USER=""
IPMI_PASS=""
MAC_ADDRESS=""
CPU_COUNT=64
MEM_MIB=524288
DISK_GIB=4096

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)  NODE_NAME="$2";   shift 2 ;;
        --ipmi)  IPMI_ADDRESS="$2"; shift 2 ;;
        --user)  IPMI_USER="$2";   shift 2 ;;
        --pass)  IPMI_PASS="$2";   shift 2 ;;
        --mac)   MAC_ADDRESS="$2"; shift 2 ;;
        --cpu)   CPU_COUNT="$2";   shift 2 ;;
        --ram)   MEM_MIB="$2";     shift 2 ;;
        --disk)  DISK_GIB="$2";    shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -z "$NODE_NAME"    ]] && die "--name is required"
[[ -z "$IPMI_ADDRESS" ]] && die "--ipmi is required"
[[ -z "$IPMI_USER"    ]] && die "--user is required"
[[ -z "$IPMI_PASS"    ]] && die "--pass is required"
[[ -z "$MAC_ADDRESS"  ]] && die "--mac is required"
[[ -z "${OS_AUTH_URL:-}" ]] && die "Source admin-openrc.sh before running this script"

echo ""
echo "Enrolling Ironic bare-metal node: $NODE_NAME"
echo "  IPMI:     $IPMI_ADDRESS  (user: $IPMI_USER)"
echo "  MAC:      $MAC_ADDRESS"
echo "  CPU:      $CPU_COUNT  |  RAM: ${MEM_MIB} MiB  |  Disk: ${DISK_GIB} GiB"
echo ""

# ── Step 1: Create node in Ironic ─────────────────────────────────────────────
# driver=ipmi  — uses ipmitool for power management
# boot_interface=pxe  — network boot via TFTP/iPXE
NODE_ID=$(openstack baremetal node create \
    --driver ipmi \
    --driver-info ipmi_address="$IPMI_ADDRESS" \
    --driver-info ipmi_username="$IPMI_USER" \
    --driver-info ipmi_password="$IPMI_PASS" \
    --boot-interface pxe \
    --deploy-interface direct \
    --inspect-interface inspector \
    --name "$NODE_NAME" \
    --property cpus="$CPU_COUNT" \
    --property memory_mb="$MEM_MIB" \
    --property local_gb="$DISK_GIB" \
    --property cpu_arch=x86_64 \
    --property capabilities="boot_mode:bios,boot_option:local" \
    -f value -c uuid)

ok "Created node: $NODE_ID"

# ── Step 2: Set GPU-specific resource class ────────────────────────────────────
# Nova uses resource classes to match bare-metal flavor to Ironic node.
# The Ironic flavor must have resources:CUSTOM_GPU_BAREMETAL: 1.
openstack baremetal node set "$NODE_ID" \
    --resource-class "GPU_BAREMETAL"
ok "Resource class set: CUSTOM_GPU_BAREMETAL"

# ── Step 3: Register MAC address as Ironic port ───────────────────────────────
# PXE boot uses the MAC to identify which node is booting
PORT_ID=$(openstack baremetal port create \
    --node "$NODE_ID" \
    --address "$MAC_ADDRESS" \
    --pxe-enabled true \
    -f value -c uuid)
ok "Created port: $PORT_ID  ($MAC_ADDRESS)"

# ── Step 4: Test IPMI connectivity (power status) ─────────────────────────────
POWER_STATE=$(openstack baremetal node show "$NODE_ID" -f value -c power_state 2>/dev/null || echo "unknown")
if [[ "$POWER_STATE" == "unknown" ]]; then
    warn "IPMI power check returned 'unknown' — verify IPMI credentials and network"
else
    ok "IPMI reachable — power state: $POWER_STATE"
fi

# ── Step 5: Transition node to 'available' (ready for Nova provisioning) ──────
# enroll → manageable → available
# manageable is needed first to allow inspection/validation
openstack baremetal node manage "$NODE_ID"
ok "Node state: manageable"

# Run basic validation (checks IPMI connectivity, required fields, etc.)
if openstack baremetal node validate "$NODE_ID" 2>&1 | grep -q "FAILED"; then
    warn "Node validation has failures — review before moving to 'available':"
    openstack baremetal node validate "$NODE_ID" || true
    warn "Run manually: openstack baremetal node provide $NODE_ID"
else
    openstack baremetal node provide "$NODE_ID"
    ok "Node state: available (ready for Nova provisioning)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Node enrollment complete:"
printf "  %-20s %s\n" "Node UUID:"     "$NODE_ID"
printf "  %-20s %s\n" "Port UUID:"     "$PORT_ID"
printf "  %-20s %s\n" "Resource class:" "CUSTOM_GPU_BAREMETAL"
echo ""
echo "Provision a bare-metal GPU instance:"
echo "  openstack server create \\"
echo "    --flavor baremetal.gpu.a100 \\"
echo "    --image Ubuntu-22.04-CUDA \\"
echo "    --network ai-training-net \\"
echo "    --availability-zone nova:${NODE_NAME} \\"
echo "    bm-gpu-job-01"
echo ""
echo "Monitor deployment:"
echo "  watch openstack baremetal node show $NODE_ID -c provision_state -c last_error"
