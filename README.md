# Talos Linux with UFS Support (customized fork)

Automated builds of [Talos Linux](https://www.talos.dev/) with UFS (Universal Flash Storage) driver support for x86_64 devices.

Standard Talos Linux does not include UFS drivers, making it impossible to install on devices with UFS storage. This project provides custom builds with UFS drivers built into the kernel and an enlarged EFI partition for 4096-byte sector compatibility.

> **This is a fork of [amoyrtil/talos-ufs](https://github.com/amoyrtil/talos-ufs).** In addition to the upstream UFS patches, this fork's `build.yml` bakes a configurable set of [Talos system extensions](https://github.com/siderolabs/extensions) directly into both the boot ISO **and** the installer image, since custom (non-Image-Factory) Talos images don't support the usual schematic-ID based extension selection. See [System Extensions](#system-extensions) below.

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
| Beelink EQi Wildcat Lake Core 3 304 | Intel Wildcat Lake Core 3 304 | 512GB UFS 3.1 | ✅ Verified |

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
    image: ghcr.io/revog/talos-ufs-installer:<version>
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
| `ghcr.io/revog/talos-ufs-installer:<version>` | Installer for machine config — includes any configured system extensions |
| `ghcr.io/revog/talos-ufs-imager:<version>` | Generate custom ISOs with system extensions |
| `ghcr.io/revog/talos-ufs-kernel:<version>` | Custom kernel with UFS drivers |

## System Extensions

Because this is a custom build (not served through Image Factory), the usual approach of appending an extensions schematic to an official installer image doesn't apply. Instead, extensions are baked directly into the release artifacts by the `build.yml` workflow itself, in two places:

1. The **ISO** (`metal-amd64.iso`) — so extensions are already active in maintenance mode / on first boot.
2. The **installer image** (`ghcr.io/revog/talos-ufs-installer:<version>`) — the image referenced by `machine.install.image` and used for `talosctl upgrade`. This is the important one: without it, extensions would be lost again on the next upgrade.

### Configuring extensions for automated (scheduled) builds

Set a repository variable once — *Settings → Secrets and variables → Actions → Variables* — named `SYSTEM_EXTENSIONS`, one extension image reference per line, e.g.:

```
ghcr.io/siderolabs/iscsi-tools:v0.2.0
ghcr.io/siderolabs/util-linux-tools:2.42.2
```

`check-release.yml` reads this variable and passes it to `build.yml` on every daily run, so newly published upstream Talos releases automatically get built with these extensions included.

### Configuring extensions for a manual build

Go to *Actions → Build Talos UFS → Run workflow* and fill in the `system_extensions` field (same one-per-line format) alongside `talos_version`.

### Building an ISO with extensions manually (local, one-off)

You can still generate a one-off ISO locally without touching the workflow, same as upstream:

```bash
docker run --rm -t -v /dev:/dev --privileged \
  ghcr.io/revog/talos-ufs-imager:<version> \
  metal --system-extension-image <extension-image>
```

This only affects the ISO, not the installer image — use the workflow's `system_extensions` input if you also need the extension present after an upgrade.

## Changes from Upstream

1. **Kernel**: UFS drivers built-in (`CONFIG_SCSI_UFSHCD=y`, `CONFIG_SCSI_UFS_BSG=y`, `CONFIG_SCSI_UFS_HWMON=y`, `CONFIG_SCSI_UFSHCD_PCI=y`) with required dependencies (`CONFIG_PM_DEVFREQ`, `CONFIG_PM_OPP`)
2. **EFI Partition**: Size increased from 100MiB to 512MiB for FAT32 compatibility with 4096-byte sectors
3. **System Extensions** *(this fork)*: `build.yml` accepts a `system_extensions` input and bakes the listed extension images into both the generated ISO and the installer image — see [System Extensions](#system-extensions)

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

To build a local installer image with extensions instead (step 6 variant, once imager is pushed):

```bash
mkdir -p output
docker run --rm -t -v $(pwd)/output:/out --privileged \
  localhost:5005/siderolabs/imager:<tag> \
  installer --system-extension-image ghcr.io/siderolabs/iscsi-tools:v0.14.0
# Inspect output/, then docker load / tag / push as needed
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

### FAT32 errors on EFI partition

The default 100MiB EFI partition is too small for 4096-byte sector devices. This build increases it to 512MiB. If you see FAT32-related errors, ensure you're using this custom build.

### Kernel config changes not reflected in ISO

Docker Buildx may cache kernel build layers. Always use `--no-cache` when building the kernel after config changes.

### "TLS config specified for non-HTTPS registry"

When using a local HTTP registry, only configure `mirrors` in machine config. Do not add `config.tls.insecureSkipVerify` for HTTP registries.

### `make installer` fails with `open /out/installer-<arch>.tar: permission denied`

Talos v1.13 changed the `image-%` Makefile target to run the imager container with `--user $(id -u):$(id -g)` (instead of `--privileged`). If `_out` does not exist beforehand, Docker auto-creates it as `root` via the volume mount, and the container running as the host user cannot write to it. `mkdir -p _out` in the Talos source directory before invoking `make installer` resolves the issue.

### `system_extensions` build step doesn't find an installer tarball

The "Rebuild installer with system extensions" step in `build.yml` looks for a `*.tar` file under `_out_ext/`. If the imager build for this Talos version names its output differently, run `docker run --rm ghcr.io/revog/talos-ufs-imager:<version> --help` locally to check the exact `installer` subcommand output path/flags and adjust the step accordingly.

## How It Works

This project uses GitHub Actions to:

1. **Monitor upstream releases** (`check-release.yml`): Daily check for new stable Talos releases; passes the `SYSTEM_EXTENSIONS` repository variable through to `build.yml`
2. **Build custom images** (`build.yml`): Apply patches, build kernel, imager, installer (with any configured system extensions), and generate the ISO (also with extensions)
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