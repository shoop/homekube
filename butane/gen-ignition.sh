#!/bin/sh
mkdir -p ign
RUN_BUTANE="podman run -i --rm -v ${PWD}:/data:Z quay.io/coreos/butane:release --pretty --strict -d /data/ign"
$RUN_BUTANE < node-install.bu > ign/node-install.ign
$RUN_BUTANE < node1-install.bu > ign/node1-install.ign
$RUN_BUTANE < node1-bootstrap.bu > ign/node1-bootstrap.ign
$RUN_BUTANE < node2-install.bu > ign/node2-install.ign
$RUN_BUTANE < node2-bootstrap.bu > ign/node2-bootstrap.ign
$RUN_BUTANE < node3-install.bu > ign/node3-install.ign
$RUN_BUTANE < node3-bootstrap.bu > ign/node3-bootstrap.ign

cp boot.ipxe ../images
cp ign/node1-install.ign ../images/config-192.168.40.41.ign
cp ign/node2-install.ign ../images/config-192.168.40.42.ign
cp ign/node3-install.ign ../images/config-192.168.40.43.ign
if [ ! -z "$1" ]; then
  echo "Setting bootstrap for node $1"
  if [ "$1" == "node1" ]; then
    cp ign/node1-bootstrap.ign ../images/config-192.168.40.41.ign
  elif [ "$1" == "node2" ]; then
    cp ign/node2-bootstrap.ign ../images/config-192.168.40.42.ign
  elif [ "$1" == "node3" ]; then
    cp ign/node3-bootstrap.ign ../images/config-192.168.40.43.ign
  else
    echo "WARNING: node $1 not found, no bootstrap set"
  fi
fi
