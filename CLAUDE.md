# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

talos-ufs builds custom Talos Linux images with UFS (Universal Flash Storage) driver support for x86_64 devices. Standard Talos does not include UFS drivers. The project maintains two patches against upstream siderolabs/talos and siderolabs/pkgs repositories, with automated CI/CD to track upstream releases and produce bootable ISOs and container images.

## Architecture

The build pipeline flows through these stages:

1. **Upstream tracking** — `check-release.yml` runs daily, detects new siderolabs/talos releases, and triggers builds
2. **Patch application** — Two patches modify upstream repos:
   - `patches/kernel-config.patch` → applied to siderolabs/pkgs (`kernel/build/config-amd64`) — enables UFS kernel drivers
   - `patches/efi-partition-size.patch` → applied to siderolabs/talos (`pkg/machinery/imager/quirks/partitions.go`) — increases EFI partition from 100MiB to 512MiB for 4096-byte sector support

   Plus one non-patch edit to siderolabs/talos: the UFS and `governor_simpleondemand` entries are stripped from `hack/modules-amd64.txt`. Talos stages every module in that list into the initramfs and fails if one is missing; those drivers are built-in here, so the `.ko` files upstream expects do not exist. It is a line filter rather than a patch because that 300+ line list is regenerated on every kernel bump, so a context diff would rot immediately.
3. **Build chain** (in `build.yml`): kernel (6h) → talos imager/installer (2h) → ISO generation (30min)
4. **Output** — ISO + checksum published as GitHub Release; container images pushed to GHCR (`ghcr.io/amoyrtil/talos-ufs-{kernel,imager,installer}`)

The pkgs version is resolved from the Talos Makefile at build time (not pinned independently). Build jobs use skopeo to check if images already exist in GHCR and skip redundant builds.

## Key Files

- `patches/` — The two upstream patches (the core of this project)
- `scripts/apply-patches.sh` — Applies patches to cloned upstream repos
- `scripts/verify-build.sh` — Verifies UFS drivers are built-in to a generated ISO
- `.github/workflows/build.yml` — Main build pipeline (4 jobs)
- `.github/workflows/check-release.yml` — Daily upstream release monitor
- `.github/workflows/test.yml` — PR validation (patch applicability + optional full build)

## Testing

**PR validation** (`test.yml` on pull requests):
```bash
# What CI does: validates patches apply cleanly against latest upstream
git apply --3way --check <patch>

# Shell script syntax check
bash -n scripts/*.sh
```

A full kernel build test (6h) runs only when patches are changed AND the PR title contains `[full-test]`.

**Build verification:**
```bash
# Verify UFS drivers are present in a built ISO
./scripts/verify-build.sh <iso_path>
```

## Local Build

Requires Docker with Buildx, ~50GB disk, and 8-9 hours total:
```bash
# Start local registry
docker run -d -p 5000:5000 --name registry registry:2

# Clone upstream repos, apply patches
git clone https://github.com/siderolabs/talos.git /tmp/talos
git clone https://github.com/siderolabs/pkgs.git /tmp/pkgs
./scripts/apply-patches.sh /tmp/pkgs /tmp/talos

# Build kernel (in /tmp/pkgs)
make -C /tmp/pkgs kernel PLATFORM=linux/amd64 PUSH=true REGISTRY=localhost:5000 USERNAME=siderolabs

# Build Talos images (in /tmp/talos) — uses INSTALLER_ARCH, PKG_KERNEL, etc.
# Pre-create _out before `make installer`: Talos v1.13+ runs the imager
# container with --user $(id -u):$(id -g), so a docker-auto-created _out
# (owned by root) breaks the installer tarball write.
mkdir -p /tmp/talos/_out
# See README.md "Local Build" section for exact make targets and arguments
```

## Conventions

- Patches use `git diff` format with 3-way merge support (`git apply --3way`)
- Container image tags follow `<talos-version>-ufs` convention
- Build failures auto-create GitHub issues with `patch-failure` label
- CODEOWNERS requires @amoyrtil approval for all changes
