{existsSync, readFileSync, writeFileSync, mkdirSync} = require 'fs'
{join}                                              = require 'path'

# ========================================================================
# State Management - "The filesystem is the database"
# ========================================================================

class State
	constructor: (@workDir) ->
		@stateFile = join @workDir, '.devuan-ami-state'
		@optionsFile = join @workDir, '.devuan-ami-options'
		@state = {}

	# Check if previous build exists
	exists: ->
		existsSync(@stateFile) or existsSync(@optionsFile)

	# Load previous state
	load: ->
		return unless @exists()

		# Load options
		if existsSync @optionsFile
			content = readFileSync @optionsFile, 'utf8'
			for line in content.split('\n') when line.trim()
				[key, value] = line.split('=')
				@state[key] = value if key

		# Load completed phases
		if existsSync @stateFile
			content = readFileSync @stateFile, 'utf8'
			@state.completed = content.split('\n').filter (x) -> x.trim()
		else
			@state.completed = []

		@state

	# Save current options
	saveOptions: (opts) ->
		mkdirSync @workDir, recursive: true

		lines = []
		for key, value of opts when key isnt 'completed' and typeof value isnt 'object'
			lines.push "#{key}=#{value}"

		writeFileSync @optionsFile, lines.join('\n')

	# Mark phase as completed
	complete: (phase) ->
		@state.completed ?= []
		@state.completed.push phase unless phase in @state.completed

		writeFileSync @stateFile, @state.completed.join('\n')

	# Check if phase is completed
	isCompleted: (phase) ->
		@state.completed ?= []
		phase in @state.completed

	# Get saved options
	getOptions: ->
		@state

	# Get a specific state value
	get: (key) ->
		@state[key]

	# Set a state value
	set: (key, value) ->
		@state[key] = value
		# Persist to options file
		@saveOptions @state

	# Detect what's been done by checking filesystem and state file
	detectProgress: ->
		# Check filesystem
		phases =
			built:      existsSync(join(@workDir, 'disk.raw')) or @isCompleted('build')
			configured: @isCompleted('configure')  # Trust state file for this
			converted:  existsSync(join(@workDir, 'disk.vmdk')) or @isCompleted('convert')

		phases

module.exports = State
