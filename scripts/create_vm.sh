#!/usr/bin/env bash
set -euo pipefail

export VM_BOOT_DISK_ID=computedisk-e00pgp81spgbpmsbpk

nebius compute instance create \
  --name mlops-hw3-kw-instance \
  --parent-id project-e00zhyy0pr003fn53qmxgf \
  --stopped false \
  --resources-platform gpu-h100-sxm \
  --resources-preset 1gpu-16vcpu-200gb \
  --boot-disk-existing-disk-id "$VM_BOOT_DISK_ID" \
  --boot-disk-attach-mode read_write \
  --boot-disk-device-id boot-disk \
  --network-interfaces '[{"name":"eth0","ip_address":{},"public_ip_address":{},"subnet_id":"vpcsubnet-e00exq1pjvtbcs3m6q"}]' \
  --reservation-policy-policy auto \
  --cloud-init-user-data '#cloud-config
users:
  - name: ubuntu
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxSi9XivY+M7BP4p7RMXZ9ohD/DdUTc/dpkAjQs+v6d kexinwang929@gmail.com'
