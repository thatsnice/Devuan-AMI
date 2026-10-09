{execSync}      = require 'child_process'
{writeFileSync, unlinkSync, existsSync} = require 'fs'
{join}          = require 'path'

# ========================================================================
# Smoke Test - Automated validation of AMI
# ========================================================================

class SmokeTest
	constructor: (@opts, @amiId) ->
		@region     = @opts.region
		@workDir    = @opts['work-dir']
		@keyName    = "devuan-ami-test-#{Date.now()}"
		@keyPath    = join @workDir, "#{@keyName}.pem"
		@instanceId = null
		@publicIp   = null

		# Launch with a root volume bigger than the image so we can verify
		# that cloud-init grows the partition and filesystem to fill it
		@imageSizeGB  = parseInt @opts['disk-size'], 10
		@volumeSizeGB = @imageSizeGB + 4

	# ====================================================================
	# Main Test Flow
	# ====================================================================

	run: ->
		console.log "\n=== Smoke Test ==="
		console.log "  Testing AMI: #{@amiId}"
		console.log ""

		try
			@createKeyPair()
			@launchInstance()
			@waitForInstance()
			@waitForSSH()
			@waitForCloudInit()
			@verifySSH()
			@verifySudo()
			@verifyRootGrown()
			@verifyNetworkStage()

			console.log "\n✓ Smoke test passed!"
			console.log "  Instance is ready and fully functional"

			@cleanup()
			true

		catch error
			console.error "\n✗ Smoke test failed: #{error.message}"
			console.error "  Instance left running for investigation:"
			console.error "  Instance ID: #{@instanceId}" if @instanceId
			console.error "  Public IP:   #{@publicIp}" if @publicIp
			console.error "  SSH key:     #{@keyPath}" if existsSync(@keyPath)
			console.error ""
			console.error "  To connect: ssh -i #{@keyPath} admin@#{@publicIp}" if @publicIp and existsSync(@keyPath)
			console.error "  To clean up: aws ec2 terminate-instances --region #{@region} --instance-ids #{@instanceId}" if @instanceId
			console.error ""

			false

	# ====================================================================
	# Setup
	# ====================================================================

	createKeyPair: ->
		console.log "  Creating temporary SSH key pair..."

		result = execSync """
			aws ec2 create-key-pair \
				--region #{@region} \
				--key-name #{@keyName} \
				--query 'KeyMaterial' \
				--output text
		"""

		writeFileSync @keyPath, result.toString()
		execSync "chmod 600 #{@keyPath}"

		if process.env.SUDO_UID
			execSync "chown #{process.env.SUDO_UID}:#{process.env.SUDO_GID} #{@keyPath}"

		console.log "    ✓ Key pair created: #{@keyName}"

	launchInstance: ->
		console.log "  Launching test instance..."

		# Get default VPC
		vpcResult = execSync """
			aws ec2 describe-vpcs \
				--region #{@region} \
				--filters "Name=isDefault,Values=true" \
				--query 'Vpcs[0].VpcId' \
				--output text
		""", encoding: 'utf8'

		vpcId = vpcResult.trim()

		unless vpcId and vpcId isnt 'None'
			throw new Error "No default VPC found in #{@region}"

		# Get default subnet
		subnetResult = execSync """
			aws ec2 describe-subnets \
				--region #{@region} \
				--filters "Name=vpc-id,Values=#{vpcId}" "Name=default-for-az,Values=true" \
				--query 'Subnets[0].SubnetId' \
				--output text
		""", encoding: 'utf8'

		subnetId = subnetResult.trim()

		# Create security group for testing
		sgName = "devuan-ami-test-#{Date.now()}"

		sgResult = execSync """
			aws ec2 create-security-group \
				--region #{@region} \
				--group-name #{sgName} \
				--description "Temporary security group for AMI smoke testing" \
				--vpc-id #{vpcId} \
				--query 'GroupId' \
				--output text
		""", encoding: 'utf8'

		@securityGroupId = sgResult.trim()

		# Allow SSH from anywhere (temporary test only)
		execSync """
			aws ec2 authorize-security-group-ingress \
				--region #{@region} \
				--group-id #{@securityGroupId} \
				--protocol tcp \
				--port 22 \
				--cidr 0.0.0.0/0
		"""

		# User-data marker: exercises the exact path the cloud-init-main race
		# broke. If the network ("init") stage runs, it dispatches this to
		# /var/lib/cloud/instance/scripts/ and modules:final executes it,
		# creating the marker file verifyNetworkStage() checks for.
		userDataPath = join @workDir, 'smoke-user-data.sh'
		writeFileSync userDataPath, "#!/bin/bash\ntouch /var/lib/cloud/SMOKE_USERDATA_RAN\n"

		# Launch instance
		result = execSync """
			aws ec2 run-instances \
				--region #{@region} \
				--image-id #{@amiId} \
				--instance-type t3.micro \
				--key-name #{@keyName} \
				--security-group-ids #{@securityGroupId} \
				--subnet-id #{subnetId} \
				--block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":#{@volumeSizeGB}}}]' \
				--user-data file://#{userDataPath} \
				--associate-public-ip-address \
				--tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=devuan-ami-smoke-test}]' \
				--query 'Instances[0].InstanceId' \
				--output text
		""", encoding: 'utf8'

		@instanceId = result.trim()

		console.log "    ✓ Instance launched: #{@instanceId}"

	# ====================================================================
	# Wait Operations
	# ====================================================================

	waitForInstance: ->
		console.log "  Waiting for instance to be running..."

		execSync """
			aws ec2 wait instance-running \
				--region #{@region} \
				--instance-ids #{@instanceId}
		"""

		# Get public IP
		result = execSync """
			aws ec2 describe-instances \
				--region #{@region} \
				--instance-ids #{@instanceId} \
				--query 'Reservations[0].Instances[0].PublicIpAddress' \
				--output text
		""", encoding: 'utf8'

		@publicIp = result.trim()

		console.log "    ✓ Instance running at #{@publicIp}"

	waitForSSH: ->
		console.log "  Waiting for SSH to become available..."

		maxAttempts = 60    # 5 minutes at 5s intervals
		attempt     = 0

		while attempt < maxAttempts
			try
				@ssh "true", silent: true
				console.log "    ✓ SSH is reachable"
				return
			catch
				attempt++
				throw new Error "SSH not available after 5 minutes" if attempt >= maxAttempts
				execSync "sleep 5"

	waitForCloudInit: ->
		console.log "  Waiting for cloud-init to complete..."

		# cloud-init status --wait blocks until done - run it once with a long timeout
		try
			@ssh "cloud-init status --wait --long", silent: true, timeout: 20 * 60 * 1000
			console.log "    ✓ Cloud-init completed"
		catch error
			throw new Error "Cloud-init did not complete within 20 minutes"

	# ====================================================================
	# Verification
	# ====================================================================

	verifySSH: ->
		console.log "  Verifying SSH access..."

		result = @ssh "echo 'SSH OK'", silent: true

		unless result.includes 'SSH OK'
			throw new Error "SSH connection failed"

		console.log "    ✓ SSH connection works"

	verifySudo: ->
		console.log "  Verifying sudo access..."

		# Check that admin user can sudo
		result = @ssh "sudo whoami", silent: true

		unless result.includes 'root'
			throw new Error "sudo is not working for admin user"

		console.log "    ✓ Sudo access works"

	verifyRootGrown: ->
		console.log "  Verifying root filesystem grew to fill #{@volumeSizeGB}GB volume..."

		result = @ssh "df -BG --output=size / | tail -n 1", silent: true
		sizeGB = parseInt result.trim(), 10

		unless sizeGB > @imageSizeGB
			throw new Error "Root filesystem is #{sizeGB}GB; expected it to grow past the #{@imageSizeGB}GB image (growpart/resizefs did not run)"

		console.log "    ✓ Root filesystem is #{sizeGB}GB"

	verifyNetworkStage: ->
		console.log "  Verifying cloud-init network stage and user-data dispatch..."

		log = @ssh "sudo cat /var/log/cloud-init.log", silent: true

		if log.includes 'Traceback'
			throw new Error "cloud-init logged a Traceback (network stage likely crashed)"

		# The network stage logs "running 'init'"; init-local logs "running 'init-local'".
		unless log.includes "running 'init' "
			throw new Error "cloud-init network ('init') stage did not run"

		marker = @ssh "sudo test -f /var/lib/cloud/SMOKE_USERDATA_RAN && echo PRESENT || echo MISSING", silent: true

		unless marker.includes 'PRESENT'
			throw new Error "user-data never executed (network stage did not dispatch scripts)"

		console.log "    ✓ Network stage ran and user-data was dispatched"

	# ====================================================================
	# Cleanup
	# ====================================================================

	cleanup: ->
		console.log "\n  Cleaning up test resources..."

		# Terminate instance
		if @instanceId
			try
				execSync """
					aws ec2 terminate-instances \
						--region #{@region} \
						--instance-ids #{@instanceId}
				""", stdio: 'ignore'

				console.log "    ✓ Instance terminated: #{@instanceId}"
			catch error
				console.warn "    ⚠ Failed to terminate instance: #{@instanceId}"

		# Delete security group (after instance is terminated)
		if @securityGroupId
			# Wait a bit for instance to start terminating
			try
				execSync "sleep 5"

				# Wait for instance to be terminated
				execSync """
					aws ec2 wait instance-terminated \
						--region #{@region} \
						--instance-ids #{@instanceId}
				""", stdio: 'ignore'

				execSync """
					aws ec2 delete-security-group \
						--region #{@region} \
						--group-id #{@securityGroupId}
				""", stdio: 'ignore'

				console.log "    ✓ Security group deleted"
			catch error
				console.warn "    ⚠ Failed to delete security group: #{@securityGroupId}"

		# Delete key pair
		if @keyName
			try
				execSync """
					aws ec2 delete-key-pair \
						--region #{@region} \
						--key-name #{@keyName}
				""", stdio: 'ignore'

				console.log "    ✓ Key pair deleted: #{@keyName}"
			catch error
				console.warn "    ⚠ Failed to delete key pair: #{@keyName}"

		# Delete local key file
		if existsSync @keyPath
			try
				unlinkSync @keyPath
				console.log "    ✓ Local key file deleted"
			catch error
				console.warn "    ⚠ Failed to delete local key file: #{@keyPath}"

	# ====================================================================
	# Helpers
	# ====================================================================

	ssh: (command, opts = {}) ->
		silent  = opts.silent  ? false
		timeout = opts.timeout ? 30_000

		# SSH with strict host key checking disabled (this is a new host)
		sshCmd = """
			ssh -i #{@keyPath} \
				-o StrictHostKeyChecking=no \
				-o UserKnownHostsFile=/dev/null \
				-o ConnectTimeout=10 \
				admin@#{@publicIp} \
				'#{command}'
		"""

		stdio = if silent then 'pipe' else 'inherit'

		result = execSync sshCmd, encoding: 'utf8', stdio: stdio, timeout: timeout

		if silent then result.toString() else result

module.exports = SmokeTest
