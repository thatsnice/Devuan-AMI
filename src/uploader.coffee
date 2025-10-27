{execSync}    = require 'child_process'
{join}        = require 'path'
{readFileSync} = require 'fs'

# ========================================================================
# Uploader Class
# ========================================================================

class Uploader
	constructor: (@opts, @imagePath) ->
		@workDir   = @opts['work-dir']
		@bucket    = @opts['s3-bucket']
		@region    = @opts.region
		@amiName   = @opts.name
		@vmdkPath  = join @workDir, 'disk.vmdk'

	# ====================================================================
	# Main Upload Process
	# ====================================================================

	upload: ->
		@convertToVmdk()
		@uploadToS3()
		importTaskId = @importSnapshot()
		snapshotId   = @waitForImport importTaskId
		amiId        = @registerAMI snapshotId
		@cleanup()
		amiId

	# ====================================================================
	# Upload Steps
	# ====================================================================

	convertToVmdk: ->
		console.log "  Converting image to VMDK format..."
		execSync "qemu-img convert -f raw -O vmdk #{@imagePath} #{@vmdkPath}"

	uploadToS3: ->
		s3Key = "devuan-ami-imports/#{@amiName}-#{Date.now()}.vmdk"
		s3Uri = "s3://#{@bucket}/#{s3Key}"

		console.log "  Uploading to S3: #{s3Uri}"
		execSync "aws s3 cp #{@vmdkPath} #{s3Uri} --region #{@region}"

		@s3Key = s3Key
		@s3Uri = s3Uri

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
				throw new Error "Import task was deleted"

			if detail.StatusMessage
				message = detail.StatusMessage
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
		console.log "  Cleaning up temporary files..."

		# Remove VMDK file
		try
			execSync "rm -f #{@vmdkPath}"
		catch error
			console.warn "Warning: Failed to remove #{@vmdkPath}"

		# Optionally remove S3 object (keeping it for now for debugging)
		# execSync "aws s3 rm #{@s3Uri} --region #{@region}"

module.exports = Uploader
