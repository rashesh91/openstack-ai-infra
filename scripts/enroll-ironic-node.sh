#!/usr/bin/env bash
# enroll-ironic-node.sh
# Enrolls bare metal GPU nodes into OpenStack Ironic.
# Author: rasheshpatel <rasheshkumar.patel@gmail.com>

set -euo pipefail

ADMIN_OPENRC="/etc/kolla/admin-openrc.sh"

if [[ ! -f "${ADMIN_OPENRC}" ]]; then
    echo "ERROR: ${ADMIN_OPENRC} not found. Run 'kolla-ansible post-deploy' first." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${ADMIN_OPENRC}"

# ─── Node definitions ─────────────────────────────────────────────────────────
# Node names
NODE_NAMES=("bm-gpu-01" "bm-gpu-02" "bm-gpu-03" "bm-gpu-04")

# IPMI out-of-band management addresses
IPMI_ADDRESSES=("10.0.2.11" "10.0.2.12" "10.0.2.13" "10.0.2.14")

# IPMI credentials (use Barbican in production)
IPMI_USERNAME="admin"
IPMI_PASSWORD="${IRONIC_IPMI_PASSWORD:-ChangeMe123!}"

# Primary NIC MAC addresses (PXE boot interface)
MAC_ADDRESSES=(
    "ac:1f:6b:a3:12:01"
    "ac:1f:6b:a3:12:02"
    "ac:1f:6b:a3:12:03"
    "ac:1f:6b:a3:12:04"
)

# Bare metal node hardware profile
BM_MEMORY_MB=524288    # 512 GB
BM_LOCAL_GB=960        # 960 GB NVMe (leaving headroom for OS partition table)
BM_CPUS=128
BM_RESOURCE_CLASS="baremetal-gpu"
DEPLOY_KERNEL="deploy-kernel"    # Glance image name
DEPLOY_RAMDISK="deploy-ramdisk"  # Glance image name

# ─── Pre-flight checks ────────────────────────────────────────────────────────
echo "==> Pre-flight: checking Ironic service availability..."
openstack baremetal driver list | grep -q "ipmi" || {
    echo "ERROR: IPMI driver not available in Ironic. Check ironic-conductor logs." >&2
    exit 1
}

DEPLOY_KERNEL_UUID=$(openstack image show "${DEPLOY_KERNEL}" -f value -c id 2>/dev/null || true)
DEPLOY_RAMDISK_UUID=$(openstack image show "${DEPLOY_RAMDISK}" -f value -c id 2>/dev/null || true)

if [[ -z "${DEPLOY_KERNEL_UUID}" || -z "${DEPLOY_RAMDISK_UUID}" ]]; then
    echo "WARN: Deploy kernel/ramdisk images not found in Glance."
    echo "      Upload ironic-deploy kernel and ramdisk images before using nodes."
    echo "      Continuing enrollment without deploy images..."
    USE_DEPLOY_IMAGES=false
else
    USE_DEPLOY_IMAGES=true
    echo "  Deploy kernel:   ${DEPLOY_KERNEL_UUID}"
    echo "  Deploy ramdisk:  ${DEPLOY_RAMDISK_UUID}"
fi

echo ""
echo "==> Enrolling ${#NODE_NAMES[@]} bare metal GPU nodes into Ironic..."
echo ""

# ─── Enrollment loop ──────────────────────────────────────────────────────────
declare -a ENROLLED_UUIDS=()

for i in "${!NODE_NAMES[@]}"; do
    NODE_NAME="${NODE_NAMES[$i]}"
    IPMI_ADDR="${IPMI_ADDRESSES[$i]}"
    MAC_ADDR="${MAC_ADDRESSES[$i]}"

    echo "──────────────────────────────────────────────────────────"
    echo "  Node: ${NODE_NAME}  |  IPMI: ${IPMI_ADDR}  |  MAC: ${MAC_ADDR}"
    echo "──────────────────────────────────────────────────────────"

    # Check if node already exists
    if openstack baremetal node show "${NODE_NAME}" &>/dev/null; then
        echo "  [SKIP] Node '${NODE_NAME}' already exists in Ironic."
        NODE_UUID=$(openstack baremetal node show "${NODE_NAME}" -f value -c uuid)
        ENROLLED_UUIDS+=("${NODE_UUID}")
        echo ""
        continue
    fi

    # Create the node
    echo "  [1/6] Creating node '${NODE_NAME}'..."
    NODE_UUID=$(openstack baremetal node create \
        --driver ipmi \
        --name "${NODE_NAME}" \
        -f value -c uuid)
    echo "        UUID: ${NODE_UUID}"
    ENROLLED_UUIDS+=("${NODE_UUID}")

    # Configure IPMI driver info and node attributes
    echo "  [2/6] Setting IPMI, boot, and deploy interfaces..."
    openstack baremetal node set "${NODE_UUID}" \
        --driver-info ipmi_address="${IPMI_ADDR}" \
        --driver-info ipmi_username="${IPMI_USERNAME}" \
        --driver-info ipmi_password="${IPMI_PASSWORD}" \
        --driver-info ipmi_port=623 \
        --boot-interface pxe \
        --deploy-interface direct \
        --inspect-interface inspector \
        --management-interface ipmitool \
        --power-interface ipmitool \
        --resource-class "${BM_RESOURCE_CLASS}"

    # Set deploy images if available
    if [[ "${USE_DEPLOY_IMAGES}" == "true" ]]; then
        openstack baremetal node set "${NODE_UUID}" \
            --driver-info deploy_kernel="${DEPLOY_KERNEL_UUID}" \
            --driver-info deploy_ramdisk="${DEPLOY_RAMDISK_UUID}"
    fi

    # Set hardware properties
    echo "  [3/6] Setting hardware properties (CPU/RAM/disk)..."
    openstack baremetal node set "${NODE_UUID}" \
        --property memory_mb="${BM_MEMORY_MB}" \
        --property local_gb="${BM_LOCAL_GB}" \
        --property cpus="${BM_CPUS}" \
        --property cpu_arch=x86_64 \
        --property capabilities="boot_mode:uefi,boot_option:local"

    # Create port for PXE boot interface
    echo "  [4/6] Creating baremetal port for MAC ${MAC_ADDR}..."
    openstack baremetal port create \
        --node "${NODE_UUID}" \
        --address "${MAC_ADDR}" \
        --pxe-enabled true

    # Move node to 'manageable' state
    echo "  [5/6] Moving node to 'manageable' state..."
    openstack baremetal node manage "${NODE_UUID}" --wait 120

    sleep 2

    # Trigger hardware inspection
    echo "  [6/6] Starting hardware inspection (this takes ~30 seconds)..."
    openstack baremetal node inspect "${NODE_UUID}" || {
        echo "  WARN: Inspection failed or timed out for ${NODE_NAME}."
        echo "        Node will remain in 'manageable' state."
        echo "        Run: openstack baremetal node inspect ${NODE_NAME}"
        echo ""
        continue
    }

    echo "        Waiting 30 seconds for inspection to complete..."
    sleep 30

    # Move to 'available' for scheduling
    echo "        Moving node to 'available' state..."
    openstack baremetal node provide "${NODE_UUID}" --wait 180 || {
        echo "  WARN: Could not move ${NODE_NAME} to 'available'."
        echo "        Check: openstack baremetal node show ${NODE_NAME}"
    }

    echo "  [OK] ${NODE_NAME} enrolled and available."
    echo ""
done

# ─── Summary ──────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Ironic Node Enrollment Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
openstack baremetal node list \
    -c Name -c UUID -c "Provisioning State" -c "Power State" -c "Resource Class"
echo ""
echo "  Total nodes enrolled: ${#ENROLLED_UUIDS[@]}"
echo ""
echo "  To check a specific node:"
echo "    openstack baremetal node show <name>"
echo ""
echo "  To manually move a node to available:"
echo "    openstack baremetal node provide <name> --wait 180"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
