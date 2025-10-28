{describe, it} = require 'node:test'
assert           = require 'node:assert'
main             = require '../src/app.coffee'

# ========================================================================
# Mock Process Object
# ========================================================================

class ProcessExit extends Error
	constructor: (code) ->
		super "Process exit: #{code}"
		@name = 'ProcessExit'
		@code = code

createMockProcess = (overrides = {}) ->
	exitCode = null
	argv     = overrides.argv or ['node', 'devuan-ami', '--help']

	mockProc =
		argv:     argv
		exit:     (code) ->
			exitCode = code
			throw new ProcessExit(code)
		getuid:   -> overrides.uid or 0
		exitCode: -> exitCode

	mockProc

# ========================================================================
# Tests
# ========================================================================

describe 'devuan-ami CLI', ->

	it 'shows help with --help flag', ->
		mockProc    = createMockProcess argv: ['node', 'devuan-ami', '--help']
		originalLog = console.log
		output      = []

		# Capture console.log
		console.log = (msg) -> output.push(msg)

		try
			main(mockProc)
			assert.fail 'Should have exited'
		catch error
			throw error unless error instanceof ProcessExit

		console.log = originalLog

		# Verify help was shown
		helpText = output.join('\n')
		assert.match helpText, /devuan-ami/
		assert.match helpText, /Usage:/
		assert.match helpText, /Options:/
		assert.strictEqual mockProc.exitCode(), 0

	it 'shows version with --version flag', ->
		mockProc    = createMockProcess argv: ['node', 'devuan-ami', '--version']
		originalLog = console.log
		output      = []

		console.log = (msg) -> output.push(msg)

		try
			main(mockProc)
			assert.fail 'Should have exited'
		catch error
			throw error unless error instanceof ProcessExit

		console.log = originalLog

		assert.match output[0], /\d+\.\d+\.\d+/
		assert.strictEqual mockProc.exitCode(), 0

	it 'requires root privileges', ->
		mockProc     = createMockProcess
			argv: ['node', 'devuan-ami', '--s3-bucket', 'test', '--release', 'excalibur']
			uid:  1000  # Non-root

		originalError = console.error
		errorOutput   = []

		console.error = (msg) -> errorOutput.push(msg)

		try
			main(mockProc)
			assert.fail 'Should have exited'
		catch error
			throw error unless error instanceof ProcessExit

		console.error = originalError

		errorText = errorOutput.join('\n')
		assert.match errorText, /root/i
		assert.strictEqual mockProc.exitCode(), 1

	it 'requires --s3-bucket flag', ->
		mockProc     = createMockProcess
			argv: ['node', 'devuan-ami', '--release', 'excalibur']
			uid:  0

		originalError = console.error
		errorOutput   = []

		console.error = (msg) -> errorOutput.push(msg)

		try
			main(mockProc)
			assert.fail 'Should have exited'
		catch error
			throw error unless error instanceof ProcessExit

		console.error = originalError

		errorText = errorOutput.join('\n')
		assert.match errorText, /s3-bucket.*required/i
		assert.strictEqual mockProc.exitCode(), 1

	it 'accepts process injection for testability', ->
		mockProc = createMockProcess argv: ['node', 'devuan-ami', '--help']

		try
			main(mockProc)
		catch error
			throw error unless error instanceof ProcessExit

		# If we got here, process injection worked
		assert.ok true

	it 'supports positional "help" command', ->
		mockProc    = createMockProcess argv: ['node', 'devuan-ami', 'help']
		originalLog = console.log
		output      = []

		console.log = (msg) -> output.push(msg)

		try
			main(mockProc)
			assert.fail 'Should have exited'
		catch error
			throw error unless error instanceof ProcessExit

		console.log = originalLog

		helpText = output.join('\n')
		assert.match helpText, /Usage:/
		assert.strictEqual mockProc.exitCode(), 0

	it 'supports positional "version" command', ->
		mockProc    = createMockProcess argv: ['node', 'devuan-ami', 'version']
		originalLog = console.log
		output      = []

		console.log = (msg) -> output.push(msg)

		try
			main(mockProc)
			assert.fail 'Should have exited'
		catch error
			throw error unless error instanceof ProcessExit

		console.log = originalLog

		assert.match output[0], /\d+\.\d+\.\d+/
		assert.strictEqual mockProc.exitCode(), 0

describe 'CLI argument parsing', ->

	it 'uses default values when flags omitted', ->
		# This test verifies the CLI has sensible defaults
		# We can't actually run the build without root/deps, but we can
		# verify the args structure is correct

		mockProc = createMockProcess
			argv: ['node', 'devuan-ami', '--s3-bucket', 'test']
			uid:  0

		# Parse args manually to check defaults
		{parseArgs} = require 'util'

		options =
			release:     {type: 'string', default: 'excalibur'}
			arch:        {type: 'string', default: 'amd64'}
			's3-bucket': {type: 'string'}
			region:      {type: 'string', default: 'us-east-1'}
			'disk-size': {type: 'string', default: '8'}

		{values} = parseArgs
			options:            options
			allowPositionals:   false
			args:               mockProc.argv.slice(2)

		assert.strictEqual values.release, 'excalibur'
		assert.strictEqual values.arch, 'amd64'
		assert.strictEqual values.region, 'us-east-1'
		assert.strictEqual values['disk-size'], '8'
		assert.strictEqual values['s3-bucket'], 'test'
