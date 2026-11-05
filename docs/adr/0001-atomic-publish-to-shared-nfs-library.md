# 0001. Publish packages to the shared NFS library by atomic rename

- **Status:** Proposed
- **Date:** 2026-11-05
- **Deciders:** Marcel Ramos

## Context and Problem Statement

Each build cycle mounts one ReadWriteMany NFS volume (`nfs-client`
StorageClass) at `/mnt` in every build pod. Pods install their package into a
pod-local library (`/tmp/library`) with `/mnt/library` second on
`.libPaths()`, then copy every newly installed package into `/mnt/library`
so later builds can reuse it.

The dependency graph (`deps_json.R`) contains only BioCsoft packages.
Annotation and experiment data packages, such as `EnsDb.Hsapiens.v86`, are not
scheduled; whichever build first needs one installs it on demand
(`dependencies = TRUE`). When several concurrent builds need the same
annotation package, each installs it locally and then ran
`cp -r <pkg> /mnt/library/`. If the directory already existed, `cp` truncated
and rewrote its files **in place**, including SQLite databases that other pods
had open or memory-mapped at the time.

In the 2026-11-02 cycles, after an NFS server stall, pods hung for days in
uninterruptible I/O. After their pods were replaced, the new `chevreulPlot`
and `RITAN` pods froze again at the same log line, both blocked reading
`/mnt/library/EnsDb.Hsapiens.v86/extdata/EnsDb.Hsapiens.v86.sqlite`. Because
each build pod requests 1 CPU on a single 8-CPU node, four hung pods
blocked roughly 150 queued builds.

How should pods add packages to the shared library so that a package
directory other pods may be reading is never modified?

## Decision

A package directory in `/mnt/library` is immutable once published. Pods
publish with a copy-then-rename protocol (`publish_pkg` in
`.github/scripts/dispatch_k8s_job.sh`):

1. If `/mnt/library/<pkg>` already exists and `<pkg>` is not the package
   this job builds, skip it. The first published copy wins.
2. Otherwise copy to a hidden staging directory
   `/mnt/library/.staging-<pkg>-<pod>` on the same filesystem.
3. For the job's own package only (a retry after a partial publish), rename
   the existing directory aside to `.old-<pkg>-<pod>`.
4. `mv -T` the staging directory to `/mnt/library/<pkg>`. `rename(2)` is
   atomic on one NFS export and refuses to replace a non-empty directory,
   so if another pod published first, discard the staging copy.
5. Remove `.old-*` best effort; open files keep it busy on NFS until closed.

Hidden names are ignored by R's library scanning (`list.files()` excludes dot
files), so staging directories are never seen as installed packages.

The same stage-then-rename approach applies to tarballs in `/mnt/tarballs`
and logs in `/mnt/logs`, so `finish_cycle` and `handle_k8s_jobs.sh` never
read a partially written file.

## Alternatives Considered

- **Keep `cp -r` but take a lock (`flock`) per package.** NFS locking with
  `local_lock=none` goes through the server and is exactly what fails during
  an NFS stall; a held lock from a hung pod would block every other pod.
  Rename needs no lock state.
- **`rsync` / `cp --remove-destination`.** Replaces files individually (new
  inodes), which protects open file handles but still exposes a
  half-updated package directory to concurrent `library()` calls.
- **Pre-install annotation and data packages before dispatching builds.**
  Removes the concurrent-install race at its source and is worth doing as a
  follow-up, but it requires computing the non-software dependency set and a
  seeding step in `setup_k8s.sh`. It also does not protect retries of
  software packages. Complementary, not a replacement.
- **No shared library; every pod installs all dependencies locally.** No
  shared mutable state, but multiplies install time and network traffic per
  build by the dependency depth, which defeats the dependency-ordered
  scheduling.

## Consequences

- Readers never see a truncated or half-written package, tarball, or log.
  An in-progress `library()` keeps reading the old inodes even when a package
  is replaced.
- A dependency is never refreshed by a later build in the same cycle; the
  first successful copy is used for the rest of the cycle. That matches the
  existing intent (one build per cycle), but if a dependency was published
  broken, it must be deleted from `/mnt/library` by hand.
- Interrupted pods can leave `.staging-*` or `.old-*` directories in
  `/mnt/library`. They are invisible to R and harmless, but they use space
  until the volume is deleted with the namespace at the end of the cycle.
- This does not fix an unhealthy NFS server. The companion change, a
  pod-level `activeDeadlineSeconds` on build Jobs (default 3600 s, the BBS
  `INSTALL_timeout` for bioc software builds), makes hung builds fail and
  retry rather than holding a CPU slot indefinitely.
