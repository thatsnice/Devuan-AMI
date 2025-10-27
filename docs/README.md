# Devuan-AMI

Build Devuan AWS Machine Images (AMIs) for EC2 with a simple command-line tool.

## Overview

This tool automates the creation of Devuan AMIs using debootstrap, making it easy to run systemd-free Devuan instances on AWS EC2. It handles the entire process from disk image creation through AWS import and AMI registration.

## Features

- **Future-proof**: Pulls packages directly from Devuan mirrors - no hardcoded package lists
- **Automated**: Complete pipeline from empty disk to registered AMI
- **AWS-ready**: Includes cloud-init, ENA drivers, serial console support
- **SysVinit**: True Devuan experience without systemd
- **HVM**: Modern virtualization for all current EC2 instance types

## Requirements

### System Dependencies

```bash
sudo apt-get install debootstrap qemu-utils awscli parted
```

### AWS Setup

1. AWS CLI configured with credentials (`aws configure`)
2. S3 bucket for temporary storage
3. IAM permissions for: S3 upload, EC2 import-snapshot, EC2 register-image

### Permissions

Must run as root (uses loop devices, mounts filesystems, chroot).

## Installation

```bash
git clone https://github.com/thatsnice/Devuan-AMI.git
cd Devuan-AMI
npm install
```

## Usage

Basic usage:

```bash
sudo bin/devuan-ami \
  --release excalibur \
  --s3-bucket my-ami-bucket \
  --region us-east-1
```

Full options:

```bash
sudo bin/devuan-ami \
  --release excalibur \          # Devuan release: chimaera, daedalus, excalibur
  --arch amd64 \                 # Architecture: amd64 (arm64 planned)
  --s3-bucket my-bucket \        # S3 bucket for upload (required)
  --region us-east-1 \           # AWS region
  --name "Custom Name" \         # AMI name (auto-generated if omitted)
  --disk-size 8 \                # Disk size in GB
  --work-dir /tmp/devuan-ami     # Build directory
```

## What It Does

### 1. Build Phase (5-15 minutes)

- Creates raw disk image
- Partitions and formats as ext4
- Runs debootstrap to install Devuan
- Installs kernel, GRUB, cloud-init, SSH

### 2. Configuration Phase (2-5 minutes)

- Configures fstab, network, SSH
- Installs GRUB bootloader
- Sets up cloud-init for EC2
- Configures SysVinit services
- Enables serial console

### 3. Upload Phase (10-30 minutes)

- Converts to VMDK format
- Uploads to S3
- Imports as EC2 snapshot
- Registers as AMI

**Total time:** 20-50 minutes depending on network speed and AWS region load.

## AMI Details

The resulting AMI includes:

- **OS**: Devuan (your chosen release)
- **Kernel**: Cloud-optimized kernel from Devuan repos
- **Init**: SysVinit (no systemd)
- **Cloud-init**: Configured for EC2
- **User**: `admin` (created by cloud-init, has sudo)
- **SSH**: Key-based auth only, root login disabled
- **Console**: Serial console enabled for debugging
- **Network**: DHCP via cloud-init
- **Filesystem**: ext4 with auto-grow to fill disk

## Architecture

Three-module pipeline:

1. **Builder** - Creates disk image with debootstrap
2. **Configurator** - Configures system for AWS in chroot
3. **Uploader** - Converts, uploads, and registers AMI

See [CLAUDE.md](../CLAUDE.md) for detailed architecture notes.

## Future Plans

- Debian package (`.deb`) for easy installation
- ARM64/Graviton support
- Multiple architecture builds in parallel
- Instance-store backed AMIs (if requested)

## Troubleshooting

### Import fails

Check IAM permissions include `ec2:ImportSnapshot` and `vmimport` service role exists.

### Debootstrap fails

Check network connectivity and Devuan mirror availability.

### Loop device errors

Ensure kernel has loop device support and `/dev/loop*` devices exist.

## License

MIT
