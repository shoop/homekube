#!/bin/sh
set -x
STREAM="stable"
sudo podman run --pull=always --user 1000 --rm \
	-v $HOME/src/firsakube/images:/data -w /data \
	quay.io/coreos/coreos-installer:release \
		download -s "${STREAM}" -p qemu -f qcow2.xz --decompress
chcon -t svirt_home_t images/\*.qcow2
