#!/usr/bin/env coffee

{parseArgs}       = require 'util'
{existsSync}      = require 'fs'
{execSync}        = require 'child_process'
{join}            = require 'path'
readline          = require 'readline'
Builder           = require './builder'
Configurator      = require './configurator'
Uploader          = require './uploader'
State             = require './state'
PermissionsChecker = require './permissions'

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

	resume:
		type:        'boolean'
		description: 'Resume previous build without prompting'

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

askYesNo = (question) ->
	return new Promise (resolve) ->
		rl = readline.createInterface
			input:  proc.stdin
			output: proc.stdout

		rl.question "#{question} [y/N] ", (answer) ->
			rl.close()
			resolve answer.toLowerCase() in ['y', 'yes']

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
		      --resume              Resume previous build without prompting
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
	{values, positionals} = parseArgs
		args:              proc.argv.slice(2)
		options:           options
		allowPositionals:  true

	# Handle positional commands
	if positionals[0] in ['help', '--help', '-h'] or values.help
		showHelp()

	if positionals[0] in ['version', '--version', '-v'] or values.version
		console.log VERSION
		proc.exit 0

	# Load state early for resume functionality
	state = new State values['work-dir']

	if values.resume
		if state.exists()
			savedState = state.load()
			# Merge saved options with command line (command line takes precedence)
			# But only override if value wasn't explicitly provided on command line
			for key, value of savedState when key isnt 'completed'
				# Skip if user explicitly provided this arg (check against defaults)
				if key is 'region' and not proc.argv.includes('--region')
					values[key] = value
				else if key is 'release' and not proc.argv.includes('--release') and not proc.argv.includes('-r')
					values[key] = value
				else if key is 'arch' and not proc.argv.includes('--arch') and not proc.argv.includes('-a')
					values[key] = value
				else if key is 'disk-size' and not proc.argv.includes('--disk-size')
					values[key] = value
				else if key not in ['region', 'release', 'arch', 'disk-size']
					values[key] ?= value
		else
			console.error "Error: --resume specified but no previous build found in #{values['work-dir']}"
			proc.exit 1

	# Validate required options
	unless values['s3-bucket']
		console.error 'Error: --s3-bucket is required'
		proc.exit 1

	# Check system requirements
	checkRequirements()

	# Check AWS permissions
	permChecker = new PermissionsChecker values['s3-bucket'], values.region
	unless permChecker.check()
		proc.exit 1

	# Generate AMI name if not provided
	unless values.name
		timestamp = new Date().toISOString().split('T')[0]
		values.name = "Devuan-#{values.release}-#{values.arch}-#{timestamp}"

	# Check for previous build (state already created above if --resume)
	if state.exists()
		progress = state.detectProgress()

		if values.resume
			console.log "Resuming previous build..."
			state.load()
		else
			console.log "Found previous build in #{values['work-dir']}:"
			console.log "  Disk image built:  #{if progress.built then '✓' else '✗'}"
			console.log "  System configured: #{if progress.configured then '✓' else '✗'}"
			console.log "  Converted to VMDK: #{if progress.converted then '✓' else '✗'}"
			console.log ""

			shouldResume = await askYesNo "Resume from previous build?"

			unless shouldResume
				console.log "Please remove #{values['work-dir']} or use a different --work-dir"
				proc.exit 1

			state.load()

	# Save options for future resume
	state.saveOptions values

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
		progress = state.detectProgress()

		# 1. Create disk image with debootstrap
		unless progress.built
			console.log "Step 1/3: Building disk image..."
			builder = new Builder values
			imagePath = builder.build()
			state.complete 'build'
		else
			console.log "Step 1/3: Building disk image... (skipped, already done)"
			imagePath = join values['work-dir'], 'disk.raw'

		# 2. Configure system for AWS
		unless progress.configured
			console.log "\nStep 2/3: Configuring for AWS..."
			configurator = new Configurator values, imagePath
			configurator.configure()
			state.complete 'configure'
		else
			console.log "\nStep 2/3: Configuring for AWS... (skipped, already done)"

		# 3. Upload and register AMI
		console.log "\nStep 3/3: Uploading to AWS..."
		uploader = new Uploader values, imagePath, state
		amiId = uploader.upload()

		console.log "\n✓ AMI created successfully!"
		console.log "  AMI ID: #{amiId}"
		console.log "  Region: #{values.region}"

	catch error
		console.error "\n✗ Build failed: #{error.message}"
		console.error "You can resume with: sudo bin/devuan-ami --resume"
		proc.exit 1

# Export for testing, run if called directly
module.exports = main

if require.main is module
	main()
