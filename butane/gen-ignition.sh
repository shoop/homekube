#!/bin/sh
podman run -i --rm -v ${PWD}:/data:Z quay.io/coreos/butane:release --pretty --strict -d /data < node-install.bu > node-install.ign
podman run -i --rm -v ${PWD}:/data:Z quay.io/coreos/butane:release --pretty --strict -d /data < node1-install.bu > node1-install.ign
podman run -i --rm -v ${PWD}:/data:Z quay.io/coreos/butane:release --pretty --strict -d /data < node1-bootstrap.bu > ../images/config.ign
