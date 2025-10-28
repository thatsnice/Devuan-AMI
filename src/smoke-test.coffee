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
			@waitForCloudInit()
			@verifySSH()
			@verifyNetwork()
			@verifySudo()

			console.log "\n✓ Smoke test passed!"
			console.log "  Instance is ready and fully functional"

			true

		catch error
			console.error "\n✗ Smoke test failed: #{error.message}"
			console.error "  You can investigate manually:"
			console.error "  Instance ID: #{@instanceId}" if @instanceId
			console.error "  Public IP:   #{@publicIp}" if @publicIp
			console.error "  SSH key:     #{@keyPath}" if existsSync(@keyPath)
			console.error ""
			console.error "  To connect: ssh -i #{@keyPath} admin@#{@publicIp}" if @publicIp and existsSync(@keyPath)
			console.error ""

			false

		finally
			@cleanup()

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

		# Launch instance
		result = execSync """
			aws ec2 run-instances \
				--region #{@region} \
				--image-id #{@amiId} \
				--instance-type t3.micro \
				--key-name #{@keyName} \
				--security-group-ids #{@securityGroupId} \
				--subnet-id #{subnetId} \
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

		# Wait for status checks
		console.log "  Waiting for status checks to pass..."

		execSync """
			aws ec2 wait instance-status-ok \
				--region #{@region} \
				--instance-ids #{@instanceId}
		"""

		console.log "    ✓ Status checks passed"

	waitForCloudInit: ->
		console.log "  Waiting for cloud-init to complete..."

		maxAttempts = 60
		attempt     = 0

		while attempt < maxAttempts
			try
				# Check if cloud-init is done
				@ssh "cloud-init status --wait --long", silent: true
				console.log "    ✓ Cloud-init completed"
				return
			catch error
				# SSH might not be ready yet, or cloud-init still running
				attempt++
				if attempt >= maxAttempts
					throw new Error "Cloud-init did not complete within 5 minutes"

				# Wait 5 seconds between attempts
				execSync "sleep 5"

	# ====================================================================
	# Verification
	# ====================================================================

	verifySSH: ->
		console.log "  Verifying SSH access..."

		result = @ssh "echo 'SSH OK'"

		unless result.includes 'SSH OK'
			throw new Error "SSH connection failed"

		console.log "    ✓ SSH connection works"

	verifyNetwork: ->
		console.log "  Verifying network configuration..."

		# Check that we have a network interface with an IP
		result = @ssh "ip addr show eth0"

		unless result.includes 'inet '
			throw new Error "eth0 does not have an IP address"

		# Check that we can reach the internet
		try
			@ssh "ping -c 1 8.8.8.8", silent: true
			console.log "    ✓ Network interface configured"
			console.log "    ✓ Internet connectivity OK"
		catch error
			throw new Error "Cannot reach internet"

	verifySudo: ->
		console.log "  Verifying sudo access..."

		# Check that admin user can sudo
		result = @ssh "sudo whoami"

		unless result.includes 'root'
			throw new Error "sudo is not working for admin user"

		console.log "    ✓ Sudo access works"

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
		silent = opts.silent ? false

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

		result = execSync sshCmd, encoding: 'utf8', stdio: stdio

		if silent
			result.toString()
		else
			result

module.exports = SmokeTest
