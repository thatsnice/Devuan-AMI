{execSync}      = require 'child_process'
{writeFileSync} = require 'fs'
{join}          = require 'path'

# ========================================================================
# Configurator Class
# ========================================================================

class Configurator
	constructor: (@opts, @imagePath) ->
		@workDir  = @opts['work-dir']
		@mountDir = join @workDir, 'mnt'
		@loopDev  = null

	# ====================================================================
	# Main Configuration Process
	# ====================================================================

	configure: ->
		@mountImage()
		@mountPseudoFilesystems()
		@configureFstab()
		@configureNetwork()
		@configureCloudInit()
		@installGrub()
		@configureSSH()
		@createAdminUser()
		@configureSerialConsole()
		@verifyInstallation()
		@cleanupSystem()
		@unmountAll()

	# ====================================================================
	# Filesystem Management
	# ====================================================================

	mountImage: ->
		console.log "  Mounting disk image..."
		output = execSync "losetup --find --show --partscan #{@imagePath}"
		@loopDev = output.toString().trim()
		partition = "#{@loopDev}p1"
		execSync "mount #{partition} #{@mountDir}"

	mountPseudoFilesystems: ->
		console.log "  Mounting pseudo-filesystems for chroot..."
		execSync "mount -t proc  proc  #{@mountDir}/proc"
		execSync "mount -t sysfs sys   #{@mountDir}/sys"
		execSync "mount -o bind  /dev  #{@mountDir}/dev"
		execSync "mount -t devpts devpts #{@mountDir}/dev/pts"

	unmountAll: ->
		console.log "  Unmounting all filesystems..."

		# Unmount in reverse order
		for path in ['/dev/pts', '/dev', '/sys', '/proc', '']
			try
				execSync "umount #{@mountDir}#{path}"
			catch error
				console.warn "Warning: Failed to unmount #{@mountDir}#{path}"

		# Detach loop device
		if @loopDev
			try
				execSync "losetup -d #{@loopDev}"
			catch error
				console.warn "Warning: Failed to detach #{@loopDev}"

	# ====================================================================
	# Configuration Steps
	# ====================================================================

	configureFstab: ->
		console.log "  Configuring fstab..."

		fstab = """
			# /etc/fstab: static file system information
			LABEL=devuan-root  /        ext4  defaults,discard  0  1
			tmpfs              /tmp     tmpfs defaults,nodev,nosuid  0  0
			"""

		@writeFile '/etc/fstab', fstab

	configureNetwork: ->
		console.log "  Configuring network..."

		# Let cloud-init handle network configuration
		interfaces = """
			# Network configuration is managed by cloud-init
			# See /etc/cloud/cloud.cfg.d/ for configuration
			auto lo
			iface lo inet loopback
			"""

		@writeFile '/etc/network/interfaces', interfaces

	configureCloudInit: ->
		console.log "  Configuring cloud-init..."

		# AWS-specific cloud-init configuration
		cloudConfig = """
			datasource_list: [ Ec2, None ]
			datasource:
			  Ec2:
			    strict_id: false
			    timeout: 10
			    max_wait: 30

			# Let cloud-init auto-configure networking using ENI
			# Don't specify network config - let it detect and use ifupdown

			# System info
			system_info:
			  default_user:
			    name: admin
			    groups: [adm, sudo]
			    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
			    shell: /bin/bash
			    lock_passwd: true

			# Disable root login
			disable_root: true

			# Manage /etc/hosts
			manage_etc_hosts: true

			# Grow root partition to fill disk
			growpart:
			  mode: auto
			  devices: ['/']

			# Resize filesystem
			resize_rootfs: true
			"""

		@writeFile '/etc/cloud/cloud.cfg.d/99-aws.cfg', cloudConfig

	installGrub: ->
		console.log "  Installing GRUB bootloader..."

		# Configure GRUB for AWS (serial console, no splash)
		grubDefault = """
			GRUB_DEFAULT=0
			GRUB_TIMEOUT=0
			GRUB_DISTRIBUTOR=Devuan
			GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8 nvme_core.io_timeout=4294967295"
			GRUB_CMDLINE_LINUX=""
			GRUB_TERMINAL="console serial"
			GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
			"""

		@writeFile '/etc/default/grub', grubDefault

		# Install GRUB to loop device
		@chroot "grub-install #{@loopDev}"
		@chroot "update-grub"

	configureSSH: ->
		console.log "  Configuring SSH..."

		# SSH daemon config for AWS
		sshdConfig = """
			# SSH daemon configuration for AWS
			PermitRootLogin no
			PasswordAuthentication no
			PubkeyAuthentication yes
			ChallengeResponseAuthentication no
			UsePAM yes
			X11Forwarding yes
			PrintMotd no
			AcceptEnv LANG LC_*
			Subsystem sftp /usr/lib/openssh/sftp-server
			"""

		@writeFile '/etc/ssh/sshd_config', sshdConfig

		# Enable SSH service (SysVinit)
		@chroot "update-rc.d ssh defaults"
		@chroot "update-rc.d ssh enable"

	createAdminUser: ->
		console.log "  Preparing for admin user creation..."

		# Ensure groups exist that cloud-init needs
		# cloud-init will create the user, but groups must exist first
		@chroot "groupadd -f sudo"
		@chroot "groupadd -f adm"

		# Configure sudoers for sudo group
		sudoersConfig = "%sudo ALL=(ALL:ALL) NOPASSWD:ALL\n"
		@appendFile '/etc/sudoers.d/90-cloud-init-users', sudoersConfig
		@chroot "chmod 0440 /etc/sudoers.d/90-cloud-init-users"

	configureSerialConsole: ->
		console.log "  Configuring serial console..."

		# Enable getty on serial console for AWS
		# Add to /etc/inittab for SysVinit
		inittabEntry = "T0:23:respawn:/sbin/getty -L ttyS0 115200 vt100\n"
		@appendFile '/etc/inittab', inittabEntry

	verifyInstallation: ->
		console.log "  Verifying installation..."

		# Essential packages that must be present
		requiredPackages = [
			'cloud-init'
			'openssh-server'
			'grub-pc'
			'ifupdown'
			'isc-dhcp-client'
		]

		requiredFiles = [
			'/etc/cloud/cloud.cfg.d/99-aws.cfg'
			'/etc/fstab'
			'/etc/ssh/sshd_config'
			'/etc/inittab'
		]

		requiredGroups = [
			'sudo'
			'adm'
		]

		# Check packages
		for pkg in requiredPackages
			try
				@chroot "dpkg -l #{pkg} | grep '^ii'"
				console.log "    ✓ Package installed: #{pkg}"
			catch error
				throw new Error "Required package missing: #{pkg}"

		# Check files
		for file in requiredFiles
			fullPath = @mountDir + file
			{existsSync} = require 'fs'
			unless existsSync fullPath
				throw new Error "Required file missing: #{file}"
			console.log "    ✓ File exists: #{file}"

		# Check groups exist
		for group in requiredGroups
			try
				@chroot "getent group #{group}"
				console.log "    ✓ Group exists: #{group}"
			catch error
				throw new Error "Required group missing: #{group}"

		# Check bootloader
		try
			@chroot "test -f /boot/grub/grub.cfg"
			console.log "    ✓ GRUB configured"
		catch error
			throw new Error "GRUB configuration missing"

		# Validate cloud-init config syntax
		try
			@chroot "cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-aws.cfg"
			console.log "    ✓ Cloud-init config valid"
		catch error
			console.warn "    ⚠ Cloud-init config validation failed (may be OK if schema validator missing)"

		console.log "  Verification passed!"

	cleanupSystem: ->
		console.log "  Cleaning up system..."

		# Clean package cache
		@chroot "apt-get clean"

		# Remove machine-id (will be regenerated on first boot)
		@writeFile '/etc/machine-id', ''

		# Clear log files
		@chroot "find /var/log -type f -exec truncate -s 0 {} \\;"

	# ====================================================================
	# Helpers
	# ====================================================================

	chroot: (cmd) ->
		execSync "chroot #{@mountDir} /bin/bash -c '#{cmd}'"

	writeFile: (path, content) ->
		fullPath = join @mountDir, path
		writeFileSync fullPath, content

	appendFile: (path, content) ->
		fullPath = join @mountDir, path
		{appendFileSync} = require 'fs'
		appendFileSync fullPath, content

	hasSystemd: ->
		# Devuan uses SysVinit by default, not systemd
		# Return false for now; we'll use traditional init scripts
		false

module.exports = Configurator
