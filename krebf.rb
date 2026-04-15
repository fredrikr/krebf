#!/usr/bin/env ruby

# Krebf, a Z-code interpreter, (c) Fredrik Ramsberg 2026. 
# License: MIT, see separate file.
# Home page: https://github.com/fredrikr/krebf
# Developed and tested on Ruby 3.3.5. Should run using a standard Ruby 
# installation, without installing any extra gems.

require 'io/console'
require 'json'
require 'base64'
#require 'tty-reader'

$z = nil # Z-machine memory contents
$quit = false 

$debug = []

FORM_VAR = 1
FORM_SHORT = 2
FORM_LONG = 3
FORM_EXT = 4

OPCODE_TYPE_0OP = 1
OPCODE_TYPE_1OP = 2
OPCODE_TYPE_2OP = 3
OPCODE_TYPE_VAR = 4
OPCODE_TYPE_EXT = 5

OPERAND_TYPE_LARGECONST = 0
OPERAND_TYPE_SMALLCONST = 1
OPERAND_TYPE_VAR        = 2
OPERAND_TYPE_OMITTED    = 3


def fatalErr(message)
	puts message
	puts caller(0)
	puts $addresses.map{|x| x.to_s(16)}.to_s # DEBUG ONLY
	exit 1
end

def unpackRoutinePaddress(paddress)
	case
		when $zcode_version < 4 then
			2 * paddress
		when $zcode_version < 7 then
			4 * paddress
		when $zcode_version == 7 then
			$routine_offset + 4 * paddress
		else
			8 * paddress
	end
end

def unpackStringPaddress(paddress)
	case
		when $zcode_version < 4 then
			2 * paddress
		when $zcode_version < 7 then
			4 * paddress
		when $zcode_version == 7 then
			$string_offset + 4 * paddress
		else
			8 * paddress
	end
end

class ScreenClass
	def initialize
		checkScreenSize()
		@buffer = ""
		@buffered = true
		@window = 0
		@bottom_printed_lines = 0
#		@cursor[0]['col'] = 0
		@top_window_start = $zcode_version < 4 ? 1 : 0
		@top_window_lines = 0
		@window_content = []
		clearLines(0, @screen_height - 1)
		@cursor = [
			{ 'line' => @screen_height - 1, 'col' => 0 },
			{ 'line' => 0, 'col' => 0 },
			{ 'line' => 0, 'col' => 0 },
		]
		IO.console.goto(@cursor[0]['line'], @cursor[0]['col'])
		unsplit()
	end
	def buffered
		@buffered
	end
	def buffered=(value)
		@buffered = value
	end
	def impossibleWindow(window)
		window == nil or window < 0 or window > 2 or 
				window == 1 && $zcode_version < 3 or
				window == 2 && $zcode_version > 3
	end
	def clear
		IO.console.clear_screen
		IO.console.goto(@screen_height - 1, 0)
		@cursor[0]['col'] = 0
	end
	def getCursor
		return @cursor[@window]['line'], @cursor[@window]['col']
	end
	def setCursor(line, col)
		@cursor[@window] = { 'line' => line, 'col' => col }
	end
	def setCursorTopLeft(window)
		if impossibleWindow(window)
			fatalErr "PC=$#{$pc.to_s(16)}: screen.setCursorTopLeft: " + 
					"Tried to set cursor position in impossible window: " + 
					(window != nil ? window.to_s : 'nil')
		end
		@cursor[window] = 
			case
				when window == 0 then
					{ 'line' => @bottom_window_start, 'col' => 0 }
				when window == 1 then
					{ 'line' => @top_window_start, 'col' => 0 }
				when window == 2 then
					{ 'line' => 0, 'col' => 0 }
			end
	end
	def setCursorBottomLeft(window)
		if impossibleWindow(window)
			fatalErr "PC=$#{$pc.to_s(16)}: screen.setCursorBottomLeft: " + 
					"Tried to set cursor position in impossible window: " + 
					(window != nil ? window.to_s : 'nil')
		end
		@cursor[window] = 
			case
				when window == 0 then
					{ 
						'line' => @bottom_window_start + @bottom_window_lines - 1,
						'col' => 0 
					}
				when window == 1 then
					{ 'line' => @bottom_window_start - 1, 'col' => 0 }
				when window == 2 then
					{ 'line' => 0, 'col' => 0 }
			end
	end
	def unsplit
		if $zcode_version < 4
			clearLines(@top_window_start, @top_window_start + @top_window_lines - 1)
		end
		@top_window_lines = 0
		@bottom_window_start = @top_window_start + @top_window_lines
		@bottom_window_lines = @screen_height - @bottom_window_start
		@cursor[1]['line'] = @top_window_start
		@cursor[1]['col'] = 0
	end
	def split(top_lines)
		old_lines = @top_window_lines
		clear_from = -1
		clear_to = -1
		top_lines = 0 if top_lines < 0
		top_lines = @top_window_lines + @bottom_window_lines if 
				top_lines > @top_window_lines + @bottom_window_lines
		if top_lines != @top_window_lines
			if @top_window_lines > 0
				# Resize
				if top_lines < @top_window_lines
					# Top window gets smaller, clear part that is now returned to bottom window
					clear_from = @top_window_start + top_lines
					clear_to = @bottom_window_start - 1
				else
					# Top window gets bigger, clear new part of top window
					clear_from = @top_window_start + @top_window_lines
					clear_to = @top_window_start + top_lines - 1
				end
			else
				clear_from = @top_window_start
				clear_to = @top_window_start + top_lines - 1				
			end
						
			clearLines(clear_from, clear_to) if $zcode_version < 4 and clear_from >= 0

			@top_window_lines = top_lines
			@bottom_window_start = @top_window_start + @top_window_lines
			@bottom_window_lines = @screen_height - @bottom_window_start
			if @cursor[0]['line'] < @bottom_window_start
				@cursor[0] = { 'line' => @bottom_window_start, 'col' => 0 }
			end
			if old_lines == 0
				@cursor[1]['line'] = @top_window_start
				@cursor[1]['col'] = 0
			end
		end
		refreshTopWindow()
	end
	def refreshTopWindow
		return if @top_window_lines == 0
		(line, col) = IO.console.cursor()
		IO.console.goto(@top_window_start, 0)
		@top_window_lines.times do |i|
			puts @window_content[@top_window_start + i]
		end
		IO.console.goto(line, col)
	end
	def selectWindow(window)
		if impossibleWindow(window)
			fatalErr "PC=$#{$pc.to_s(16)}: screen.selectWindow: " + 
					"Tried to select impossible window: " + 
					(window != nil ? window.to_s : 'nil') +
					" when window was " + @window.to_s
		end
		@window = window 
	end
	def window
		@window
	end
	def checkScreenSize
		@screen_height, @screen_width = IO.console.winsize
	end
	def screen_height
		@screen_height
	end
	def screen_width
		@screen_width
	end
	def clearLines(from, to)
		while @window_content.length < to + 1 do
			@window_content += [nil]
		end
		from.upto(to) do |line|
			@window_content[line] = ' ' * (@screen_width - 1)
		end
	end
	def clearWindow(window)
		if impossibleWindow(window)
			fatalErr "PC=$#{$pc.to_s(16)}: screen.clearWindow: " + 
					"Tried to clear impossible window: " + 
					(window != nil ? window.to_s : 'nil')
		end
		clear_from = -1
		clear_to = -1
		if window == 0
			clear_from = @bottom_window_start
			clear_to = @bottom_window_start + @bottom_window_lines - 1
		elsif window == 1
			clear_from = @top_window_start
			clear_to = @bottom_window_start - 1
		elsif window == 2
			clear_from = 0
			clear_to = 0
		end
		clearLines(clear_from, clear_to) if clear_from >= 0
		case
			when window == 0
				refreshBottomWindow()
			when window == 1
				refreshTopWindow()
			when window == 2
				refreshStatusline()
		end
	end
	def refreshStatusline
		return if $zcode_version > 3
		(line, col) = IO.console.cursor()
		IO.console.goto(0, 0)
		print "\033[7m " # Reverse text
		print @window_content[0]
		print "\033[0m" # Normal text (reverse off)
		IO.console.goto(line, col)
	end
	def showStatusline # Only used for v1-v3
		return if $zcode_version > 3
		win = @window
		@window = 2
		setCursorTopLeft(2)

		printObjectName(readGlobal(16))
		printPartialLine ' ' * @screen_width # if @screen_width - s_col > 0

		if $zcode_version == 3 and readByte(1) & 2 != 0
			@cursor[2]['col'] = @screen_width - 18
			hbase = readGlobal(17)
			h = hbase > 12 ? hbase - 12 : (hbase == 0 ? 12 : hbase)
			m = readGlobal(18).to_s.rjust(2,'0')
			ampm = hbase < 12 ? 'AM' : 'PM'
			printBuffered " Time: #{h}:#{m} #{ampm}   "
		else
			@cursor[2]['col'] = @screen_width - 25
			printBuffered " Score: #{readGlobal(17)}   "
			@cursor[2]['col'] = @screen_width - 13
			printBuffered " Moves: #{readGlobal(18)}   "
		end
		
		@window = win
		refreshStatusline()
	end
	def more
		if @bottom_window_lines > 1
			IO.console.goto(@screen_height - 1, 0)
			print " -- MORE --"
			$screen.readChar()
			IO.console.goto(@screen_height - 2, 0)
			print "                "
			IO.console.goto(@screen_height - 2, 0)
		end
		bottom_clear_lines()
	end
	def bottom_clear_lines
		@bottom_printed_lines = 0
	end
	def bottom_add_line
		@bottom_printed_lines += 1
		more() if @bottom_printed_lines >= @bottom_window_lines - 1
	end
	def refreshBottomWindow
		if @bottom_window_lines > 0
			@bottom_window_lines.times do |i|
				IO.console.goto(@bottom_window_start + i, 0)
				print @window_content[@bottom_window_start + i]
			end
#			IO.console.goto(@screen_height - 2, 0)
			IO.console.goto(@cursor[0]['line'], @cursor[0]['col'])
		end
	end
	def bottomScroll
		@window_content[@bottom_window_start, @bottom_window_lines] =
			@window_content[@bottom_window_start + 1, @bottom_window_lines - 1] +
				[' ' * (@screen_width - 1)]
		refreshBottomWindow()
	end
	def newline
		if @window == 0
			if @cursor[0]['line'] >= @bottom_window_start + @bottom_window_lines - 1
				bottomScroll()
			else
				@cursor[0]['line'] += 1
			end	
			@cursor[0]['col'] = 0
			refreshBottomWindow()
		else
			if @cursor[@window]['line'] < @bottom_window_start + @bottom_window_lines - 1
				@cursor[@window]['line'] += 1
			end
			@cursor[@window]['col'] = 0
			if @window == 1
				refreshTopWindow()
			else
				refreshStatusline()
			end
		end
	end
	def printPartialLine(str)
		line = @cursor[@window]['line']
		if line < 0 or line > @screen_height - 1 or 
					@window == 0 && line < @bottom_window_start or
					@window == 1 && line < @top_window_start
			fatalErr "PC=$#{$pc.to_s(16)}: screen.printPartialLine: " + 
					"Tried to print to impossible line: " + 
					(line != nil ? line.to_s : 'nil') +
					" in window " + @window.to_s +
					", screen_height is " + @screen_height.to_s +
					", bottom_window_start is " + @bottom_window_start.to_s
		end
		return if str.length == 0 or @window == 2 && line > 0
		maxlength = @screen_width - 1 - @cursor[@window]['col']
		str = str[0, maxlength] if str.length > maxlength
		if @window_content[line] == nil
			puts @window_content.length
			fatalErr "NO LINE!"
		end
		split(line + 1 - @top_window_start) if @window == 1 and line >= @bottom_window_start
		@window_content[line][@cursor[@window]['col'], str.length] = str
		@cursor[@window]['col'] += str.length
	end
	def printBuffered(str, flush = false)
		if str && str.length > 0
			if @window == 0 && @buffered
				newlinePos = 1
				while str and newlinePos do
					newlinePos = str.index(/\n/)
					if newlinePos
						if newlinePos > 0
							printBuffered(str[0, newlinePos], true)
							newline()
							bottom_add_line()
						else
							flushBuffer()
							newline()
							bottom_add_line()
						end
						str = str[newlinePos + 1 ..]
					end
				end
				# There are no newlines in str from this point
				@buffer += str
				if @buffer.length > @screen_width - 1
					breakPos = @buffer.rindex(/ /, @screen_width - 1)
					if breakPos
						printPartialLine @buffer[0 .. breakPos - 1]
						newline()
						bottom_add_line()
						@buffer = @buffer [breakPos + 1 ..]
					else
						printPartialLine @buffer[0 .. @screen_width - 2]
						newline()
						bottom_add_line()
						@buffer = @buffer[@screen_width - 1 ..]
					end
				end
			elsif @window == 0
				# Bottom window, not buffered
				newlinePos = 1
				while str and newlinePos do
					newlinePos = str.index(/\n/)
					if newlinePos
						if newlinePos > 0
							printBuffered(str[0, newlinePos])
						end
#						else
							newline()
							bottom_add_line()
#						end
						str = str[newlinePos + 1 ..]
					end
				end
				# There are no newlines in str from this point
				while str and !str.empty? do
					if @cursor[0]['col'] + str.length < @screen_width - 2
						printPartialLine str
						str = ""
					else
						printPartialLine str[0 .. @screen_width - @cursor[0]['col'] - 1]
						newline()
						bottom_add_line()
						str = str[@screen_width - @cursor[0]['col'] ..]
					end
				end
			elsif @window == 1
				# Top window (1)
				newlinePos = 1
				while str and newlinePos do
					newlinePos = str.index(/\n/)
					if newlinePos
						if newlinePos > 0
							printPartialLine str[0, newlinePos]
						else
							newline()
						end
						str = str[newlinePos + 1 ..]
					end
				end
				# There are no newlines in str from this point
				printPartialLine str
			else
				# Statusline (2)
				newlinePos = str.index(/\n/)
				str = str[0, newlinePos] if newlinePos
				printPartialLine str
			end
		end
		flushBuffer() if flush
	end
	def flushBuffer
		if @buffer.length > 0
			printPartialLine @buffer
			refreshBottomWindow()
			@buffer = ""
		end
	end
	def debug
		puts @window_content.to_s
	end

	def get_key_state
	  STDIN.raw do |io|
		begin
		  input = io.read_nonblock(3)

		  # Normalize Windows arrow keys
		  if Gem.win_platform?
			case input
			when "\xE0H" then return :up
			when "\xE0P" then return :down
			when "\xE0K" then return :left
			when "\xE0M" then return :right
			end
		  else
			# Normalize Linux/macOS escape sequences
			case input
			when "\e[A" then return :up
			when "\e[B" then return :down
			when "\e[C" then return :right
			when "\e[D" then return :left
			end
		  end

		  return input

		rescue IO::WaitReadable, EOFError
		  return nil
		end
	  end
	end
	def readChar
		loop do
			key = get_key_state()
			return key if key
			sleep 0.05
		end
	end
	def readInput(max_chars)
		total = ""
		loop do
			key = get_key_state()
			if key == 13.chr
				return total
			elsif key == 8.chr
				if total.length > 0
					total = total[0, total.length - 1] 
					print key + " " + key
				end
			elsif total.length < max_chars
#				print "(#{key.ord})"
				total += key
				print key
			end
			sleep 0.05
		end
	end

end # ScreenClass

class StreamsClass
	def initialize(#screenObject
		)
#		@screenObject = screenObject
		@outputStreams = [
				nil,
				{ 'active' => true },  # screen
				{ 'active' => false }, # transcript
				{ 'active' => false }, # memory
				{ 'active' => false }, # command transcript
		]
		@inputStreams = [
				{ 'active' => true },  # keyboard
				{ 'active' => false }, # command file
		]
		@commands = ""
	end
	def activateInput(stream)
		return false if !stream or stream < 0 or stream > 1
		return true if @inputStreams[stream]['active']
		if stream == 0
			@inputStreams[0]['active'] = true
			@inputStreams[1]['active'] = false
			@commands = ""
		else
			$screen.printBuffered("Please enter filename for command file to read: ", true)
			filename = STDIN.gets.chomp
			if filename.length == 0
				return false
			elsif filename =~/\.\.|~|\// 
				puts "Illegal characters in filename."
				return false
			elsif !File.exist?(filename)
				puts "File not found."
				return false
			else
				@commands = IO.read(filename)
				@inputStreams[1]['active'] = true
				@inputStreams[0]['active'] = false
				return true
			end
		end
	end
	def readInput(maxchars)
		if @inputStreams[0]['active']
#			command = STDIN.gets.chomp
			command = $screen.readInput(maxchars)
		else
			if @commands.empty?
				activateInput(0)
				command = readInput()
			else
				pos = @commands.index(/\n/)
				if pos
					command = @commands[0, pos]
					@commands = @commands[pos + 1 ..]
				else
					command = @commands
#					$screen.printBuffered ">#{command}<"
					@commands = ""
				end
				printASCIICommand(command, true)
			end
		end
		command
	end
	def activateOutput(stream, arg = nil)
		return false if !stream or stream < 1 or stream > 4
		hash = @outputStreams[stream]
		return true if hash['active']
		if stream == 2 and !hash.has_key? 'filename'
			$screen.printBuffered("Please enter filename for transcript: ", true)
			filename = STDIN.gets.chomp
			if filename.length == 0
				return false
			elsif filename =~/\.\.|~|\// 
				puts "Illegal characters in filename."
				return false
			elsif File.exist?(filename)
				puts "File exists."
				return false
			else
				IO.write(filename,'')
				hash['active'] = true
				hash['filename'] = filename
				writeWord(0x10, readWord(0x10) | 1)
				return true
			end
		elsif stream == 3
			hash['stack'] = [] unless hash.has_key? 'stack'
			fatalErr("Too many active memory streams!") if hash['stack'].length >= 16
			hash['active'] = true
			arg2 = arg + 2
			hash['stack'] = hash['stack'].push({'start' => arg, 'current' => arg2 })
#			$screen.printBuffered(@outputStreams.to_s, true)
		elsif stream == 4
			$screen.printBuffered("Please enter filename for command recording: ", true)
			filename = STDIN.gets.chomp
			if filename.length == 0
				return false
			elsif filename =~/\.\.|~|\// 
				puts "Illegal characters in filename."
				return false
			elsif File.exist?(filename)
				puts "File exists."
				return false
			else
				IO.write(filename,'')
				hash['active'] = true
				hash['filename'] = filename
				return true
			end
		end
	end
	def inactivateOutput(stream, reset = false)
		return false if !stream or stream < 1 or stream > 4
		hash = @outputStreams[stream]
		return true if !hash['active']
		hash['active'] = false
#		$screen.printBuffered @outputStreams.to_s
		if stream == 2
			writeWord(0x10, readWord(0x10) & 0xfffe)
		elsif stream == 3
			if reset
				hash.delete 'stack' if hash.has_key? 'stack'
				return true
			end
			stack = hash['stack']
			fatalErr("No active memory stream to close!") unless stack and !stack.empty?
			frame = stack.pop
			writeWord(frame['start'], frame['current'] - frame['start'] - 2)
			hash.delete 'stack' if stack.empty?
		end
		true
	end
	def ZSCIItoASCII (str)
		result = ""
		str.each_char do |char|
			code = char.ord
			result +=
				case
					when (code >= 155 and code <= 223) then $default_unicode[code - 155]
					when code == 13 then "\n"
					else char
				end
		end
		result
	end
	def printZSCIIString(str, flush = false)
		if @outputStreams[3]['active']
			frame = @outputStreams[3]['stack'].last
			address = frame['current']
			str.each_char do |char|
				writeByte(address, char.ord)
				address += 1
			end
			frame['current'] = address
		else
			strASCII = ZSCIItoASCII(str)
			if @outputStreams[1]['active']
				$screen.printBuffered(strASCII, flush)
			end
			if @outputStreams[2]['active'] and $screen.window == 0
				File.open(@outputStreams[2]['filename'], 'a') do |file|
					file.print strASCII
				end
			end
		end
	end
	def printASCIICommand(strASCII, echoToScreen = false)
		strASCII = strASCII.chomp()
		if @outputStreams[1]['active'] and echoToScreen
#			strASCII.each_char { |x| print"#{x.ord}," }
			$screen.printBuffered(strASCII + "\n", true)
			$screen.refreshBottomWindow()
		end
		if @outputStreams[2]['active']
			File.open(@outputStreams[2]['filename'], 'a') do |file|
				file.puts strASCII
			end
		end
		if @outputStreams[4]['active']
			File.open(@outputStreams[4]['filename'], 'a') do |file|
				file.puts strASCII
			end
		end
	end
end # StreamsClass

class StackClass
	def initialize
		@stack = [{}]
		@locals = nil
		@pushed = nil
	end
	def depth
		@stack.length
	end
	def throw(value, target_depth)
		if depth() < target_depth
			fatalErr "PC=$#{$pc.to_s(16)}: stack.throw: No such frame (#{target_depth})!"
		end
		packCurrentFrame()
		@stack = @stack.first(target_depth)
		return(value)
	end
	def packCurrentFrame
		frame = @stack.last
		if @locals and !@locals.empty?
			frame['loc'] = @locals
		else
			frame.delete('loc')
		end
		if @pushed and !@pushed.empty?
			frame['push'] = @pushed
		else
			frame.delete('push')
		end
		nil
	end
	def stackForSave
		packCurrentFrame()
		@stack.dup
	end
	def stackForSave=(stack)
		@stack = stack
		frame = @stack.last
		@locals = frame['loc']
		@pushed = frame['pushed']
		@stack
	end
	def readLocal(n)
		if @locals.length < n
			puts "Stack is #{@stack}"
			puts "Locals is #{@locals}"
			fatalErr "PC=$#{$pc.to_s(16)}, readLocal: Local ##{n} doesn't exist!"
		end
		@locals[n-1]
	end
	def setLocal(n, value)
		if @locals.length < n
			puts "Stack is #{@stack}"
			puts "Locals is #{@locals}"
			fatalErr "PC=$#{$pc.to_s(16)}, setLocal: Local ##{n} doesn't exist!"
		end
		@locals[n-1] = value
	end
	def call(paddress, args, store)
		packCurrentFrame()
		new_frame = {
			'ret' => $pc,
			'sto' => store,
			'arg' => args
		}
		$pc = unpackRoutinePaddress(paddress)
		varCount = readByteAtPC()
		@locals = Array.new(size = varCount, default = 0)
		@pushed = nil
		if $zcode_version < 5
			varCount.times do |i|
				if i < args.length
					@locals[i] = args[i]
					$pc += 2
				elsif i < @locals.length
					@locals[i] = readWordAtPC()
				else
					readWordAtPC()
				end
			end
		else
			args.length.times do |i|
				@locals[i] = args[i] # if i < varCount - 1
			end
		end
		@stack.push new_frame
	end
	def return(value)
		frame = @stack.pop
		$pc = frame['ret']
		store = frame['sto']
		frame = @stack.last
		@locals = frame['loc']
		@pushed = frame['push']
		if store
			setVar(readByteAtPC(), value)
		end
	end
	def push(value)
		@pushed = [] unless @pushed
		if @pushed.length > 10000
			fatalErr "PC=$#{$pc.to_s(16)}: stack.push: Too many values on stack!"
		end
		@pushed.push value
		value
	end
	def pop
		if @pushed.length < 1
			fatalErr "PC=$#{$pc.to_s(16)}: stack.pop: No values on stack!"
		end
		@pushed.pop
	end
end #StackClass

def readGlobal(n)
	readWord(2 * n + $global_base)
end

def setGlobal(n, value)
	address = 2 * n + readWord(0xc) - 32
	$z[address .. address + 1] = [value].pack('n')
end

def readVar(n)
	case
		when n == 0 then $stack.pop
		when n < 16 then $stack.readLocal(n)
		else readGlobal(n)
	end
end

def setVar(n, value)
	case
		when n == 0 then $stack.push value
		when n < 16 then $stack.setLocal(n, value)
		else setGlobal(n, value)
	end
end

def condBranch(result)
	offset = 0
	byte0 = readByteAtPC()
	result = byte0 & 0x80 == 0 ? !result : result
	if !result 
		# Do not branch
		readByteAtPC() if byte0 & 0x40 == 0
		return
	end
	
	if byte0 & 0x40 != 0
		offset = byte0 & 0x3f
#		puts "1Base offset is #{offset}!"
	else
		offset = ((byte0 & 0x3f) << 8) + readByteAtPC()
#		puts "2Base offset is #{offset}!"
		if offset > (1<<13) - 1
			offset -= 1<<14
		end
	end
#	puts "Final offset is #{offset}!"
	if offset == 0 or offset == 1
		$stack.return offset;
	else
		$pc += offset - 2
	end	
end

def objectAddress(n)
	case
		when $zcode_version < 4 then
			$object_table + 53 + 9 * n;
		else
			$object_table + 112 + 14 * n;
	end
end

def getParent(objaddress)
	case
		when $zcode_version < 4 then
			readByte(objaddress + 4)
		else
			readWord(objaddress + 6)
	end
end

def setParent(objaddress, parent)
	if $zcode_version < 4
		writeByte(objaddress + 4, parent)
	else
		writeWord(objaddress + 6, parent)
	end
end

def getSibling(objaddress)
	case
		when $zcode_version < 4 then
			readByte(objaddress + 5)
		else
			readWord(objaddress + 8)
	end
end

def setSibling(objaddress, sibling)
	if $zcode_version < 4
		writeByte(objaddress + 5, sibling)
	else
		writeWord(objaddress + 8, sibling)
	end
end

def getChild(objaddress)
	case
		when $zcode_version < 4 then
			readByte(objaddress + 6)
		else
			readWord(objaddress + 10)
	end
end

def setChild(objaddress, child)
	if $zcode_version < 4
		writeByte(objaddress + 6, child)
	else
		writeWord(objaddress + 10, child)
	end
end

def printAtAddress(address, return_string = false)
#		$streams.printZSCIIString("X") unless return_string
	word = 0
	alphabet_offset_lock = 0
	alphabet_offset = 0
	abbrev_bank = 0
	escape_step = 0
	escape_code = 0
	str = ""
	until word & 0x8000 != 0 do
		word = readWord(address)
		address += 2
		values = [	(word & 0b0111110000000000) >> 10,
					(word & 0b0000001111100000) >> 5,
					(word & 0b0000000000011111) ]

		values.each do |value|
			char = nil
			
			if escape_step > 0
				escape_code = (escape_code << 5) | value
				escape_step -= 1
				char = (escape_code & 0xff).chr if escape_step == 0
			elsif abbrev_bank > 0
				alphabet_offset = 0
				abbpointer = $abbrev_table + 2 * (32 * abbrev_bank - 32 + value)
				abbaddress = 2 * readWord(abbpointer)
				str += printAtAddress(abbaddress, true)
				abbrev_bank = 0
			elsif alphabet_offset == 2 and value == 6
				 alphabet_offset = 0
				 escape_step = 2
				 escape_code = 0
			elsif alphabet_offset == 2 and value == 7 and $zcode_version > 1
				char = 13.chr
			elsif value > 5
				char = $alphabet[26 * alphabet_offset + value - 6]
				if char.ord >= 155 and char.ord <= 223
					char = $default_unicode[char.ord - 154]
				end
			elsif value == 0
				char = ' '
			elsif value == 1
				if $zcode_version == 1 then
					char = 13.chr
				else
					abbrev_bank = 1
				end
			elsif value == 2
				if $zcode_version < 3 then
					alphabet_offset = (alphabet_offset_lock + 1) % 3
				else
					abbrev_bank = 2
				end
			elsif value == 3
				if $zcode_version < 3 then
					alphabet_offset = (alphabet_offset_lock + 2) % 3
				else
					abbrev_bank = 3
				end
			elsif value == 4
				if $zcode_version < 3 then
					alphabet_offset_lock = (alphabet_offset_lock + 1) % 3
					alphabet_offset = alphabet_offset_lock
				else
					alphabet_offset = 1
				end
			elsif value == 5
				if $zcode_version < 3 then
					alphabet_offset_lock = (alphabet_offset_lock + 2) % 3
					alphabet_offset = alphabet_offset_lock
				else
					alphabet_offset = 2
				end
			end
			if char
				str += char
				if return_string == false and str.length > 79
					$streams.printZSCIIString str.to_s # char.to_s
					str = ""
				end
				alphabet_offset = alphabet_offset_lock
			end
		end
		
	end

	return str if return_string
	
	$streams.printZSCIIString str unless str.empty?
#		$streams.printZSCIIString("Y")

	address
end

def toSigned(num)
	num > 32767 ? num - 65536 : num
end

def toUnsigned(num)
	num < 0 ? num + 65536 : num
end

def illegalInstruction
	fatalErr "PC=$#{$pc.to_s(16)}: illegalInstruction encountered!"
end

####################################
#           INSTRUCTIONS           #
####################################

def insRtrue
	$stack.return 1
end

def insRfalse
	$stack.return 0
end

def insPrint
	$pc = printAtAddress($pc)
end

def insPrintRet
	$pc = printAtAddress($pc)
	$streams.printZSCIIString "\n";
	$stack.return 1
end

def insNop
	nil
end

def saveGame
	success = false
	$streams.printZSCIIString("Please enter a filename: ", true)
	filename = STDIN.gets.chomp
	if filename.length == 0
		nil
	elsif filename =~/\.\.|~|\// 
		puts "Illegal characters in filename."
	elsif File.exist?(filename)
		puts "File exists."
	else
		savedata = {
			'pc' => $pc,
			'stack' => $stack.stackForSave,
			'dynmem' => Base64.encode64($z[0 .. readWord(0xe) - 1])
		}
		json = JSON.generate(savedata)
		IO.binwrite(filename, json)
		success = true
	end
	success
end

def insSavePreZ5
	success = saveGame()
	if $zcode_version < 4
		condBranch(success)
	else ## if $zcode_version == 4
		setVar(readByteAtPC(), success ? 1 : 0)
	end
end

def forkInsSaveOrIllegal
	if $zcode_version < 5
		insSavePreZ5()
	else
		illegalInstruction();
	end
end

def restoreGame
	success = false
	$streams.printZSCIIString("Please enter a filename: ", true)
	filename = STDIN.gets.chomp
	if filename.length == 0
		nil
	elsif filename =~ /\.\.|~|\//
		puts "Illegal characters in filename."
	elsif !File.exist?(filename)
		puts "File not found."
	else
		savefiledata = IO.binread(filename)
		success = true
		begin
			savedata = JSON.parse(savefiledata)
		rescue JSON::ParserError
			puts "Not a valid save file."
			success = false
		end
		if success
			$pc = savedata['pc']
			$stack.stackForSave = savedata['stack']
			$z[0 .. readWord(0xe) - 1] = Base64.decode64(savedata['dynmem'])
			updateHeader()
			writeWord(0x10, readWord(0x10) & 0xfffe | $transcriptBit)
			$screen.unsplit() if $zcode_version == 3
		end
	end
	success
end

def insRestorePreZ5
	success = restoreGame()
	if $zcode_version < 4
		condBranch(success)
	else ## if $zcode_version == 4
		setVar(readByteAtPC(), success ? 1 : 0)
	end
end

def forkInsRestoreOrIllegal
	if $zcode_version < 5
		insRestore()
	else
		illegalInstruction();
	end
end

def insRestart
	initializeGame()
	writeWord(0x10, readWord(0x10) & 0xfffe | $transcriptBit)
end

def insRetPopped
	$stack.return $stack.pop
end

def insPop
	$stack.pop()
end

def insCatch
	setVar(readByteAtPC(), $stack.depth)
end

def forkInsPopOrCatch
	if $zcode_version < 5
		insPop()
	else
		insCatch()
	end
end

def insQuit
#	puts "<Hit any key to exit>";
#	STDIN.gets
	$quit = true
end

def insNewLine
	$streams.printZSCIIString 13.chr;
end

def insShowStatus
	# Works like NOP in v4+
	if $zcode_version < 4
		$screen.showStatusline()
		$screen.refreshTopWindow()
	end
end

def insVerify
	condBranch(true)
end

def insPiracy
	condBranch(true)
end

def insJe
	match = false
	($args.count - 1).times do |x|
		if $args[0] == $args[1+x]
			match = true
			break
		end
	end
	condBranch(match)
end

def insJl
	condBranch(toSigned($args[0]) < toSigned($args[1]))
end

def insJg
	condBranch(toSigned($args[0]) > toSigned($args[1]))
end

def insDecChk
	value = readVar($args[0]) - 1
	value = 0xffff if value < 0
	setVar($args[0], value)
	condBranch(toSigned(value) < toSigned($args[1])) 
end

def insIncChk
	value = (readVar($args[0]) + 1) % 0x10000
	setVar($args[0], value)
	condBranch(toSigned(value) > toSigned($args[1])) 
end

def insJin
	condBranch(getParent(objectAddress($args[0])) == $args[1]) 
end

def insTest
	condBranch($args[0] & $args[1] == $args[1])
end

def insOr
	setVar(readByteAtPC(), $args[0] | $args[1])
end

def insAnd
	setVar(readByteAtPC(), $args[0] & $args[1])
end

def insTestAttr
	obj = objectAddress($args[0])
	byte0 = readByte(obj + ($args[1] / 8))
	condBranch((byte0 << ($args[1] % 8)) & 0x80 != 0)
end

def insSetAttr
	address = objectAddress($args[0]) + ($args[1] / 8)
	byte0 = readByte(address)
	writeByte(address, byte0 | (1 << (7 - ($args[1] % 8))))
end

def insClearAttr
	address = objectAddress($args[0]) + ($args[1] / 8)
	byte0 = readByte(address)
	writeByte(address, byte0 & ((1 << (7 - ($args[1] % 8))) ^ 0xffff))
end

def insJz
	condBranch($args[0] == 0)
end

def insGetSibling
	sibling = getSibling(objectAddress($args[0]))
	var = readByteAtPC();
	setVar(var, sibling)
	condBranch(sibling != 0)
end

def insGetChild
	child = getChild(objectAddress($args[0]))
	setVar(readByteAtPC(), child)
	condBranch(child != 0)
end

def insGetParent
	parent = getParent(objectAddress($args[0]))
	setVar(readByteAtPC(), parent)
end

def insGetPropLen
	address = $args[0]
	value = 0
	if address > 0
		value = readByte(address - 1)
		if $zcode_version < 4
			value = (value >> 5) + 1
		else
			if value & 0x80 != 0
				value &= 0b00111111
				value = 64 if value == 0
			else
				value = 1 + (value >> 6)
			end
		end
	end
	setVar(readByteAtPC(), value)
end

def insInc
	value = (readVar($args[0]) + 1) % 0x10000
	setVar($args[0], value)
end

def insDec
	value = readVar($args[0]) - 1
	value = 0xffff if value < 0
	setVar($args[0], value)
end

def insPrintAddr
	printAtAddress($args[0])
end

def insRemoveObj
	obj = $args[0]
	objaddress = objectAddress(obj)
	parent = getParent(objaddress)
	if parent != 0
		parentaddress = objectAddress(parent)
		oldersibling = getChild(parentaddress)
		if oldersibling == obj
			setChild(parentaddress, getSibling(objaddress))
		else
			while oldersibling != 0 do
				nextsibling = getSibling(objectAddress(oldersibling))
				break if nextsibling == obj
				oldersibling = nextsibling
			end
			if oldersibling == 0
				fatalErr "PC=$#{$pc.to_s(16)}: remove_obj: Malformed object tree detected!"
			end
			setSibling(objectAddress(oldersibling), getSibling(objaddress))
		end
	end
	setParent(objaddress, 0)
	setSibling(objaddress, 0)
end

def printObjectName(obj)
	address = objectAddress(obj) + 
		($zcode_version < 4 ? 7 : 12)
	props = readWord(address)
	if readByte(props) > 0
		printAtAddress(props + 1)
	end
end

def insPrintObj
	printObjectName($args[0])
end

def insRet
	$stack.return $args[0]
end

def insJump
	offset = $args[0]
	if offset > (1<<15) - 1
		offset -= 1<<16
	end
#	puts "Final offset is #{offset}!"
	$pc += offset - 2
end

def insPrintPaddr
	printAtAddress(unpackStringPaddress($args[0]))
end

def insLoad
	# Indirect variable, so we need to re-push to stack if it's variable 0
	val = readVar($args[0])
	$stack.push(val) if $args[0] == 0
	setVar(readByteAtPC(), val)
end

def insNot
	setVar(readByteAtPC(), $args[0] ^ 0xffff)
end

def insCallN
	if $args[0] != 0
		$stack.call($args[0], $args.drop(1), false)
	end
end

def forkInsNotOrCallN
	if $zcode_version < 5
		insNot()
	else
		insCallN();
	end
end

def insStore
	$stack.pop if $args[0] == 0 # Should alter the top value, not add a new onw
	setVar($args[0], $args[1])
end

def insInsertObj
	obj = $args[0]
	destobj = $args[1]
	objaddress = objectAddress(obj)
	destobjaddress = objectAddress(destobj)
	parent = getParent(objaddress)
	if parent != 0
		parentaddress = objectAddress(parent)
		oldersibling = getChild(parentaddress)
		if oldersibling == obj
			setChild(parentaddress, getSibling(objaddress))
		else
			while oldersibling != 0 do
				nextsibling = getSibling(objectAddress(oldersibling))
				break if nextsibling == obj
				oldersibling = nextsibling
			end
			if oldersibling == 0
				fatalErr "PC=$#{$pc.to_s(16)}: insert_obj: Malformed object tree detected!"
			end
			setSibling(objectAddress(oldersibling), getSibling(objaddress))
		end
	end
	setParent(objaddress, destobj)
	setSibling(objaddress, getChild(destobjaddress))
	setChild(destobjaddress, obj)
end

def insLoadw
	address = $args[0] + 2 * $args[1]
	setVar(readByteAtPC(), readWord(address))
end

def insLoadb
	address = $args[0] + $args[1]
	setVar(readByteAtPC(), readByte(address))
end

def getProp(obj, propnum, next_after_prop = false)
	# If next_after_prop == true, look for NEXT prop after propnum,
	# or FIRST prop if propnum == 0
	#
	# Return: [ prop, address of data, length ]

	address = objectAddress(obj) + ($zcode_version < 4 ? 7 : 12)
	address = readWord(address) # After this, address points to property table
	done = false
	found = false
	lastpropnum = 0
	if address != 0 and (propnum > 0 || next_after_prop)
		address += 2 * readByte(address) + 1 # Now pointing to first property in table
		byte0 = 1000
		thispropnum = 1000
		until done do
			byte0 = readByte(address)
			if $zcode_version < 4
				thispropnum = byte0 & 0b00011111
				length = (byte0 >> 5) + 1
			else
				thispropnum = byte0 & 0b00111111
				length = byte0 & 0x40 == 0 ? 1 : 2
				if byte0 & 0x80 != 0
					address += 1
					byte1 = readByte(address)
					length = byte1 & 0b00111111
					length = 64 if length == 0
				end
			end
			if propnum == (next_after_prop ? lastpropnum : thispropnum)
				address += 1
				length = length
				done = true
				found = true
			elsif thispropnum < propnum 
				done = true
			else
				address += length + 1
			end
			lastpropnum = thispropnum
		end
	end

	case 
		when found then 
			[ thispropnum, address, length ]
		else
			[ 0, 0, 0 ]
	end
end

def insGetProp
	val = 0
	(propnum, address, length) = getProp($args[0], $args[1])
	if propnum == 0
		# Retrieve default value
		val = readWord($object_table + 2 * $args[1] - 2)
	else
		val = 
			case
				when length == 1 then readByte(address)
				when length == 2 then readWord(address)
				else 0
			end
	end
	setVar(readByteAtPC(), val)
end

def insGetPropAddr
	(propnum, address, length) = getProp($args[0], $args[1])
	setVar(readByteAtPC(), address)
end

def insGetNextProp
	(propnum, address, length) = getProp($args[0], $args[1], true)
	setVar(readByteAtPC(), propnum)
end

def insAdd
	v1 = toSigned($args[0]) 
	v2 = toSigned($args[1])
	sum = toUnsigned(v1 + v2)
	setVar(readByteAtPC, sum)
end

def insSub
	v1 = toSigned($args[0]) 
	v2 = toSigned($args[1])
	diff = toUnsigned(v1 - v2)
	setVar(readByteAtPC(), diff)
end

def insMul
	v1 = toSigned($args[0])
	v2 = toSigned($args[1])
	prod = v1 * v2
	# Convert product to unsigned 32-bit
	prod = prod < 0 ? prod + (1 << 32) : prod
	# Convert to unsigned 16-bit
	prod = prod & 0xffff
	
	setVar(readByteAtPC(), prod)
end

def insDiv
	v1 = toSigned($args[0])
	v2 = toSigned($args[1])
	flip = false
	if v1 < 0 && v2 > 0 or v1 > 0 && v2 < 0
		flip = true
		v1 = v1 < 0 ? -v1 : v1
		v2 = v2 < 0 ? -v2 : v2
	end
	result = v1 / v2
	result = flip ? -result : result
	# Convert product to unsigned 32-bit
	result = result < 0 ? result + (1 << 32) : result
	# Convert to unsigned 16-bit
	result = result & 0xffff
	
	setVar(readByteAtPC(), result)
end

def insMod
	v1base = toSigned($args[0])
	v2base = toSigned($args[1])
	v1 = v1base < 0 ? -v1base : v1base
	v2 = v2base < 0 ? -v2base : v2base

	result = v1 % v2
	result = -result if v1base < 0

	result = toUnsigned(result)
	
	setVar(readByteAtPC(), result)
end

def insCallS
	if $args[0] == 0
		setVar(readByteAtPC(), 0)
	else
		$stack.call($args[0], $args.drop(1), true)
	end
end

def insSetColour
	# If implemented, should print any text already in buffer in old colours
	nil
end

def insThrow
	$stack.throw($args[0], $args[1])
end

def insStorew
	address = $args[0] + 2 * $args[1]
	writeWord(address, $args[2])
end

def insStoreb
	address = $args[0] + $args[1]
	writeByte(address, $args[2])
end

def insPutProp
	(propnum, address, length) = getProp($args[0], $args[1])
	if propnum == 0
		fatalErr "PC=$#{$pc.to_s(16)}, put_prop: Object ##{$args[0]} " + 
			"doesn't provide property ##{$args[1]}!"
	end
	if length == 1
		writeByte(address, $args[2] & 0xff)
	elsif length == 2
		writeWord(address, $args[2])
	end
end

def encodeWord(word)
	intermediate = []
	word.each_char do |char|
		index = $alphabet.index char
		hash = nil
		if index
			hash = {
				'alphabet_row' => index / 26,
				'code' => index % 26 + 6
			}
		else
			charcode = char.ord
			accentedpos = $default_unicode.index(char)
			charcode = 155 + accentedpos if accentedpos
			hash = {
				'zscii' => charcode
			}
		end
		intermediate.push hash
	end
	
	codes = []
	max_codes = $zcode_version < 4 ? 6 : 9
	intermediate.each do |hash|
		row = hash['alphabet_row']
		# NOTE: This code is NOT correct for v1-v2!
		if row
			if row > 0
				codes.push row + 3
			end
			codes.push hash['code']
		else
			num = hash['zscii']
			codes += [5, 6, num >> 5, num & 0b00011111]
		end
		break if codes.length >= max_codes
	end

	if codes.length < max_codes
		codes += Array.new(max_codes - codes.length, 5)
	elsif codes.length > max_codes
		codes = codes.first(max_codes)
	end

	code_pointer = 0
	bin = ""
	while code_pointer < max_codes do
		val = (codes[code_pointer] << 10) +
				(codes[code_pointer + 1] << 5) +
				codes[code_pointer + 2]
		val |= 0x8000 if code_pointer + 3 >= max_codes
		bin += (val >> 8).chr + (val & 0xff).chr
		code_pointer += 3
	end
	bin
end

def dictLookup(encodedWord)
	return 0 if $dict_entry_count == 0
	
	compare_length_m1 = ($zcode_version < 4 ? 4 : 6) - 1
	first = 0
	last = $dict_entry_count - 1
	
	while last > first do
		mid = (first + last) / 2
		mid_address = $dict_base + $dict_entry_length * mid
		compare = $z[mid_address .. mid_address + compare_length_m1] <=> encodedWord
		if compare == 0
			return mid_address
		elsif compare < 0
			first = mid + 1
		else
			last = mid - 1
		end
	end

	first_address = $dict_base + $dict_entry_length * first
	if $z[first_address .. first_address + compare_length_m1] == encodedWord
		return first_address
	end

	0
end

def insRead

	buffer = $args[0]
	byte0 = readByte(buffer)
	maxchars = $zcode_version < 5 ? byte0 - 1 : byte0
	parse = $args[1]
	maxparse = readByte(parse)

	### Perform input from keyboard
	
	$screen.flushBuffer()
	$screen.showStatusline() if $zcode_version < 4
	$screen.refreshTopWindow()
	$screen.refreshBottomWindow()
	$screen.bottom_clear_lines()
#	input = STDIN.gets.chomp[0 .. maxchars - 1].downcase
#	IO.console.goto($screen.screen_height - 2, 0)
	input = $streams.readInput(maxchars)[0 .. maxchars - 1].downcase
	$streams.printASCIICommand(input, true)

	### Write input into memory, and split it into words

	words = []
	word_start = nil
	buffer_pointer = buffer + 1
	string_pointer = 0
	last_char = nil

	input.each_char do |char|
		charcode = char.ord

		accentedpos = $default_unicode.index(char)
		charcode = accentedpos + 155 if accentedpos

		writeByte(buffer_pointer, charcode)
		if word_start
			if char == ' ' or
					$dict_separators.include? char or 
					$dict_separators.include? last_char
				word = input[word_start .. string_pointer - 1]
				hash = { 'word' => word, 'start' => word_start + 1 }
				words.push hash
				word_start = nil
			end
		end
		if word_start == nil && char != ' '
			word_start = string_pointer
		end
		last_char = char
		buffer_pointer += 1
		string_pointer += 1
	end

	if word_start
		word = input[word_start .. string_pointer - 1]
		hash = { 'word' => word, 'start' => word_start + 1}
		words.push hash 
	end
	
	if $zcode_version < 4
		writeByte(buffer_pointer, 0)
	end

	### Parse words

	parsed = 0
	words.each do |hash|
		break if parsed >= maxparse
		word = hash['word']
		dict = dictLookup(encodeWord(word))
		writeWord(parse + 4 * parsed + 2, dict)
		writeByte(parse + 4 * parsed + 4, word.length)
		writeByte(parse + 4 * parsed + 5, hash['start'])
		parsed += 1
	end

	writeByte(parse + 1, parsed)

	setVar(readByteAtPC(), 13) if $zcode_version > 4
	
end

def insPrintChar
	charcode = $args[0]
	char = charcode.chr
	
	char = $default_unicode[charcode - 155] if charcode >= 155 and charcode <= 223
	
	$streams.printZSCIIString char
end

def insPrintNum
	$streams.printZSCIIString "#{toSigned($args[0])}"
end

#######################################
#               PRNG
#
# Must work exactly like Ozmoo's PRNG,
# for Ozmoo's walkthroughs to work.
#######################################

def rndNumber
	# returns an 8-bit random number
	$rnd_x = ($rnd_x + 1) & 0xff
	$rnd_a = $rnd_x ^ $rnd_c ^ $rnd_a
	$rnd_b = ($rnd_a + $rnd_b) & 0xff
	$rnd_c = ((($rnd_b >> 1) ^ $rnd_a) + $rnd_c) & 0xff
#	puts "rnd_a = #{$rnd_a.to_s(16)} rnd_b = #{$rnd_b.to_s(16)} rnd_c = #{$rnd_c.to_s(16)} rnd_x = #{$rnd_x.to_s(16)}"
	$rnd_c
end	

def rndSeed(a, x, y)
	$rnd_a = a
	$rnd_b = x
	$rnd_c = y
	$rnd_x = a ^ 0xff
	rndNumber()
end

def rndSeedRandom
	seed = $random.bytes(3)
	rndSeed(seed[0].ord, seed[1].ord, seed[2].ord) 
end

def insRandom
	arg = toSigned($args[0])
	val = 0
	mask = 1
	if arg < 0
		rndSeed(
			((arg >> 8) + 0b10101010) % 256,
			arg & 0xff,
			arg >> 8
		)
	elsif arg == 0
		rndSeedRandom()
	else
		# Create a bit mask, 1, 11, 111, etc that is >= arg
		while mask < arg do
			mask = (mask << 1) | 1
		end
		# Draw random number, apply mask, redraw if too big
		val = 100000
		while val >= arg do
			val = rndNumber()
#			if arg > 255 # Due to a bug in Ozmoo, this must be commented out.
				val = (val << 8) | rndNumber()
#			end
			val &= mask
		end
		val += 1
	end
#		puts "arg = #{arg}  mask = #{mask}  val = #{val}"
	setVar(readByteAtPC(), val)
end

# End of PRNG code

def insPush
	$stack.push $args[0]
end

def insPull
	value = $stack.pop
	$stack.pop if $args[0] == 0 # Should alter the top value, not add a new one
	setVar($args[0], value)
end

def insSplitWindow
	lines = $args[0]
	if lines == 0
		$screen.unsplit()
	else
		$screen.split(lines)
	end
end

def insSetWindow
	$screen.selectWindow($args[0])
end

def insEraseWindow
	window = toSigned($args[0])
	if window == 0 or window == 1
		$screen.clearWindow(window)
		if window == 1
			$screen.setCursorTopLeft(1)
		elsif $zcode_version > 4
			$screen.setCursorTopLeft(0)
		else
			$screen.setCursorBottomLeft(0)
		end
	elsif window == -1
		$screen.unsplit()
		$screen.clearWindow(0)
		if $zcode_version > 4
			$screen.setCursorTopLeft(0)
		else
			$screen.setCursorBottomLeft(0)
		end
		$screen.selectWindow(0)
	elsif window == -2
		$screen.clearWindow(0)
		if $zcode_version > 4
			$screen.setCursorTopLeft(0)
		else
			$screen.setCursorBottomLeft(0)
		end
		$screen.clearWindow(1)
		$screen.setCursorTopLeft(1)
	end
end

def insEraseLine
	puts "Erase Line"
	exit 1	
end

def insSetCursor
	if $screen.window == 1
		$screen.setCursor(toSigned($args[0]) - 1, toSigned($args[1]) - 1)
	end
end

def insGetCursor
	(line, col) = $screen.getCursor()
	writeWord($args[0], line + 1)
	writeWord($args[0] + 2, col + 1)
end

def insSetTextStyle
	# Ignore, for now
end

def insBufferMode
	flag = $args[0]
	if flag == 0 or flag == 1
		$screen.buffered = flag == 1 ? true : false
	end
end

def insOutputStream
	stream = toSigned($args[0])
#	$screen.printBuffered "STREAM IS #{stream}"
	if stream < 0
		$streams.inactivateOutput(-stream)
	elsif stream == 3
		address = $args[1]
		$streams.activateOutput(stream, address)
	else
		$streams.activateOutput(stream)
	end
end

def insInputStream
	$streams.activateInput($args[0])
end

def insSoundEffect
	print "\007" if $args.empty? or [1,2].include? $args[0]
end

def insReadChar
	key = $screen.readChar()
	setVar(readByteAtPC(), key.ord)
end

def insScanTable
	(x, table, len, form) = $args[0 .. 3]
	address = 0
	form = 0x82 unless form
	wordmode = form & 0x80 > 0 ? true : false
	entry_len = form & 0x7f
	found = false
	if len > 0 and entry_len > 0
		address = table
		loop do
			val = wordmode ? readWord(address) : readByte(address)
			if val == x
				found = true
				break
			end
			address += entry_len
			len -= 1
			break if len < 1
		end
		address = 0 unless found
	end
	
	setVar(readByteAtPC(), address)
	condBranch(found)
end

def insCopyTable
	(first, second, size_value) = $args[0 .. 2]
	size_value = toSigned(size_value)
	size = size_value < 0 ? (-size_value) : size_value
	forward = true
	forward = false if size_value >= 0 and first < second

	if forward
		size.times do |i|
			writeByte(second + i, readByte(first + i))
		end
	else
		(size - 1).downto(0) do |i|
			writeByte(second + i, readByte(first + i))
		end
	end
end

def insPrintTable
	address = $args[0]
	width = $args[1]
	height = $args.length > 2 ? $args[2] : 1
	skip = $args.length > 3 ? $args[3] : 0
	line, col = $screen.getCursor()
	height.times do
		$screen.setCursor(line, col)
		$streams.printZSCIIString($z[address, width])
		address += height + skip
		line += 1
	end
end

def insCheckArgCount
	arg = $stack.stackForSave().last['arg']
	condBranch((arg != nil and arg.length >= $args[0]))
end

def insSaveZ5
	success = saveGame()
	setVar(readByteAtPC(), success ? 1 : 0)
end

def insRestoreZ5
	success = restoreGame()
	setVar(readByteAtPC(), success ? 2 : 0)
end


def insLogShift
	value = $args[0]
	places = toSigned($args[1])
	places = 0 if places < -15 or places > 15
	if places > 0
		value = (value << places) & 0xffff
	else
		value = value >> (-places)
	end
	setVar(readByteAtPC(), value)
end

def insArtShift
	value = $args[0]
	places = toSigned($args[1])
	places = 0 if places < -15 or places > 15
	if places > 0
		value = (value << places) & 0xffff
	else
		(-places).times do
			value >>= 1
			value = value | 0x8000 if value & 0x4000 != 0
		end
	end
	setVar(readByteAtPC(), value)
end

def insSetFont
	old_font = $font
	new_font = $args[0]
	if new_font == 0
		# Don't change, just return old font
		nil
	elsif new_font == 1 or new_font == 4
		$font = new_font
	else
		# Unavailable font
		old_font = 0
	end
	setVar(readByteAtPC(), old_font)
end

def insSaveUndo
	$undo_data = {
		'pc' => $pc,
		'stack' => $stack.stackForSave,
		'dynmem' => $z[0 .. readWord(0xe) - 1]
	}
	setVar(readByteAtPC(), 1)
end

def insRestoreUndo
	result = 0
	if $undo_data
		$pc = $undo_data['pc']
		$stack.stackForSave = $undo_data['stack']
		$z[0 .. readWord(0xe) - 1] = $undo_data['dynmem']
		$undo_data = nil
		updateHeader()
		writeWord(0x10, readWord(0x10) & 0xfffe | $transcriptBit)
		result = 2
	end
	setVar(readByteAtPC(), result)
end

def insPrintUnicode
	nil
end

def insCheckUnicode
	setVar(readByteAtPC(), 0)
end

$opcode_routines = {
	OPCODE_TYPE_0OP => [
		method(:insRtrue),
		method(:insRfalse),
		method(:insPrint),
		method(:insPrintRet),
		method(:insNop),
		method(:forkInsSaveOrIllegal), #save v1-v4
		method(:forkInsRestoreOrIllegal), #restore v1-v4
		method(:insRestart),
		method(:insRetPopped),
		method(:forkInsPopOrCatch),
		method(:insQuit),
		method(:insNewLine),
		method(:insShowStatus),
		method(:insVerify),
		method(:insPiracy), #piracy
	],
	OPCODE_TYPE_1OP => [
		method(:insJz),
		method(:insGetSibling),
		method(:insGetChild),
		method(:insGetParent),
		method(:insGetPropLen),
		method(:insInc),
		method(:insDec),
		method(:insPrintAddr),
		method(:insCallS), #call_1s v4+
		method(:insRemoveObj),
		method(:insPrintObj),
		method(:insRet),
		method(:insJump),
		method(:insPrintPaddr),
		method(:insLoad),
		method(:forkInsNotOrCallN),
	],
	OPCODE_TYPE_2OP => [
		nil,
		method(:insJe),
		method(:insJl),
		method(:insJg),
		method(:insDecChk),
		method(:insIncChk),
		method(:insJin),
		method(:insTest),
		method(:insOr),
		method(:insAnd),
		method(:insTestAttr),
		method(:insSetAttr),
		method(:insClearAttr),
		method(:insStore),
		method(:insInsertObj),
		method(:insLoadw),
		method(:insLoadb),
		method(:insGetProp),
		method(:insGetPropAddr),
		method(:insGetNextProp),
		method(:insAdd),
		method(:insSub),
		method(:insMul),
		method(:insDiv),
		method(:insMod),
		method(:insCallS), # call_2s v4+
		method(:insCallN), # call_2n v5+
		method(:insSetColour), # set_colour v5+
		method(:insThrow), # throw v5+
	],
	OPCODE_TYPE_VAR => [
		method(:insCallS),
		method(:insStorew),
		method(:insStoreb),
		method(:insPutProp),
		method(:insRead),
		method(:insPrintChar),
		method(:insPrintNum),
		method(:insRandom),
		method(:insPush),
		method(:insPull),
		method(:insSplitWindow),
		method(:insSetWindow),
		method(:insCallS), #call_vs2 v4+
		method(:insEraseWindow),
		method(:insEraseLine), #erase_line v4+
		method(:insSetCursor),
		method(:insGetCursor),
		method(:insSetTextStyle),
		method(:insBufferMode),
		method(:insOutputStream),
		method(:insInputStream),
		method(:insSoundEffect),
		method(:insReadChar),
		method(:insScanTable),
		method(:insNot), #not v5+
		method(:insCallN), #call_vn v5+
		method(:insCallN), #call_vn2 v5+
		nil, #tokenise v5+
		nil, #encode v5+
		method(:insCopyTable),
		method(:insPrintTable),
		method(:insCheckArgCount),
	],
	OPCODE_TYPE_EXT => [
		method(:insSaveZ5),
		method(:insRestoreZ5),
		method(:insLogShift),
		method(:insArtShift),
		method(:insSetFont),
		nil,
		nil,
		nil,
		nil,
		method(:insSaveUndo),
		method(:insRestoreUndo),
		method(:insPrintUnicode),
		method(:insCheckUnicode),
		nil, #set_true_colour v5+
	],
}

def readWord(p_address)
	$z[p_address .. p_address + 1].unpack('n*')[0]
end

def writeWord(p_address, value)
	$z[p_address .. p_address + 1] = [value].pack('n')
end

def readByte(p_address)
	$z[p_address].ord
end

def writeByte(p_address, value)
	$z[p_address] = value.chr
end


def readByteAtPC
	$pc += 1
	$z[$pc - 1].ord
end

def readWordAtPC
	$pc += 2
	$z[$pc - 2 .. $pc - 1].unpack('n*')[0]
end

def readInstruction
	opcode_type = nil
	opcode_number = nil
	operand_types = []

	# Step 1: Read opcode, decide form, opcode type, opcode# and operand type(s).
	opcode = readByteAtPC()
	form = FORM_EXT
	if $zcode_version < 5 or opcode != 0xbe
		topbits = (opcode & 0b11000000) >> 6
		form =
			case
				when topbits == 0b11 then FORM_VAR
				when topbits == 0b10 then FORM_SHORT
				else FORM_LONG
			end
	end
	case
		when form == FORM_SHORT then
			vartype = (opcode & 0b110000) >> 4
			if vartype == 0b11
				opcode_type = OPCODE_TYPE_0OP
			else
				opcode_type = OPCODE_TYPE_1OP
				operand_types.push vartype
			end
			opcode_number = opcode & 0b1111
		when form == FORM_LONG then
			opcode_type = OPCODE_TYPE_2OP
			vartype1 = (opcode & 0b1000000) >> 6
			if vartype1 == 0b1
				operand_types.push OPERAND_TYPE_VAR
			else
				operand_types.push OPERAND_TYPE_SMALLCONST
			end
			vartype2 = (opcode & 0b100000) >> 5
			if vartype2 == 0b1
				operand_types.push OPERAND_TYPE_VAR
			else
				operand_types.push OPERAND_TYPE_SMALLCONST
			end
			opcode_number = opcode & 0b11111
		when form == FORM_VAR then
			opcode_type_flag = (opcode & 0b100000) >> 5
			if opcode_type_flag == 0b1
				opcode_type = OPCODE_TYPE_VAR
			else
				opcode_type = OPCODE_TYPE_2OP
			end
			opcode_number = opcode & 0b11111
			operand_type_byte = readByteAtPC()
			operand_type_byte_2 = -1
			if opcode_type == OPCODE_TYPE_VAR and 
						[0xc, 0x1a].include? opcode_number
				operand_type_byte_2 = readByteAtPC()
			end
			operand_types = [
					(operand_type_byte & 0b11000000) >> 6,
					(operand_type_byte & 0b00110000) >> 4,
					(operand_type_byte & 0b00001100) >> 2,
					(operand_type_byte & 0b00000011) ]
			if operand_type_byte_2 >= 0
				operand_types += [
						(operand_type_byte_2 & 0b11000000) >> 6,
						(operand_type_byte_2 & 0b00110000) >> 4,
						(operand_type_byte_2 & 0b00001100) >> 2,
						(operand_type_byte_2 & 0b00000011) ]
			end
		when form == FORM_EXT then
			opcode_type = OPCODE_TYPE_EXT
			opcode_number = readByteAtPC()
			operand_type_byte = readByteAtPC()
			operand_types = [
					(operand_type_byte & 0b11000000) >> 6,
					(operand_type_byte & 0b00110000) >> 4,
					(operand_type_byte & 0b00001100) >> 2,
					(operand_type_byte & 0b00000011) ]
		else
			fatalErr "ERROR: Incorrect form!"
	end
	
	# Step 2: Read operands
	
	operand_values = []
	operand_types.each do |type|
		case
			when type == OPERAND_TYPE_LARGECONST then
				operand_values.push readWordAtPC()
			when type == OPERAND_TYPE_SMALLCONST then
				operand_values.push readByteAtPC()
			when type == OPERAND_TYPE_VAR then
				operand_values.push readVar(readByteAtPC())
		end
	end
	
	{
		'opcode_type' => opcode_type,
		'opcode_number' => opcode_number,
		'operand_types' => operand_types,
		'operand_values' => operand_values
	}
end

def updateHeader
	flags1 = readByte(1)
	if $zcode_version < 4
		# Variable pitch font not default, supports screen split, but supports statusline
		flags1 &= (255 - 64 - 16)
		flags1 |= 32
	end
	writeByte(1, flags1)

	writeByte(0x32, 0) # Standard revision, major version
	writeByte(0x33, 0) # Standard revision, minor version
	
	if $zcode_version > 3
		writeByte(0x1e, 2) # Interpreter = Apple IIe
		writeByte(0x1f, 1) # Interpreter version = 1
		writeByte(0x20, $screen.screen_height) # Screen height in characters
		writeByte(0x21, $screen.screen_width - 1) # Screen width in characters
		if $zcode_version > 4
			writeWord(0x22, $screen.screen_width - 1) # Screen width in units
			writeWord(0x24, $screen.screen_height)  # Screen height in units
			writeByte(0x26, 1) # Font width in units
			writeByte(0x27, 1) # Font height in units
			writeByte(0x2c, 9) # Default background colour (white)
			writeByte(0x2d, 2) # Default foreground colour (black)
		end
	end

end

def initializeGame

	$stack = StackClass.new

	$screen = ScreenClass.new

	$random = Random.new
	
	$streams.activateOutput(1)
	$streams.inactivateOutput(3, true)

	$undo_data = nil
	
	$font = 1
	
	rndSeedRandom()
#	rndSeed(0xff, 0x80, 0x01) # For benchmark mode

	$z[0 .. readWord(0xe) - 1] = $dynmem_backup 

	$pc = readWord(6)
	$object_table = readWord(0xa)

	$dictionary = readWord(0x8)
	sep_count = readByte($dictionary)
	$dict_separators = $z[$dictionary + 1  .. $dictionary + sep_count]
	$dict_entry_length = readByte($dictionary + sep_count + 1)
	$dict_entry_count = readWord($dictionary + sep_count + 2)
	$dict_base = $dictionary + sep_count + 4

	$routine_offset = $zcode_version == 7 ? 8 * readWord(0x28) : nil
	$string_offset = $zcode_version == 7 ? 8 * readWord(0x2a) : nil
	$abbrev_table = $zcode_version > 1 ? readWord(0x18) : nil

	$global_base = readWord(0xc) - 32

	alphabetaddress = $zcode_version > 4 ? readWord(0x34) : 0
	if alphabetaddress == 0
		$alphabet =
			"abcdefghijklmnopqrstuvwxyz" +
			"ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
			( $zcode_version == 1 ?
				" 0123456789.,!?_#'\"/\\<-:()" :
				" ^0123456789.,!?_#'\"/\\-:()" )
	else
		$alphabet =
			$z[alphabetaddress .. alphabetaddress + 77]
	end

	$default_unicode = "äöüÄÖÜß»«ëïÿËÏáéíóúýÁÉÍÓÚÝàèìòùÀÈÌÒÙâêîôûÂÊÎÔÛåÅøØãñõÃÑÕæÆçÇþðÞÐ£œŒ¡¿"

	updateHeader()
	
	$screen.clear()
	$args = [ 0xffff ]
	insEraseWindow()
end

####################################
#           MAIN PROGRAM           #
####################################

def printUsageAndExit
	puts "Usage: ruby krebf.rb [-d disassembly file] <zcode-file>"
	exit 1
end

printUsageAndExit() if ARGV.length < 1

$storyfile_name = nil
$disassembly_filename = nil
args = ARGV.dup
while args.length > 0 do
	if args[0] == '-d'
		printUsageAndExit() if args.length < 2
		$disassembly_filename = args[1]
		args = args.drop(2)
	else
		printUsageAndExit() if $storyfile_name
		$storyfile_name = args[0]
		args = args.drop(1)
	end
end

$z = IO.binread($storyfile_name)

$dynmem_backup = $z[0 .. readWord(0xe) - 1]

len = $z.length
$zcode_version = -1
$zcode_version = $z[0].ord if len > 0

if len < 64 or len > 512 * 1024 or $zcode_version.to_s !~ /^[1234578]$/
	puts "The file #{$storyfile_name} doesn't seem to be a valid Z-code file, " +
			"using Z-code version 1, 2, 3, 4, 5, 7 or 8."
	exit 1
end

$instructions = nil
if $disassembly_filename
	$instructions = {}
	code = false
	File.foreach($disassembly_filename) do |line|
		if line =~ /^(Main )?[Rr]outine/
			code = true
		elsif line =~ /^(Padding|\*\*\*\*|\[End)/
			code = false
		elsif code
			if line =~ /locals?$/ or line =~ /L0[0-9A-F]=0x[0-9A-F]{4} *$/
				nil
			elsif line =~ /^([0-9a-f]{5}| [0-9a-f]{4}|  [0-9a-f]{3}):/
				$instructions[$1.strip] = 1
			elsif line =~ /^([0-9A-F]{5}) /
				$instructions[$1.strip.lstrip('0').downcase] = 1
			end
		end	
	end
#	puts $instructions.keys.sort.first(20)
#	puts $instructions.keys.sort.last(20)
#	exit 1
end


#$tty_reader = TTY::Reader.new

$streams = StreamsClass.new( #:screenObject => $screen
)

initializeGame()

$transcriptBit = 0

$trace = false

####################################
#        Main game loop            #
####################################

$addresses = []

while $quit == false do
	address = $pc
	if $instructions
		unless $instructions.has_key? $pc.to_s(16)
			fatalErr "PC=$#{address.to_s(16)}: No instruction at this address!"
		end
	end
	
	# DEBUG ONLY
	$addresses += [address]
	$addresses = $addresses[1,100] if $addresses.length > 100
	
	$instruction = readInstruction()
	$args = $instruction['operand_values']
	funcs = $opcode_routines[$instruction['opcode_type']]
	if funcs.length < $instruction['opcode_number'] + 1 or 
			funcs[$instruction['opcode_number']] == nil
		fatalErr "PC=$#{address.to_s(16)}: Instruction type " +
			"#{$instruction['opcode_type']}, " + 
			"##{$instruction['opcode_number']} not implemented!"
	end
	func = funcs[$instruction['opcode_number']]

	if address == 0x2e8d000
		puts $stack.stackForSave.to_s
		puts "PC=$#{address.to_s(16)}, Ins = #{$instruction}" #if $trace
		fatalErr "BREAK!"
	end

	func.call()
	
	newtrans = readWord(0x10) & 1
	if newtrans != $transcriptBit
		$transcriptBit = newtrans
		if $transcriptBit == 1
			$streams.activateOutput(2)
		else
			$streams.inactivateOutput(2)
		end
	end
end

puts "-- End of session --"

#puts $debug.to_s
