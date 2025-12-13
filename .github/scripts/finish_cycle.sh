#!/bin/bash
# finish_cycle.sh - Creates PACKAGES index and preserves old packages
# Usage: ./finish_cycle.sh <build-id> <old-packages-url> <container-image>

if [ $# -ne 3 ]; then
    echo "Error: Invalid arguments"
    echo "Usage: $0 <build-id> <old-packages-url> <container-image>"
    exit 1
fi

sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-' | tr -cd '[:alnum:]-'
}

truncate_build_id() {
    local full_id="$1"
    local version_suffix="${full_id: -3}"
    local date_part=$(echo "$full_id" | cut -d'-' -f1-3 | tr -d '-')
    local container_hint=$(echo "$full_id" | sed 's/^[0-9-]*-[0-9]*-//' | sed 's/-[^-]*$//' | cut -c1-4)
    echo "${date_part}-${container_hint}-${version_suffix}"
}

BUILD_ID=$(sanitize_name "$1")
BUILD_ID_SHORT=$(truncate_build_id "$BUILD_ID")
OLD_URL=$2
CONTAINER=$3
NAMESPACE="ns-${BUILD_ID}"
PVC_NAME="pvc-${BUILD_ID_SHORT}"

# First create rclone config secret if not exists
echo "Creating rclone config secret..."
TMPFILE=$(mktemp)
echo "$RCLONE_CONF" > "${TMPFILE}"
kubectl create secret generic rclone-config \
  --from-file=rclone.conf="${TMPFILE}" \
  -n ${NAMESPACE} || true
rm -f "${TMPFILE}"

# Create the indexing job
echo "Creating package indexing job..."
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: index-pkg-${BUILD_ID_SHORT}
  namespace: ${NAMESPACE}
spec:
  template:
    metadata:
      labels:
        app: bioc-indexer
        build-id: ${BUILD_ID_SHORT}
    spec:
      initContainers:
      - name: package-indexer
        image: ${CONTAINER}
        command: ["/bin/bash", "-c"]
        args:
        - |
          set -euxo pipefail
          mkdir -p /tmp/pkglinks
          cd /mnt/tarballs
          
          # Link new packages
          for tarball in *.tar.gz; do
            [ -f "\$tarball" ] && ln -s "/mnt/tarballs/\$tarball" "/tmp/pkglinks/\$tarball"
            [ -f "\$tarball" ] && echo "\${tarball%%_*}" >> /tmp/new_packages.txt
          done
          
          # Handle old packages if URL provided
          if [ -n "${OLD_URL}" ] && curl -sfL "${OLD_URL}" -o /tmp/old_packages; then
            mkdir -p /tmp/pkglinks
            # Remove pattern where there is a newline between the 'File:' and filename
            sed -i -z 's/\n[[:space:]]\+/ /g' /tmp/old_packages
        
            grep "^Package:" /tmp/old_packages | cut -d' ' -f2 > /tmp/old_packages.txt
        
            comm -23 <(sort /tmp/old_packages.txt) <(sort /tmp/new_packages.txt) | while read -r pkg; do
              # Escape the package name for use in a regex
              pkg_escaped=\$(printf '%s' "\$pkg" | sed 's/[][\\.^\$*]/\\\\&/g')
              pkg_pattern="\${pkg_escaped}_.*\.tar\.gz"

              old_tarball=\$(grep -E "\$pkg_pattern" /tmp/old_packages | grep "^File:" | cut -d' ' -f2 | head -n1)
        
              if [ -n "\$old_tarball" ]; then
                old_url_base="${OLD_URL%/*}"
                curl -sfL "\$old_url_base/\$old_tarball" -o "/tmp/pkglinks/\$(basename "\$old_tarball")"
              fi
            done
          fi
          
          # Generate index
          cd /tmp/pkglinks
          Rscript -e 'tools::write_PACKAGES(".", addFiles = TRUE, verbose = TRUE, latestOnly = TRUE)'
          cp PACKAGES* /mnt/tarballs/

          # Get container name
          CONTAINER_NAME=""
          if [ -f "/mnt/container_name" ]; then
            CONTAINER_NAME=\$(cat /mnt/container_name)
          else
            # Try to get from environment variables
            CONTAINER_NAME=\${BIOCONDUCTOR_NAME:-\${TERRA_R_PLATFORM:-bioconductor_docker}}
          fi
          echo "\$CONTAINER_NAME" > /mnt/container_name_for_sync
        volumeMounts:
        - name: bioc-data
          mountPath: /mnt
      containers:
      - name: rclone-sync
        image: rclone/rclone:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -x
          DEST_PATH="final:/bioconductor-packages/\$(cat /mnt/bioc_version)/container-binaries/\$(cat /mnt/container_name_for_sync)/src/contrib"
          
          # First pass: Copy all tarballs
          echo "=== First pass: Copying tarballs ==="
          rclone copy --verbose --progress --include "*.tar.gz" /mnt/tarballs/ "\${DEST_PATH}/"
          
          # Second pass: Copy entire directory (catches PACKAGES files and any missed tarballs)
          echo "=== Second pass: Syncing entire directory ==="
          rclone copy --verbose --progress /mnt/tarballs/ "\${DEST_PATH}/"
          
          echo "=== Sync complete ==="
        volumeMounts:
        - name: bioc-data
          mountPath: /mnt
        - name: rclone-config
          mountPath: /config/rclone
          readOnly: true
        env:
        - name: RCLONE_CONFIG
          value: /config/rclone/rclone.conf
      volumes:
      - name: bioc-data
        persistentVolumeClaim:
          claimName: ${PVC_NAME}
      - name: rclone-config
        secret:
          secretName: rclone-config
          items:
          - key: rclone.conf
            path: rclone.conf
      restartPolicy: OnFailure
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
EOF

echo "Waiting for indexing to complete..."
# Wait for init container to finish
kubectl wait --for=condition=initialized=true pod \
  -l job-name=index-pkg-${BUILD_ID_SHORT} \
  -n ${NAMESPACE} --timeout=7200s || ( echo 'Error waiting for init container' && exit 1 )

# Wait for rclone-sync container to be running before copying files
echo "Waiting for rclone-sync container to start..."
kubectl wait --for=jsonpath='{.status.containerStatuses[?(@.name=="rclone-sync")].state.running}' pod \
  -l job-name=index-pkg-${BUILD_ID_SHORT} \
  -n ${NAMESPACE} --timeout=3600s || ( echo 'Warning: rclone-sync container not running yet' )

# Copy PACKAGES file and save stats
echo "Copying PACKAGES and saving stats..."
POD_NAME=$(kubectl get pod -n ${NAMESPACE} -l job-name=index-pkg-${BUILD_ID_SHORT} -o name | cut -d/ -f2)
kubectl cp ${NAMESPACE}/${POD_NAME}:/mnt/tarballs/PACKAGES PACKAGES
PKG_COUNT=$(grep -c '^Package:' "PACKAGES")
echo "${PKG_COUNT}" > "indexed_packages_count"

# Record completion time
TZ=EST date '+%Y-%m-%d %H:%M:%S %Z' > "cycle_complete_time"

# Wait for final sync to complete
echo "Waiting for rclone sync to complete..."
kubectl wait --for=condition=complete job/index-pkg-${BUILD_ID_SHORT} \
  -n ${NAMESPACE} --timeout=14400s

echo "Package indexing and sync completed for build: ${BUILD_ID} (namespace: ${NAMESPACE}) with ${PKG_COUNT} packages"
