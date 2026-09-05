#!/usr/bin/env bash
set -euo pipefail

# Apply UFS patches to siderolabs/pkgs and siderolabs/talos repositories.
#
# Usage:
#   ./scripts/apply-patches.sh <pkgs_dir> <talos_dir>
#
# Arguments:
#   pkgs_dir  - Path to the cloned siderolabs/pkgs repository
#   talos_dir - Path to the cloned siderolabs/talos repository

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$(cd "${SCRIPT_DIR}/../patches" && pwd)"

PKGS_DIR="${1:?Usage: $0 <pkgs_dir> <talos_dir>}"
TALOS_DIR="${2:?Usage: $0 <pkgs_dir> <talos_dir>}"

apply_patch() {
  local repo_dir="$1"
  local patch_file="$2"
  local repo_name="$3"

  echo "Applying ${patch_file##*/} to ${repo_name}..."

  if ! git -C "${repo_dir}" apply --3way "${patch_file}"; then
    echo "ERROR: Failed to apply ${patch_file##*/} to ${repo_name}" >&2
    echo "The upstream code may have changed. Please update the patch." >&2
    return 1
  fi

  echo "Successfully applied ${patch_file##*/} to ${repo_name}"
}

# Apply kernel config patch to pkgs
apply_patch "${PKGS_DIR}" "${PATCHES_DIR}/kernel-config.patch" "pkgs"

# Apply EFI partition size patch to talos
apply_patch "${TALOS_DIR}" "${PATCHES_DIR}/efi-partition-size.patch" "talos"

# Talos stages every module in hack/modules-amd64.txt into the initramfs and
# fails if one is missing. Upstream builds UFS and the simple-ondemand devfreq
# governor as modules, but kernel-config.patch makes them built-in (=y), so
# those .ko files never exist. Delete the entries by exact path instead of
# shipping a patch: this 300+ line list is regenerated on every kernel bump, so
# a context diff would rot immediately.
echo "Dropping built-in drivers from the talos module list..."
MODULE_LIST="${TALOS_DIR}/hack/modules-amd64.txt"
grep -vE '^kernel/drivers/(ufs/|devfreq/governor_simpleondemand\.ko$)' \
  "${MODULE_LIST}" > "${MODULE_LIST}.tmp"
mv "${MODULE_LIST}.tmp" "${MODULE_LIST}"

echo "All patches applied successfully."
