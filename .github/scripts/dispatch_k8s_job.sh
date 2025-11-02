#!/bin/bash
# dispatch_k8s_job.sh - Creates and deploys a Kubernetes Job for R package installation
# Usage: ./dispatch_k8s_job.sh <package-name> <container-image> <pvc-name> <build-id>

# Validate input parameters
if [ $# -ne 4 ]; then
    echo "Error: Invalid arguments"
    echo "Usage: $0 <package-name> <container-image> <pvc-name> <build-id>"
    exit 1
fi

# Sanitize names for DNS compliance (replace dots with hyphens, lowercase, remove special chars)
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

PKG_SAFE=$(sanitize_name "$1")
PKG=$1
CONTAINER=$2
PVC=$3
BUILD_ID=$(sanitize_name "$4")
BUILD_ID_SHORT=$(truncate_build_id "$BUILD_ID")
NAMESPACE="ns-${BUILD_ID}"

# Record dispatched package
mkdir -p "logs"
echo "$PKG" >> "logs/dispatched-packages.txt"

# Create Kubernetes Job manifest using heredoc
cat << EOF | kubectl apply -n ${NAMESPACE} -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: pkg-${PKG_SAFE}-${BUILD_ID_SHORT}
  namespace: ${NAMESPACE}
  labels:
    app: bioc-builder
    pkg: ${PKG}
    build-id: ${BUILD_ID_SHORT}
spec:
  backoffLimit: 5
  template:
    metadata:
      labels:
        app: bioc-builder
        pkg: ${PKG}
        build-id: ${BUILD_ID_SHORT}
    spec:
      containers:
      - name: bioc-builder
        image: ${CONTAINER}
        imagePullPolicy: Always
        resources:
          requests:
            cpu: "1"
            memory: "4Gi"
        command: ["/bin/bash", "-c"]
        args:
        - |
          set -euxo pipefail
          export TEMP_LIBRARY="/tmp/library"
          export SHARED_LIBRARY="/mnt/library"
          export TARDIR="/mnt/tarballs"
          export LOGDIR="/mnt/logs"
          
          # Create directories
          mkdir -p \${TARDIR} \${LOGDIR} \${TEMP_LIBRARY} \${SHARED_LIBRARY}
          
          # Record initial temp library state (should be empty)
          ls -1 \${TEMP_LIBRARY} > /tmp/initial_libs.txt || touch /tmp/initial_libs.txt
          
          # Install package using both libraries (temp first for new installations)
          cd ~/
          (time Rscript -e "Sys.setenv(BIOCONDUCTOR_USE_CONTAINER_REPOSITORY=FALSE);
            p <- .libPaths();
            p <- c('\${TEMP_LIBRARY}', '\${SHARED_LIBRARY}', p);
            .libPaths(p);
            if(BiocManager::install('${PKG}', INSTALL_opts = '--build', update = TRUE, quiet = FALSE, dependencies=TRUE, force = TRUE, keep_outputs = TRUE) %in% rownames(installed.packages())) q(status = 0) else q(status = 1)" 2>&1 ) 2>&1 | tee \${LOGDIR}/${PKG}.log
          
          # Move new packages to shared library
          cd \${TEMP_LIBRARY}
          ls -1 > /tmp/final_libs.txt
          comm -13 /tmp/initial_libs.txt /tmp/final_libs.txt | while read pkg; do
            if [ -d "\${pkg}" ]; then
              cp -r "\${pkg}" "\${SHARED_LIBRARY}/"
            fi
          done
          
          # Handle build artifacts
          cd ~/
          echo "Tarballs Detected: \$(ls *.tar.gz)"
          mv *.tar.gz \${TARDIR}/
          echo "Build artifacts stored in \${TARDIR}"
        volumeMounts:
        - name: bioc-data
          mountPath: /mnt
      restartPolicy: OnFailure
      volumes:
      - name: bioc-data
        persistentVolumeClaim:
          claimName: ${PVC}
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
EOF

echo "Dispatched job for package: ${PKG} with build-id: ${BUILD_ID_SHORT}"
