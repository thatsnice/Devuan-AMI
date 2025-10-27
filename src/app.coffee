#!/usr/bin/env coffee

{parseArgs}       = require 'util'
{existsSync}      = require 'fs'
{execSync}        = require 'child_process'
Builder           = require './builder'
Configurator      = require './configurator'
Uploader          = require './uploader'

VERSION = '0.1.0'

# Global process object - injected by caller for testability
proc = null

# ========================================================================
# CLI Configuration
# ========================================================================

options =
	release:
		type:        'string'
		short:       'r'
		description: 'Devuan release (chimaera, daedalus, excalibur)'
		default:     'excalibur'

	arch:
		type:        'string'
		short:       'a'
		description: 'Architecture (amd64, arm64)'
		default:     'amd64'

	's3-bucket':
		type:        'string'
		short:       'b'
		description: 'S3 bucket for AMI storage'

	region:
		type:        'string'
		description: 'AWS region'
		default:     'us-east-1'

	name:
		type:        'string'
		short:       'n'
		description: 'AMI name'

	'disk-size':
		type:        'string'
		description: 'Disk size in GB'
		default:     '8'

	'work-dir':
		type:        'string'
		description: 'Working directory for build artifacts'
		default:     '/tmp/devuan-ami'

	help:
		type:        'boolean'
		short:       'h'
		description: 'Show help'

	version:
		type:        'boolean'
		short:       'v'
		description: 'Show version'

# ========================================================================
# Helpers
# ========================================================================

showHelp = ->
	console.log """
		devuan-ami v#{VERSION}
		Build Devuan AWS Machine Images (AMIs) for EC2

		Usage:
		  devuan-ami [options]

		Options:
		  -r, --release <name>      Devuan release (default: excalibur)
		  -a, --arch <arch>         Architecture: amd64, arm64 (default: amd64)
		  -b, --s3-bucket <bucket>  S3 bucket for AMI storage (required)
		      --region <region>     AWS region (default: us-east-1)
		  -n, --name <name>         AMI name (auto-generated if not specified)
		      --disk-size <gb>      Disk size in GB (default: 8)
		      --work-dir <path>     Work directory (default: /tmp/devuan-ami)
		  -h, --help                Show this help
		  -v, --version             Show version

		Example:
		  sudo devuan-ami --release excalibur --s3-bucket my-bucket --name "Devuan Excalibur"

		Requirements:
		  - Must run as root
		  - Requires: debootstrap, qemu-utils, awscli, parted
		"""
	proc.exit 0

checkRequirements = ->
	# Check root
	unless proc.getuid() is 0
		console.error 'Error: Must run as root (use sudo)'
		proc.exit 1

	# Check required commands
	required = ['debootstrap', 'qemu-img', 'aws', 'parted', 'losetup']

	for cmd in required
		try
			execSync "which #{cmd}", stdio: 'ignore'
		catch
			console.error "Error: Required command not found: #{cmd}"
			console.error "Install with: apt-get install debootstrap qemu-utils awscli parted"
			proc.exit 1

# ========================================================================
# Main
# ========================================================================

main = (processObj = process) ->
	# Inject process for testability
	proc = processObj

	# Parse arguments
	{values} = parseArgs {options, allowPositionals: false}

	if values.help
		showHelp()

	if values.version
		console.log VERSION
		proc.exit 0

	# Validate required options
	unless values['s3-bucket']
		console.error 'Error: --s3-bucket is required'
		proc.exit 1

	# Check system requirements
	checkRequirements()

	# Generate AMI name if not provided
	unless values.name
		timestamp = new Date().toISOString().split('T')[0]
		values.name = "Devuan-#{values.release}-#{values.arch}-#{timestamp}"

	console.log "Building Devuan AMI: #{values.name}"
	console.log "  Release:    #{values.release}"
	console.log "  Arch:       #{values.arch}"
	console.log "  Disk size:  #{values['disk-size']}GB"
	console.log "  Work dir:   #{values['work-dir']}"
	console.log "  S3 bucket:  #{values['s3-bucket']}"
	console.log "  Region:     #{values.region}"
	console.log ""

	# Build pipeline
	try
		# 1. Create disk image with debootstrap
		console.log "Step 1/3: Building disk image..."
		builder = new Builder values
		imagePath = builder.build()

		# 2. Configure system for AWS
		console.log "\nStep 2/3: Configuring for AWS..."
		configurator = new Configurator values, imagePath
		configurator.configure()

		# 3. Upload and register AMI
		console.log "\nStep 3/3: Uploading to AWS..."
		uploader = new Uploader values, imagePath
		amiId = uploader.upload()

		console.log "\n✓ AMI created successfully!"
		console.log "  AMI ID: #{amiId}"
		console.log "  Region: #{values.region}"

	catch error
		console.error "\n✗ Build failed: #{error.message}"
		proc.exit 1

# Export for testing, run if called directly
module.exports = main

if require.main is module
	main()
