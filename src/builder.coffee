{execSync}      = require 'child_process'
{mkdirSync}     = require 'fs'
{readFileSync}  = require 'fs'
{join}          = require 'path'

# ========================================================================
# Devuan Mirror Configuration
# ========================================================================

MIRRORS =
	default: 'http://deb.devuan.org/merged'
	pkgmaster: 'http://pkgmaster.devuan.org/merged'

# ========================================================================
# Builder Class
# ========================================================================

class Builder
	constructor: (@opts) ->
		@workDir   = @opts['work-dir']
		@imagePath = join @workDir, 'disk.raw'
		@mountDir  = join @workDir, 'mnt'
		@loopDev   = null

	# ====================================================================
	# Main Build Process
	# ====================================================================

	build: ->
		@createWorkspace()
		@createDiskImage()
		@setupLoopDevice()
		@partitionDisk()
		@createFilesystem()
		@mountFilesystem()
		@runDebootstrap()
		@cleanup()
		@imagePath

	# ====================================================================
	# Build Steps
	# ====================================================================

	createWorkspace: ->
		console.log "  Creating workspace: #{@workDir}"
		execSync "mkdir -p #{@workDir}"
		execSync "mkdir -p #{@mountDir}"

	createDiskImage: ->
		sizeGB = @opts['disk-size']
		console.log "  Creating #{sizeGB}GB disk image..."
		execSync "qemu-img create -f raw #{@imagePath} #{sizeGB}G"

	setupLoopDevice: ->
		console.log "  Setting up loop device..."
		output = execSync "losetup --find --show --partscan #{@imagePath}"
		@loopDev = output.toString().trim()
		console.log "  Loop device: #{@loopDev}"

	partitionDisk: ->
		console.log "  Partitioning disk..."

		# Create single partition for root
		commands = [
			"parted -s #{@loopDev} mklabel msdos"
			"parted -s #{@loopDev} mkpart primary ext4 1MiB 100%"
			"parted -s #{@loopDev} set 1 boot on"
		]

		for cmd in commands
			execSync cmd

		# Inform kernel of partition changes
		execSync "partprobe #{@loopDev}"

	createFilesystem: ->
		partition = "#{@loopDev}p1"
		console.log "  Creating ext4 filesystem on #{partition}..."
		execSync "mkfs.ext4 -L devuan-root #{partition}"

	mountFilesystem: ->
		partition = "#{@loopDev}p1"
		console.log "  Mounting filesystem..."
		execSync "mount #{partition} #{@mountDir}"

	runDebootstrap: ->
		{release, arch} = @opts
		mirror = MIRRORS.default

		console.log "  Running debootstrap (this may take several minutes)..."
		console.log "    Release: #{release}"
		console.log "    Arch:    #{arch}"
		console.log "    Mirror:  #{mirror}"

		# Load package list from config file
		configPath = join __dirname, '../config/packages.txt'
		content    = readFileSync configPath, 'utf8'

		# Parse: one package per line, ignore comments and blank lines
		packages = content
			.split('\n')
			.map (line) -> line.trim()
			.filter (line) -> line and not line.startsWith('#')

		packageList = packages.join ','
		console.log "    Packages: #{packages.length} packages"

		cmd = "debootstrap --variant=minbase --arch=#{arch} --include=#{packageList} #{release} #{@mountDir} #{mirror}"

		try
			execSync cmd, stdio: 'inherit'
		catch error
			throw new Error "debootstrap failed: #{error.message}"

	cleanup: ->
		console.log "  Unmounting and cleaning up..."

		# Unmount filesystem
		try
			execSync "umount #{@mountDir}"
		catch error
			console.warn "Warning: Failed to unmount #{@mountDir}"

		# Detach loop device
		if @loopDev
			try
				execSync "losetup -d #{@loopDev}"
			catch error
				console.warn "Warning: Failed to detach loop device #{@loopDev}"

module.exports = Builder
