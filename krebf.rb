require 'io/console'
require 'json'
require 'base64'

$z = nil # Z-machine memory contents
$quit = false 

FORM_VAR = 1
FORM_SHORT = 2
FORM_LONG = 3

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
	end
	def checkScreenSize
		@screen_height, @screen_width = IO.console.winsize
		#puts "Your terminal is #{$screen_width} columns wide and #{$screen_height} rows high."
	end
	def screen_height
		@screen_height
	end
	def screen_width
		@screen_width
	end
	def printBuffered(str, flush = false)
		if str && str.length > 0
			if @buffered
				newlinePos = 1
				while str and newlinePos do
					newlinePos = str.index(/\n/)
					if newlinePos
						if newlinePos > 0
							printBuffered(str.first(newlinePos), true)
						else
							flushBuffer()
							print "\n"
						end
						str = str[newlinePos + 1 ..]
					end
				end
				@buffer += str
				if @buffer.length > @screen_width - 1
					breakPos = @buffer.rindex(/ /, @screen_width - 1)
					if breakPos
						puts @buffer[0 .. breakPos - 1]
						@buffer = @buffer [breakPos + 1 ..]
					else
						puts @buffer[0 .. @screen_width - 2]
						@buffer = @buffer[@screen_width - 1 ..]
					end
				end
			else
				print str
			end
		end
		flushBuffer() if flush
	end
	def flushBuffer
		print @buffer
		@buffer = ""
	end
end

class StackClass
	def initialize
		@stack = [{}]
		@locals = nil
		@pushed = nil
	end
	def stackForSave
		frame = @stack.last
		frame['loc'] = @locals if @locals
		@stack
	end
	def stackForSave=(stack)
		@stack = stack
		frame = @stack.last
		@locals = frame['loc']
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
		frame = @stack.last
		frame['loc'] = @locals if @locals
		if @pushed
			frame['push'] = @pushed
		else 
			frame.delete 'push'
		end
		new_frame = {
			'ret' => $pc,
			'sto' => store,
		}
		$pc = unpackRoutinePaddress(paddress)
		varCount = readByteAtPC()
		@locals = Array.new(size = varCount, default = 0)
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
				@locals[i] = args[i] if i < varCount - 1
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
end

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

def printAtAddress(address)
	word = 0
	alphabet_offset_lock = 0
	alphabet_offset = 0
	abbrev_bank = 0
	escape_step = 0
	escape_code = 0
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
				if escape_step == 0
					escape_code &= 0xff
					if escape_code >= 155 and escape_code <= 223
						char = $default_unicode[escape_code - 154]
					else
						char = escape_code.chr
					end
				end
			elsif abbrev_bank > 0
				alphabet_offset = 0
				abbpointer = $abbrev_table + 2 * (32 * abbrev_bank - 32 + value)
				abbaddress = 2 * readWord(abbpointer)
				printAtAddress(abbaddress)
				abbrev_bank = 0
			elsif alphabet_offset == 2 and value == 6
				 alphabet_offset = 0
				 escape_step = 2
				 escape_code = 0
			elsif alphabet_offset == 2 and value == 7 and $zcode_version > 1
				char = 10.chr
			elsif value > 5
				char = $alphabet[26 * alphabet_offset + value - 6]
				if char.ord >= 155 and char.ord <= 223
					char = $default_unicode[char.ord - 154]
				end
			elsif value == 0
				char = ' '
			elsif value == 1
				if $zcode_version == 1 then
					char = 10.chr
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
				$screen.printBuffered char.to_s
				alphabet_offset = alphabet_offset_lock
			end
		end
		
	end

	return address
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
	$screen.printBuffered "\n";
	$stack.return 1
end

def insNop
	nil
end

def insSave
	success = false
	$screen.printBuffered("Please enter a filename: ", true)
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
	if $zcode_version < 4
		condBranch(success)
	else ## if $zcode_version == 4
		setVar(readByteAtPC(), success ? 1 : 0)
	end
end

def forkInsSaveOrIllegal
	if $zcode_version < 5
		insSave()
	else
		illegalInstruction();
	end
end

def insRestore
	success = false
	$screen.printBuffered("Please enter a filename: ", true)
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
		end
	end

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
	puts "[Restart not implemented]"
end

def insRetPopped
	$stack.return $stack.pop
end

def insPop
	$stack.pop()
end

def forkInsPopOrCatch
	if $zcode_version < 5
		insPop()
	else
		fatalErr "PC=$#{$pc.to_s(16)}: forkInsPopOrCatch: Catch not implemented!"
	end
end

def insQuit
	puts "<Hit any key to exit>";
	STDIN.gets
	exit 0
end

def insNewLine
	$screen.printBuffered "\n";
end

def insShowStatus
	# NOP for now in all versions. Should always be a NOP in v4+
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
				value &= 0x0b00111111
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


def insPrintObj
	address = objectAddress($args[0]) + 
		($zcode_version < 4 ? 7 : 12)
	props = readWord(address)
	if readByte(props) > 0
		printAtAddress(props + 1)
	end
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
			hash = {
				'zscii' => char.ord
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
	input = STDIN.gets.chomp[0 .. maxchars - 1].downcase

	### Write input into memory, and split it into words

	words = []
	word_start = nil
	buffer_pointer = buffer + 1
	string_pointer = 0
	last_char = nil

	input.each_char do |char|
		writeByte(buffer_pointer, char.ord)
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

end

def insPrintChar
	$screen.printBuffered $args[0].chr
end

def insPrintNum
	$screen.printBuffered "#{toSigned($args[0])}"
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
		method(:insShowStatus), #show_status v3
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
		nil, # set_colour v5+
		nil, # throw v5+
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
		nil, #split_window v3+
		nil, #set_window v3+
		nil, #call_vs2 v4+
		nil, #erase_window v4+
		nil, #erase_line v4+
		nil, #set_cursor v4+
		nil, #get_cursor v4+
		nil, #set_text_style v4+
		nil, #buffer_mode v4+
		nil, #output_stream v3+
		nil, #input_stream v3+
		nil, #sound_effect v3+
		nil, #read_char v4+
		nil, #scan_table v4+
		nil, #not v5+
		method(:insCallN), #call_vn v5+
		nil, #call_vn2 v5+
		nil, #tokenise v5+
		nil, #encode v5+
		nil, #copy_table v5+
		nil, #print_table v5+
		nil, #check_arg_count v5+
	],
	OPCODE_TYPE_EXT => [
		nil, #save v5+
		nil, #restore v5+
		nil, #log_shift v5+
		nil, #art_shift v5+
		nil, #set_font v5+
		nil,
		nil,
		nil,
		nil,
		nil, #save_undo v5+
		nil, #restore_undo v5+
		nil, #print_unicode v5+
		nil, #check_unicode v5+
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
	topbits = (opcode & 0b11000000) >> 6
	form =
		case
			when topbits == 0b11 then FORM_VAR
			when topbits == 0b10 then FORM_SHORT
			else FORM_LONG
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
		flags1 &= (255 - 64 - 32) # Variable pitch font is not default, no screen split 
		flags1 |= 16 # No statusline
	end
	writeByte(1, flags1)

	writeByte(0x32, 0) # Standard revision, major version
	writeByte(0x33, 0) # Standard revision, minor version
	
	if $zcode_version > 3
		writeByte(0x1e, 2) # Interpreter = Apple IIe
		writeByte(0x1f, 1) # Interpreter version = 1
		writeByte(0x20, $screen.screen_height) # Screen height in characters
		writeByte(0x21, $screen.screen_width) # Screen width in characters
		if $zcode_version > 4
			writeWord(0x22, $screen.screen_width) # Screen width in units
			writeWord(0x24, $screen.screen_height)  # Screen height in units
			writeByte(0x26, 1) # Font width in units
			writeByte(0x27, 1) # Font height in units
			writeByte(0x2c, 9) # Default background colour (white)
			writeByte(0x2d, 2) # Default foreground colour (black)
		end
	end

end

def initializeGame

	rndSeedRandom()
#	rndSeed(0xff, 0x80, 0x01) # For benchmark mode

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
end

####################################
#           MAIN PROGRAM           #
####################################

if ARGV.length < 1
	puts "Usage: ruby krebf.rb <zcode-file>"
	exit 1
end

$storyfile_name = ARGV[0]

$z = IO.binread($storyfile_name)

len = $z.length
$zcode_version = -1
$zcode_version = $z[0].ord if len > 0

if len < 64 or len > 512 * 1024 or [1,2,3,4,5,8].include?($zcode_version) == false
	puts "The file #{$storyfile_name} doesn't seem to be a valid Z-code file, " +
			"using Z-code version 1,2,3,4,5 or 8."
	exit 1
end

$stack = StackClass.new

$screen = ScreenClass.new


$random = Random.new

initializeGame()

$trace = false

# Main game loop
while $quit == false do
	address = $pc
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

	puts "PC=$#{address.to_s(16)}, Ins = #{$instruction}" if $trace
	func.call()
		
end

puts "Bye"
