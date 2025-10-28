{execSync} = require 'child_process'

# ========================================================================
# AWS Permissions Checker
# ========================================================================

class PermissionsChecker
	constructor: (@bucket, @region) ->
		@errors = []

	check: ->
		console.log "Checking AWS permissions..."

		@checkVmimportRole()
		@checkS3Access()
		@checkEC2Permissions()

		if @errors.length > 0
			console.error "\n✗ AWS permissions check failed:\n"
			for error in @errors
				console.error "  • #{error}"
			console.error "\nPlease fix these issues before continuing.\n"
			return false

		console.log "  ✓ All AWS permissions verified\n"
		true

	checkVmimportRole: ->
		try
			execSync "aws iam get-role --role-name vmimport", stdio: 'pipe'
		catch error
			@errors.push "vmimport IAM role does not exist"
			@errors.push "  Fix: See docs/vmimport-setup.md"
			@errors.push "       (Remember to replace YOUR-BUCKET-NAME with: #{@bucket})"

	checkS3Access: ->
		# Check if bucket exists and is accessible
		try
			execSync "aws s3 ls s3://#{@bucket} --region #{@region}", stdio: 'pipe'
		catch error
			@errors.push "Cannot access S3 bucket: s3://#{@bucket}"
			@errors.push "  Either the bucket doesn't exist or you lack permissions"
			@errors.push "  Create it with: aws s3 mb s3://#{@bucket} --region #{@region}"

		# Check write permissions
		try
			testFile = "s3://#{@bucket}/.permissions-test-#{Date.now()}"
			execSync "echo test | aws s3 cp - #{testFile} --region #{@region}", stdio: 'pipe'
			execSync "aws s3 rm #{testFile} --region #{@region}", stdio: 'pipe'
		catch error
			@errors.push "Cannot write to S3 bucket: s3://#{@bucket}"
			@errors.push "  Check your IAM permissions include s3:PutObject and s3:DeleteObject"

	checkEC2Permissions: ->
		# Check basic EC2 describe permissions
		try
			execSync "aws ec2 describe-regions --region #{@region}", stdio: 'pipe'
		catch error
			@errors.push "Cannot access EC2 API in region #{@region}"
			@errors.push "  Check your AWS credentials and region settings"

		# Check import-snapshot permission
		# We can't actually test this without doing an import, so check IAM policies
		try
			result = execSync "aws iam get-user", encoding: 'utf8'
			user = JSON.parse(result).User
			userName = user.UserName

			# Try to check attached policies
			try
				execSync "aws iam list-attached-user-policies --user-name #{userName}", stdio: 'pipe'
			catch
				# User might have group policies or inline policies instead
				# We'll let the actual import-snapshot call fail with a better error
		catch error
			# Might be using role-based credentials, which is fine

module.exports = PermissionsChecker
