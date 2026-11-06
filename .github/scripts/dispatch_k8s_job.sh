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

# Tunables (override via environment / GitHub repository variables).
# Pod-level deadline: counts from pod start on the node, not from Job
# creation, so time spent Pending in the scheduling queue is not charged.
# Default matches the Bioconductor Build System INSTALL timeout for bioc
# software builds (Bioconductor/BBS, BBSvars.py: 3600 s). Observed 3.23
# release builds here: p50 ~0.6 min, p99 ~8 min, max ~38 min.
POD_DEADLINE_SECONDS="${BUILD_POD_DEADLINE_SECONDS:-3600}"
CPU_REQUEST="${BUILD_CPU_REQUEST:-1}"
MEMORY_REQUEST="${BUILD_MEMORY_REQUEST:-4Gi}"

if ! [[ "${POD_DEADLINE_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: BUILD_POD_DEADLINE_SECONDS must be a positive integer, got '${POD_DEADLINE_SECONDS}'"
    exit 1
fi

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
      # A build stuck in uninterruptible NFS I/O otherwise holds its CPU
      # request forever and starves the queue; fail it so it is retried
      # (backoffLimit) and eventually reported instead of hanging silently.
      activeDeadlineSeconds: ${POD_DEADLINE_SECONDS}
      containers:
      - name: bioc-builder
        image: ${CONTAINER}
        imagePullPolicy: Always
        resources:
          requests:
            cpu: "${CPU_REQUEST}"
            memory: "${MEMORY_REQUEST}"
        command: ["/bin/bash", "-c"]
        args:
        - |
          set -euxo pipefail
          export TEMP_LIBRARY="/tmp/library"
          export SHARED_LIBRARY="/mnt/library"
          export TARDIR="/mnt/tarballs"
          export LOGDIR="/mnt/logs"
          # Unique per pod; names staging paths on the shared volume.
          STAGE_TAG="\$(hostname)"
          LOCAL_LOG="/tmp/${PKG}.log"

          # Create directories
          mkdir -p \${TARDIR} \${LOGDIR} \${TEMP_LIBRARY} \${SHARED_LIBRARY}

          # Write the build log to local disk while R runs, so an NFS stall
          # cannot block the build's own output; publish it on exit.
          publish_log() {
            if [ -f "\${LOCAL_LOG}" ]; then
              cp "\${LOCAL_LOG}" "\${LOGDIR}/.${PKG}.log.\${STAGE_TAG}" &&
                mv -f "\${LOGDIR}/.${PKG}.log.\${STAGE_TAG}" "\${LOGDIR}/${PKG}.log" || true
            fi
          }
          trap publish_log EXIT

          # Publish a package into the shared library atomically (ADR 0001):
          # copy to a hidden staging dir, then rename into place. Never write
          # into an existing package dir; other pods may have its files open
          # (e.g. EnsDb.* SQLite databases).
          publish_pkg() {
            local name="\$1"
            local dest="\${SHARED_LIBRARY}/\${name}"
            local stage="\${SHARED_LIBRARY}/.staging-\${name}-\${STAGE_TAG}"
            local old="\${SHARED_LIBRARY}/.old-\${name}-\${STAGE_TAG}"
            # Dependencies already published by another job are left alone;
            # only the package this job builds may replace an existing copy.
            if [ -e "\${dest}" ] && [ "\${name}" != "${PKG}" ]; then
              echo "Skipping \${name}: already in shared library"
              return 0
            fi
            rm -rf "\${stage}"
            cp -r "\${TEMP_LIBRARY}/\${name}" "\${stage}"
            if [ -e "\${dest}" ] && [ "\${name}" = "${PKG}" ]; then
              mv -T "\${dest}" "\${old}"
            fi
            if mv -T "\${stage}" "\${dest}"; then
              echo "Published \${name}"
            else
              echo "Skipping \${name}: published concurrently by another job"
              rm -rf "\${stage}"
            fi
            # Best effort: open files in the old copy may keep it busy.
            rm -rf "\${old}" || true
          }

          # Record initial temp library state (should be empty)
          ls -1 \${TEMP_LIBRARY} > /tmp/initial_libs.txt || touch /tmp/initial_libs.txt

          # Install package using both libraries (temp first for new installations)
          cd ~/
          (time Rscript -e "Sys.setenv(BIOCONDUCTOR_USE_CONTAINER_REPOSITORY=FALSE);
            p <- .libPaths();
            p <- c('\${TEMP_LIBRARY}', '\${SHARED_LIBRARY}', p);
            .libPaths(p);
            if(BiocManager::install('${PKG}', INSTALL_opts = '--build', update = TRUE, quiet = FALSE, dependencies=TRUE, force = TRUE, keep_outputs = TRUE) %in% rownames(installed.packages())) q(status = 0) else q(status = 1)" 2>&1 ) 2>&1 | tee \${LOCAL_LOG}

          # Publish newly installed packages to the shared library
          cd \${TEMP_LIBRARY}
          ls -1 > /tmp/final_libs.txt
          comm -13 /tmp/initial_libs.txt /tmp/final_libs.txt | while read -r pkg; do
            if [ -d "\${pkg}" ]; then
              publish_pkg "\${pkg}"
            fi
          done

          # Handle build artifacts: stage then rename so readers of the
          # tarball directory never see a partially written file.
          cd ~/
          echo "Tarballs Detected: \$(ls *.tar.gz)"
          for tarball in *.tar.gz; do
            cp "\${tarball}" "\${TARDIR}/.\${tarball}.\${STAGE_TAG}"
            mv -f "\${TARDIR}/.\${tarball}.\${STAGE_TAG}" "\${TARDIR}/\${tarball}"
            rm -f "\${tarball}"
          done
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
          # Prefer worker nodes, but allow the control-plane node so builds
          # still schedule on single-node clusters.
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
EOF

echo "Dispatched job for package: ${PKG} with build-id: ${BUILD_ID_SHORT}"
