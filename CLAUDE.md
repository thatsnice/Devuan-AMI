# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Resume here: ON HOLD since 2026-10-07

Robert put this project on hold on 2026-10-07 so he can focus on the venture
with Jamin. It will likely be back in scope later. A Claude session wrote this
note on 2026-10-09 while reconciling work from Robert's laptop and desktop.

**State.** `main` has fixes for two AMI bugs. No build has verified either yet:
- Root fs didn't grow to fill a larger volume, because `growpart` was missing
  (`7edeb51`). Reported by thunder-mountain on 2026-10-02.
- The cloud-init network stage raced `cloud-init-local` and was skipped
  roughly 1 boot in N, so user-data never ran (`f6a60ff`). Hit
  RentCoordinator from 2026-06-10 to 06-12.

The latest AMI is `ami-0981e1199de28a49f` (us-west-2, built 2026-06-13). It
has an earlier version of the race fix and no `growpart`. Its smoke test
passed once.

**Next step.** Build a new AMI, then run the smoke test several times
(5 to 10 launches), because one passing run can't rule out an intermittent
race. Then point `create-instance` at the new AMI. It still names
`ami-03a3c3aebfb1434b4`.

**Known bugs and open questions**
- `npm test`: 6 of the 8 tests in `test/app.test.coffee` fail on `main`.
  The CLI's ProcessExit is thrown asynchronously, after each test has
  ended. This failure predates 2026-10-09.
- An uncommitted June change added `locales-all`. It was dropped on
  2026-10-09: cloud-init depends on `locales`, so `configureLocale`'s
  `locale-gen` already produces `en_US.UTF-8`. Nobody recorded why it was
  added. Re-add it if a build shows locale warnings.
- Feedback from users of the AMI (thunder-mountain, 2026-10-02): `dig`
  (dnsutils) and `rsync` are not installed, and Debian's `caddy` package
  has no SysVinit script.
- Workaround for instances from older AMIs that skip the network stage:
  ```
  sudo /usr/bin/cloud-init init
  sudo rm -f /var/lib/cloud/instances/*/sem/config_scripts_user
  sudo /usr/bin/cloud-init modules --mode final
  ```
  The full incident write-up was `obsolete-FIXME.md`; see git history
  before this note.

## Project Overview

Creates Devuan AWS Machine Images (AMIs) for EC2 using debootstrap. Built in CoffeeScript as a CLI tool that can be packaged as a .deb for distribution.

## Language and Style

- **Primary Language:** CoffeeScript (not TypeScript or JavaScript)
- **Main Entry Point:** `bin/devuan-ami` (Node.js wrapper) → `src/app.coffee`
- **Module System:** CommonJS (`require`/`module.exports`)
- **Process Injection:** Process object injected for testability via `main(process)`

## Development Commands

### Running Locally
```bash
# Install dependencies
npm install

# Run directly (requires root)
sudo bin/devuan-ami --help

# Or via coffee
sudo coffee src/app.coffee
```

### Building
```bash
# Compile CoffeeScript to JavaScript
npm run build
```

### Usage
```bash
sudo devuan-ami \
  --release excalibur \
  --arch amd64 \
  --s3-bucket my-bucket \
  --region us-east-1 \
  --name "Devuan Excalibur"
```

## Architecture

### Three-Phase Pipeline

1. **Builder** (`src/builder.coffee`)
   - Creates raw disk image with `qemu-img`
   - Sets up loop device and partitions disk (single root partition)
   - Creates ext4 filesystem
   - Runs `debootstrap` to install Devuan from upstream mirrors
   - Installs: cloud-init, openssh-server, grub-pc, linux-image-cloud-amd64

2. **Configurator** (`src/configurator.coffee`)
   - Mounts image and chroots into it
   - Configures fstab, network (via cloud-init), SSH
   - Installs GRUB bootloader with serial console support
   - Creates admin user (managed by cloud-init)
   - Configures SysVinit services (not systemd)
   - Adds serial console to `/etc/inittab`
   - Cleans up logs and machine-id

3. **Uploader** (`src/uploader.coffee`)
   - Converts raw image to VMDK format
   - Uploads to S3
   - Creates EC2 import-snapshot task
   - Polls for completion (10-30 minutes typical)
   - Registers snapshot as AMI with ENA support

### Devuan-Specific Details

- **Init System:** SysVinit (NOT systemd)
  - Use `update-rc.d` instead of `systemctl`
  - Configure `/etc/inittab` for serial console
  - No systemd unit files

- **Cloud Integration:** cloud-init (available in Devuan repos)
  - Handles user creation, SSH keys, network config
  - EC2 datasource configured in `/etc/cloud/cloud.cfg.d/99-aws.cfg`

- **Mirrors:** Pulls from `http://deb.devuan.org/merged` (future-proof)

### Current Scope

- **Instance Type:** HVM only (modern standard, PV is deprecated)
- **Architecture:** x86_64 (amd64); ARM64 planned for future
- **Root Volume:** EBS-backed only; instance-store can be added if requested
- **Bootloader:** GRUB with serial console for AWS debugging

## Recent Changes (2025-10-28)

### Locale Configuration Fix
Fixed cloud-init locale warning by adding `configureLocale()` method to `src/configurator.coffee`:
- Generates `en_US.UTF-8` locale during image build
- Creates `/etc/locale.gen` with `en_US.UTF-8 UTF-8` enabled
- Runs `locale-gen` in chroot to generate the locale
- Sets `/etc/default/locale` to `LANG=en_US.UTF-8`
- Eliminates "invalid locale settings" warning during cloud-init execution

**Changes made:**
- Added `@configureLocale()` call to `configure()` method (line 24)
- Implemented `configureLocale()` method (lines 97-120)

## System Requirements

Must run as root. Requires system packages:
- `debootstrap` - Debian/Devuan bootstrap tool
- `qemu-utils` - For disk image creation (`qemu-img`)
- `awscli` - AWS CLI for S3 upload and AMI registration
- `parted` - Disk partitioning
- `losetup` - Loop device management

## Future: Debian Package

Plan to create `.deb` package structure:
```
DEBIAN/
  control       # Package metadata
  postinst      # Dependency checks
usr/bin/
  devuan-ami    # CLI wrapper
usr/lib/devuan-ami/
  (compiled JS or source)
```

Users install with: `sudo dpkg -i devuan-ami_0.1.0_all.deb`
