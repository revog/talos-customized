# Talos Linux with UFS Support

Automated builds of [Talos Linux](https://www.talos.dev/) with UFS (Universal Flash Storage) driver support for x86_64 devices.

Standard Talos Linux does not include UFS drivers, making it impossible to install on devices with UFS storage. This project provides custom builds with UFS drivers built into the kernel and an enlarged EFI partition for 4096-byte sector compatibility.

## Supported Hardware

All x86_64 devices with PCI-connected UFS controllers supported by the Linux `ufshcd-pci` driver:

| Vendor | Device ID | Description |
|--------|-----------|-------------|
| Intel | 0x54FF | Alder Lake-N UFS Controller |
| Intel | 0x4B41, 0x4B43 | Elkhart Lake UFS |
| Qualcomm | Various | Qualcomm UFS controllers |

### Verified Devices

| Device | CPU | UFS | Status |
|--------|-----|-----|--------|
| MINISFORUM S100-WLP | Intel N100 (Alder Lake-N) | 256GB UFS 2.1 | ✅ Verified |

We welcome hardware compatibility reports! See [Contributing](#contributing).

## Quick Start

### 1. Download and Boot

Download `metal-amd64.iso` from the [latest release](../../releases/latest), write it to a USB drive, and boot your device with Secure Boot disabled.

### 2. Verify UFS Detection

Once the device enters Talos maintenance mode, confirm UFS storage is detected:

```bash
talosctl get disks --insecure --nodes <IP>
```

### 3. Generate and Apply Config

```bash
talosctl gen config my-cluster https://<CONTROL_PLANE_IP>:6443
```

Edit the generated config to use the UFS installer:

```yaml
machine:
  install:
    disk: /dev/sda  # Your UFS device
    image: ghcr.io/amoyrtil/talos-ufs-installer:<version>
```

Apply and bootstrap:

```bash
talosctl apply-config --insecure --nodes <IP> --file controlplane.yaml
talosctl bootstrap --nodes <IP>  # After reboot
```

For detailed installation steps, see the [Talos Getting Started Guide](https://www.talos.dev/latest/introduction/getting-started/).

## Container Images

Each release publishes three container images:

| Image | Purpose |
|-------|---------|
| `ghcr.io/amoyrtil/talos-ufs-installer:<version>` | Installer for machine config |
| `ghcr.io/amoyrtil/talos-ufs-imager:<version>` | Generate custom ISOs with system extensions |
| `ghcr.io/amoyrtil/talos-ufs-kernel:<version>` | Custom kernel with UFS drivers |

## Custom ISO Generation

Use the published imager to generate ISOs with system extensions:

```bash
docker run --rm -t -v /dev:/dev --privileged \
  ghcr.io/amoyrtil/talos-ufs-imager:<version> \
  metal --system-extension-image <extension-image>
```

## Changes from Upstream

1. **Kernel**: UFS drivers built-in (`CONFIG_SCSI_UFSHCD=y`, `CONFIG_SCSI_UFS_BSG=y`, `CONFIG_SCSI_UFS_HWMON=y`, `CONFIG_SCSI_UFSHCD_PCI=y`) with required dependencies (`CONFIG_PM_DEVFREQ`, `CONFIG_PM_OPP`)
2. **EFI Partition**: Size increased from 100MiB to 512MiB for FAT32 compatibility with 4096-byte sectors
3. **Module list**: The UFS and `governor_simpleondemand` entries are removed from Talos's `hack/modules-amd64.txt`, since those drivers are built-in here and the `.ko` files upstream expects do not exist

## Local Build

### Prerequisites

- Docker with Buildx support
- GNU Make (`brew install make` on macOS, use `gmake`)
- ~50GB free disk space
- ~4-6 hours build time (kernel build is the bottleneck)

### Build Steps

```bash
# 1. Set up a local registry
docker run -d -p 5005:5000 --name registry registry:2

# 2. Configure buildx for insecure local registry
cat > /tmp/buildkitd.toml << 'EOF'
[registry."host.docker.internal:5005"]
  http = true
  insecure = true
[registry."localhost:5005"]
  http = true
  insecure = true
EOF

docker buildx create --name talos-builder --driver docker-container \
  --driver-opt network=host --config /tmp/buildkitd.toml --use

# 3. Clone repositories
git clone --branch <talos-version> https://github.com/siderolabs/talos.git /tmp/talos
# Resolve pkgs version: grep '^PKGS ?=' /tmp/talos/Makefile
git clone --branch <pkgs-version> https://github.com/siderolabs/pkgs.git /tmp/pkgs

# 4. Apply patches
./scripts/apply-patches.sh /tmp/pkgs /tmp/talos

# 5. Build kernel (2-3 hours)
cd /tmp/pkgs
docker buildx build --no-cache --file=Pkgfile --platform=linux/amd64 \
  --target=kernel --tag=localhost:5005/siderolabs/kernel:custom --push .

# 6. Build imager, installer-base, and installer
cd /tmp/talos

# Pre-create the artifacts directory. Talos v1.13+ runs the imager container as
# the host user (--user $(id -u):$(id -g)); if _out is auto-created by the
# docker volume mount it will be owned by root and the installer build will
# fail with "permission denied" when writing installer-<arch>.tar.
mkdir -p _out

gmake imager \
  PKG_KERNEL=host.docker.internal:5005/siderolabs/kernel:custom \
  PLATFORM=linux/amd64 REGISTRY=localhost:5005 PUSH=true INSTALLER_ARCH=amd64

gmake installer-base \
  PKG_KERNEL=host.docker.internal:5005/siderolabs/kernel:custom \
  PLATFORM=linux/amd64 REGISTRY=localhost:5005 PUSH=true INSTALLER_ARCH=amd64

gmake installer \
  PKG_KERNEL=host.docker.internal:5005/siderolabs/kernel:custom \
  PLATFORM=linux/amd64 REGISTRY=localhost:5005 PUSH=true INSTALLER_ARCH=amd64

# 7. Generate ISO
mkdir -p output
docker run --rm --platform linux/amd64 -v $(pwd)/output:/out --privileged \
  localhost:5005/siderolabs/imager:<tag> iso --arch amd64

# 8. Verify UFS drivers are included
./scripts/verify-build.sh output/metal-amd64.iso
```

## Troubleshooting

### UFS storage not detected after booting ISO

Verify the ISO contains UFS drivers:

```bash
./scripts/verify-build.sh metal-amd64.iso
```

Expected output should show `ufshcd-core.ko` and `ufshcd-pci.ko` in `modules.builtin`.

### UFS drivers built as modules (=m) don't work

Talos does not auto-load kernel modules in maintenance mode unless they are listed in `hack/modules-amd64.txt`. UFS drivers must be built-in (`=y`), not modules.

### `install: cannot stat '.../ufshcd-core.ko'` during the imager build

Talos stages every module listed in `hack/modules-amd64.txt` into the initramfs and fails if one is missing. Upstream lists the UFS drivers there, but this build makes them built-in, so the `.ko` files never exist. `scripts/apply-patches.sh` removes those entries — make sure it ran against the Talos checkout.

### FAT32 errors on EFI partition

The default 100MiB EFI partition is too small for 4096-byte sector devices. This build increases it to 512MiB. If you see FAT32-related errors, ensure you're using this custom build.

### Kernel config changes not reflected in ISO

Docker Buildx may cache kernel build layers. Always use `--no-cache` when building the kernel after config changes.

### "TLS config specified for non-HTTPS registry"

When using a local HTTP registry, only configure `mirrors` in machine config. Do not add `config.tls.insecureSkipVerify` for HTTP registries.

### `make installer` fails with `open /out/installer-<arch>.tar: permission denied`

Talos v1.13 changed the `image-%` Makefile target to run the imager container with `--user $(id -u):$(id -g)` (instead of `--privileged`). If `_out` does not exist beforehand, Docker auto-creates it as `root` via the volume mount, and the container running as the host user cannot write to it. `mkdir -p _out` in the Talos source directory before invoking `make installer` resolves the issue.

## How It Works

This project uses GitHub Actions to:

1. **Monitor upstream releases** (`check-release.yml`): Daily check for new stable Talos releases
2. **Build custom images** (`build.yml`): Apply patches, build kernel, imager, installer, and generate ISO
3. **Test patches** (`test.yml`): Validate patches apply cleanly on PRs, with optional kernel build

The pkgs version is automatically resolved from the Talos `Makefile` (`PKGS ?=` variable) to ensure the custom kernel is built against the exact version Talos expects.

## Contributing

### Hardware Reports

If you have a UFS-equipped x86_64 device, please report compatibility:

1. Open an [Issue](../../issues/new) with:
   - Device name and model
   - Output of `lspci -nn | grep -i ufs`
   - UFS storage capacity and model
   - Whether Talos installed and booted successfully

### Patch Updates

When upstream Talos changes break patches:

1. Clone this repo and the upstream repos
2. Update patch files in `patches/`
3. Test with `./scripts/apply-patches.sh`
4. Submit a PR (patches are automatically validated)

## License

[MPL-2.0](LICENSE) (matching Talos Linux)
