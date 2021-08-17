#!/bin/bash
set -e
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DEPS_DIR="${SCRIPT_DIR}/deps"

## Part 1: Github releases

while read OWNER REPO ASSETRE STREAMRE; do
  if [[ -z "$OWNER" || $OWNER == "#" || $OWNER == "#*" ]]; then
    continue
  fi
  mkdir -p ${DEPS_DIR}/gh/${OWNER}/${REPO}
  cd ${DEPS_DIR}/gh/${OWNER}/${REPO}
  if [[ -z "$STREAMRE" ]]; then
    echo "[*] Getting latest release info for ${OWNER}/${REPO}."
    curl -fsLJ https://api.github.com/repos/${OWNER}/${REPO}/releases/latest > release-cache.json
    RELEASE_NAME=$(jq -r ".name" release-cache.json)
    RELEASE_ASSETS=$(jq -r "if .assets == [] then .tarball_url else .assets[].browser_download_url end|select(test(\"${ASSETRE}\"))" release-cache.json)
  else
    echo "[*] Getting latest release info for stream ${STREAMRE} for ${OWNER}/${REPO}."
    curl -fsLJ https://api.github.com/repos/${OWNER}/${REPO}/releases > release-cache.json
    RELEASE_NAME=$(jq -r "[.[]|select(.name|test(\"${STREAMRE}\"))]|sort_by(.published_at)|reverse|.[0].name" release-cache.json)
    RELEASE_ASSETS=$(jq -r ".[]|select(.name == \"${RELEASE_NAME}\")|if .assets == [] then .tarball_url else .assets[].browser_download_url end|select(test(\"${ASSETRE}\"))" release-cache.json)
  fi
  RELEASE_DIR=$(echo $RELEASE_NAME | sed -e 's/^Release //')
  if [ -d "${RELEASE_DIR}" ]; then
    echo "[-] Release ${RELEASE_DIR} already cached, skipping."
  else
    echo "[*] Downloading new release ${RELEASE_DIR}..."
    mkdir -p "${RELEASE_DIR}"
    cd "${RELEASE_DIR}"
    echo "${RELEASE_ASSETS}" | xargs -I{} sh -c 'curl --progress-meter -fLJO {}'
    echo "[*] New release for ${OWNER}/${REPO} downloaded."
  fi
done < "${DEPS_DIR}/github-deps.txt"

## Part 2: Fedora CoreOS image

DEFAULT_BASE_URL="https://builds.coreos.fedoraproject.org/streams"
STREAM="stable"

echo "[*] Getting latest release info for Fedora CoreOS stream ${STREAM}."
JSON_URL="${DEFAULT_BASE_URL}/${STREAM}.json"
curl -fsLJ -o "${DEPS_DIR}/fcos/stable.json" "${JSON_URL}"
RELVER=$(jq -r '.architectures.x86_64.artifacts.qemu.release' ${DEPS_DIR}/fcos/stable.json)
IMAGE="fedora-coreos-${RELVER}-qemu.x86_64.qcow2"
if [ ! -f "${DEPS_DIR}/fcos/${IMAGE}" ]; then
  echo "[*] Downloading new release ${RELVER}..."
  podman run -it --pull=always --rm \
    -v ${DEPS_DIR}/fcos:/data -w /data \
    quay.io/coreos/coreos-installer:release \
      download -s "${STREAM}" -p qemu -f qcow2.xz --decompress
  chcon -t svirt_home_t ${DEPS_DIR}/fcos/*.qcow2
  echo "[*] New Fedora CoreOS release ${RELVER} downloaded."
else
  echo "[-] Latest Fedora CoreOS release ${RELVER} already cached, skipping."
fi

## Part 3: External resources
while read PROJECT NAME URL SHA512; do
  if [[ -z "$PROJECT" || $PROJECT == "#" || $PROJECT == "#*" ]]; then
    continue
  fi
  echo "[*] Getting resource ${PROJECT}/${NAME}"
  mkdir -p "${DEPS_DIR}/resource/${PROJECT}"
  NEWNAME="${DEPS_DIR}/resource/${PROJECT}/${NAME}.new"
  curl -fsLJ -o "${NEWNAME}" "${URL}"
  SHASUM=$(sha512sum "${NEWNAME}" | awk '{print $1}')
  if [[ ! -f "${DEPS_DIR}/resource/${PROJECT}/${NAME}" ]]; then
    if [[ "$SHASUM" -ne "$SHA512" ]]; then
      echo "[*] Resource ${PROJECT}/${NAME} mismatch, SHA512 ${SHASUM}."
      echo "[=] New version at ${NEWNAME}, please check."
    else
      mv "${NEWNAME}" "${DEPS_DIR}/resource/${PROJECT}/${NAME}"
      echo "[*] Resource ${PROJECT}/${NAME} downloaded."
    fi
  else
    if [[ "$SHASUM" -ne "$SHA512" ]]; then
      echo "[*] Resource ${PROJECT}/${NAME} changed, SHA512 ${SHASUM}."
      echo "[=] New version at ${NEWNAME}, please compare."
    else
      rm "${NEWNAME}"
      echo "[-] Resource ${PROJECT}/${NAME} unchanged."
    fi
  fi
done < "${DEPS_DIR}/resource-deps.txt"
