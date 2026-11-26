#!/bin/bash
set -euo pipefail

if ! modprobe vhost_net; then
  echo "host-prepare: cannot load vhost_net from /lib/modules/$(uname -r)"
  exit 1
fi
# KVM_DEVICE lets the unit test point the check at a file.
if [[ ! -e "${KVM_DEVICE:-/dev/kvm}" ]]; then
  echo "host-prepare: /dev/kvm is missing on this node, guests run under TCG"
fi
