# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

### Four-Phase Pipeline

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
   - Prepares for admin user creation (managed by cloud-init)
   - Configures SysVinit services (not systemd)
   - Adds serial console to `/etc/inittab`
   - Validates configuration (packages, groups, cloud-init syntax)
   - Cleans up logs and machine-id

3. **Uploader** (`src/uploader.coffee`)
   - Converts raw image to VMDK streamOptimized format (~50% compression)
   - Uploads to S3
   - Creates EC2 import-snapshot task
   - Polls for completion (10-30 minutes typical)
   - Registers snapshot as AMI with ENA support

4. **Smoke Test** (`src/smoke-test.coffee`)
   - Launches test instance in default VPC
   - Waits for cloud-init to complete
   - Verifies SSH connectivity
   - Verifies network (eth0 has IP, internet reachable)
   - Verifies sudo access for admin user
   - Automatically cleans up all test resources

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
