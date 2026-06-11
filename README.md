# OpenStack GPU Cloud for AI/ML — Kolla-Ansible

Extends a production OpenStack private cloud for **GPU AI/ML workloads**. Enables PCI passthrough for NVIDIA GPUs, Ironic bare-metal provisioning for GPU nodes, custom Nova flavors, and an isolated high-MTU training network — so data science teams get self-service GPU compute with full data sovereignty.

---

## Use Case

A data science team needs:
- On-demand GPU instances (no cloud egress, full GPU memory, PCI passthrough)
- Bare-metal GPU nodes for workloads that can't tolerate hypervisor overhead
- An isolated AI training network with jumbo frames (MTU 9000) for NCCL distributed training
- Self-service: `openstack server create --flavor gpu.a100.1x` — done

This repo adds those capabilities on top of a Kolla-Ansible OpenStack base (see [`openstack-kolla-deploy`](https://github.com/rashesh91/openstack-kolla-deploy)).

---

## Architecture

```
                        OpenStack Control Plane (existing)
                        ┌──────────────────────────────────┐
                        │  Nova + PCI Passthrough Filters  │
                        │  Ironic (bare metal service)     │
                        │  Heat orchestration templates    │
                        └──────────────────────────────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              │                          │                          │
   compute-gpu01-04              ironic-bm01-02              AI Training Net
   NVIDIA A100 / T4              Full bare-metal GPU         VLAN 200, MTU 9000
   vfio-pci passthrough          No hypervisor overhead      NCCL AllReduce ready
```

| Resource | Detail |
|----------|--------|
| GPU flavors | `gpu.a100.1x`, `gpu.a100.2x`, `gpu.t4.1x`, `baremetal.gpu.a100` |
| Passthrough | NVIDIA A100 (10de:20b5), T4 (10de:1eb8) via vfio-pci |
| Bare metal | Ironic IPMI driver, iPXE boot |
| AI network | VLAN 200, 10.200.0.0/16, MTU 9000 |
| NUMA pinning | `hw:cpu_policy=dedicated`, `hw:mem_page_size=large` |

---

## Prerequisites

- Working Kolla-Ansible OpenStack deployment (`openstack-kolla-deploy`)
- BIOS: VT-d (Intel) or AMD-Vi enabled on GPU compute nodes
- GPU nodes isolated from Nova general pool (host aggregate `gpu-nodes`)

---

## Setup Steps

### 1. Enable GPU passthrough on each GPU compute node

```bash
# Run on each GPU compute node
sudo ./scripts/setup-gpu-passthrough.sh
sudo reboot

# Verify after reboot
dmesg | grep -i iommu
lspci -nnk | grep -A2 NVIDIA   # should show "Kernel driver in use: vfio-pci"
```

### 2. Update Nova config and reconfigure

```bash
cp config/nova/nova.conf /etc/kolla/config/nova/nova.conf
kolla-ansible -i inventory/multinode reconfigure --tags nova
```

### 3. Configure GPU compute nodes (hugepages, CPU governor, MPS)

```bash
ansible-playbook -i inventory/multinode playbooks/configure-gpu-nodes.yml
```

### 4. Create GPU flavors

```bash
source /etc/kolla/admin-openrc.sh
./scripts/create-gpu-flavors.sh
```

### 5. Create AI training network

```bash
./scripts/create-ai-network.sh
```

### 6. Launch GPU instance via Heat

```bash
openstack stack create gpu-job-01 \
  --template heat/gpu-training-stack.yaml \
  --parameter key_name=openstack-key \
  --parameter flavor=gpu.a100.1x \
  --wait

openstack stack output show gpu-job-01 ssh_command
```

---

## GPU Flavors

| Flavor | vCPU | RAM | GPU | Use case |
|--------|------|-----|-----|---------|
| `gpu.a100.1x` | 16 | 128 GB | 1x A100 | Single-GPU fine-tuning |
| `gpu.a100.2x` | 32 | 256 GB | 2x A100 | Multi-GPU training |
| `gpu.t4.1x` | 8 | 64 GB | 1x T4 | Inference serving |
| `baremetal.gpu.a100` | 64 | 512 GB | Full node | Large model pre-training |

---

## Minimum Requirements

| Node type | CPU | RAM | GPU | Notes |
|-----------|-----|-----|-----|-------|
| GPU compute | 32 cores | 256 GB | 1–2x A100/T4 | IOMMU required |
| Bare metal GPU | 64 cores | 512 GB | 4–8x A100 | Ironic IPMI access needed |
