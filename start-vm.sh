#!/bin/sh -x

#
# TODO:
# - generate MAC:
# echo 'import random ; print("52:54:00:%02x:%02x:%02x" % (random.randint(0,255), random.randint(0,255), random.randint(0,255)))' | python
# - virsh net-define virsh-net-kubernetes.yaml
# - virsh net-autostart kubenet
# - virsh net-start kubenet
# - possibly destroy/undefine/remove storage of VM

help() {
	echo "Usage: $(basename $0) <.ign> [<qcow> [<vmname> [<vcpu> [<ram> [<disk>]]]]]"
	exit 1
}

if [ -z "$1" ]; then
	help
	exit 1
fi

FCC=$(readlink -f $1)
IGNITION_CONFIG=$(readlink -f ./ignition/${1%.*}).ign
podman run -i --rm quay.io/coreos/fcct:release --pretty --strict < ${FCC} > ${IGNITION_CONFIG} || exit 1
chcon -t svirt_home_t ${IGNITION_CONFIG}
echo Using ignition config ${IGNITION_CONFIG}

STREAM="stable"
IMAGE=$(readlink -f ${2:-./images/$(ls -t ./images | head -n 1)})
VM_NAME=${3:-$(basename ${FCC%.*})}
NETWORK="kubenet"
VCPUS=${4:-2}
RAM_MB=${5:-2048}
DISK_GB=${6:-20}

sudo virt-install --connect="qemu:///system" --name="${VM_NAME}" \
	--vcpus="${VCPUS}" --memory="${RAM_MB}" \
	--network="network=${NETWORK}" \
        --os-variant="fedora-coreos-${STREAM}" --import --graphics=none \
        --disk="size=${DISK_GB},backing_store=${IMAGE}" \
        --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}"
