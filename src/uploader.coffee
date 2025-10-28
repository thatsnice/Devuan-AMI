{execSync}    = require 'child_process'
{join}        = require 'path'
{readFileSync} = require 'fs'
SmokeTest     = require './smoke-test'

# ========================================================================
# Uploader Class
# ========================================================================

class Uploader
	constructor: (@opts, @imagePath, @state) ->
		@workDir   = @opts['work-dir']
		@bucket    = @opts['s3-bucket']
		@region    = @opts.region
		@amiName   = @opts.name
		@amiId     = null
		@vmdkPath  = join @workDir, 'disk.vmdk'

	# ====================================================================
	# Main Upload Process
	# ====================================================================

	upload: ->
		# Convert to VMDK streamOptimized (skip if already done)
		unless @state.isCompleted('convert')
			@convertToVmdk()
			@state.complete 'convert'
		else
			console.log "  Converting to VMDK streamOptimized... (skipped, already done)"

		# Upload to S3 (skip if already done and URI matches)
		savedS3Uri = @state.get('s3-uri')
		currentS3Uri = @generateS3Uri()

		if @state.isCompleted('upload') and savedS3Uri is currentS3Uri
			console.log "  Uploading to S3... (skipped, already uploaded)"
			@s3Uri = savedS3Uri
			@s3Key = @state.get('s3-key')
		else
			@uploadToS3()
			@state.set 's3-uri', @s3Uri
			@state.set 's3-key', @s3Key
			@state.complete 'upload'

		# Import snapshot (resume if interrupted)
		savedTaskId = @state.get('import-task-id')

		if savedTaskId and @state.isCompleted('import-started')
			console.log "  Resuming import snapshot task: #{savedTaskId}"
			importTaskId = savedTaskId
		else
			importTaskId = @importSnapshot()
			@state.set 'import-task-id', importTaskId
			@state.complete 'import-started'

		snapshotId = @waitForImport importTaskId
		@state.set 'snapshot-id', snapshotId
		@state.complete 'import'

		# Register AMI
		@amiId = @registerAMI snapshotId
		@state.set 'ami-id', @amiId
		@state.complete 'register'

		# Run smoke test
		unless @state.isCompleted('smoke-test')
			smokeTest = new SmokeTest @opts, @amiId
			passed    = smokeTest.run()

			if passed
				@state.complete 'smoke-test'
			else
				console.warn "\n⚠ Smoke test failed, but AMI was created successfully"
				console.warn "  AMI ID: #{@amiId}"
				console.warn "  You may want to investigate and fix issues before using this AMI"
		else
			console.log "\n=== Smoke Test ==="
			console.log "  Smoke test already passed for this AMI"

		@cleanup()
		@amiId

	# ====================================================================
	# Upload Steps
	# ====================================================================

	generateS3Uri: ->
		s3Key = "devuan-ami-imports/#{@amiName}.vmdk"
		"s3://#{@bucket}/#{s3Key}"

	convertToVmdk: ->
		console.log "  Converting to VMDK streamOptimized format..."
		console.log "  (This compresses the image and makes upload faster)"
		execSync "qemu-img convert -f raw -O vmdk -o subformat=streamOptimized #{@imagePath} #{@vmdkPath}"

	uploadToS3: ->
		# Use deterministic S3 key (no timestamp) so we can detect re-uploads
		@s3Key = "devuan-ami-imports/#{@amiName}.vmdk"
		@s3Uri = "s3://#{@bucket}/#{@s3Key}"

		console.log "  Uploading VMDK to S3: #{@s3Uri}"
		console.log "  (Compressed image - faster than RAW upload)"
		execSync "aws s3 cp #{@vmdkPath} #{@s3Uri} --region #{@region}"

	importSnapshot: ->
		console.log "  Creating import snapshot task..."

		# Create disk container JSON for import
		diskContainer =
			Description: @amiName
			Format:      'VMDK'
			UserBucket:
				S3Bucket: @bucket
				S3Key:    @s3Key

		# Write to temp file
		containerFile = join @workDir, 'container.json'
		{writeFileSync} = require 'fs'
		writeFileSync containerFile, JSON.stringify(diskContainer)

		# Import snapshot
		cmd = """
			aws ec2 import-snapshot \
				--region #{@region} \
				--description "#{@amiName}" \
				--disk-container file://#{containerFile}
			"""

		output = execSync cmd
		result = JSON.parse output.toString()

		importTaskId = result.ImportTaskId
		console.log "  Import task ID: #{importTaskId}"
		importTaskId

	waitForImport: (taskId) ->
		console.log "  Waiting for import to complete (this may take 10-30 minutes)..."

		loop
			# Check status
			cmd = "aws ec2 describe-import-snapshot-tasks --region #{@region} --import-task-ids #{taskId}"
			output = execSync cmd
			result = JSON.parse output.toString()

			task   = result.ImportSnapshotTasks[0]
			detail = task.SnapshotTaskDetail
			status = detail.Status

			progress = detail.Progress or '0'
			console.log "  Import progress: #{progress}% (#{status})"

			if status is 'completed'
				snapshotId = detail.SnapshotId
				console.log "  Snapshot created: #{snapshotId}"
				return snapshotId

			if status in ['deleted', 'deleting']
				errorMsg = detail.StatusMessage or 'No error message provided'
				throw new Error "Import task was deleted: #{errorMsg}"

			if detail.StatusMessage
				message = detail.StatusMessage
				console.log "  Status: #{message}"
				if message.includes('error') or message.includes('fail')
					throw new Error "Import failed: #{message}"

			# Wait 30 seconds before checking again
			execSync 'sleep 30'

	registerAMI: (snapshotId) ->
		console.log "  Registering AMI from snapshot..."

		arch = @opts.arch
		awsArch = if arch is 'amd64' then 'x86_64' else 'arm64'

		# Determine root device name based on architecture
		rootDevice = '/dev/sda1'

		cmd = """
			aws ec2 register-image \
				--region #{@region} \
				--name "#{@amiName}" \
				--description "Devuan #{@opts.release} #{arch}" \
				--architecture #{awsArch} \
				--root-device-name #{rootDevice} \
				--virtualization-type hvm \
				--ena-support \
				--block-device-mappings '[{
					"DeviceName": "#{rootDevice}",
					"Ebs": {
						"SnapshotId": "#{snapshotId}",
						"VolumeType": "gp3",
						"DeleteOnTermination": true
					}
				}]'
			"""

		output = execSync cmd
		result = JSON.parse output.toString()

		amiId = result.ImageId
		console.log "  AMI registered: #{amiId}"
		amiId

	cleanup: ->
		console.log "  Cleaning up local temporary files..."

		# Remove VMDK file
		try
			execSync "rm -f #{@vmdkPath}"
			console.log "  Removed local VMDK file"
		catch error
			console.warn "  Warning: Failed to remove #{@vmdkPath}"

		# Note: Keeping S3 object for manual cleanup (lifecycle policy will delete after 7 days)

module.exports = Uploader
