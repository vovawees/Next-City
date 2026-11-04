-- JSON of util.TableToJSON / util.JSONToTable for the emulated realms, like GMod:
-- sequences (1..n) become arrays, other tables objects with string keys; reading turns
-- numeric object keys back into numbers unless ignoreConversions. Strings are UTF-8 with
-- the usual escapes; numbers that are whole are written without a fraction.

local Json = {}

local format = string.format
local concat = table.concat
local floor = math.floor
local huge = math.huge

local ESCAPES = { ["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r",
	["\t"] = "\\t" }

local function isSequence(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	for i = 1, n do
		if t[i] == nil then
			return false
		end
	end
	return n > 0
end

local function encodeString(s)
	return "\"" .. s:gsub("[%c\"\\]", function(c)
		return ESCAPES[c] or format("\\u%04x", c:byte())
	end) .. "\""
end

local function encodeNumber(n)
	if n ~= n or n == huge or n == -huge then
		return "null"
	end
	if n == floor(n) and n > -1e15 and n < 1e15 then
		return format("%d", n)
	end
	return format("%.17g", n)
end

local function encode(value, seen, out)
	local kind = type(value)
	if kind == "table" then
		if seen[value] then
			error("util.TableToJSON: a table refers to itself", 0)
		end
		seen[value] = true
		if isSequence(value) then
			out[#out + 1] = "["
			for i = 1, #value do
				if i > 1 then
					out[#out + 1] = ","
				end
				encode(value[i], seen, out)
			end
			out[#out + 1] = "]"
		else
			local keys = {}
			for key in pairs(value) do
				local keyKind = type(key)
				if keyKind == "string" or keyKind == "number" then
					keys[#keys + 1] = key
				end
			end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			out[#out + 1] = "{"
			for i, key in ipairs(keys) do
				if i > 1 then
					out[#out + 1] = ","
				end
				out[#out + 1] = encodeString(type(key) == "number" and encodeNumber(key) or key)
				out[#out + 1] = ":"
				encode(value[key], seen, out)
			end
			out[#out + 1] = "}"
		end
		seen[value] = nil
	elseif kind == "string" then
		out[#out + 1] = encodeString(value)
	elseif kind == "number" then
		out[#out + 1] = encodeNumber(value)
	elseif kind == "boolean" then
		out[#out + 1] = value and "true" or "false"
	else
		out[#out + 1] = "null"
	end
end

-- util.TableToJSON(t): nil for anything but a table.
function Json.Encode(t)
	if type(t) ~= "table" then
		return nil
	end
	local out = {}
	encode(t, {}, out)
	return concat(out)
end

local Parser = {}
Parser.__index = Parser

function Parser:Fail(message)
	error(format("JSON at %d: %s", self.at, message), 0)
end

function Parser:Skip()
	self.at = self.text:find("[^ \t\r\n]", self.at) or #self.text + 1
end

function Parser:Peek()
	self:Skip()
	return self.text:sub(self.at, self.at)
end

function Parser:Expect(c)
	if self:Peek() ~= c then
		self:Fail("expected " .. c)
	end
	self.at = self.at + 1
end

local function utf8(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 + floor(code / 64), 0x80 + code % 64)
	end
	return string.char(0xE0 + floor(code / 4096), 0x80 + floor(code / 64) % 64, 0x80 + code % 64)
end

local UNESCAPE = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ["\""] = "\"", ["\\"] = "\\", ["/"] = "/" }

function Parser:String()
	self:Expect("\"")
	local parts = {}
	local text = self.text
	while true do
		local stop = text:find("[\"\\]", self.at)
		if stop == nil then
			self:Fail("unterminated string")
		end
		parts[#parts + 1] = text:sub(self.at, stop - 1)
		local c = text:sub(stop, stop)
		if c == "\"" then
			self.at = stop + 1
			return concat(parts)
		end
		local e = text:sub(stop + 1, stop + 1)
		if e == "u" then
			local hex = text:sub(stop + 2, stop + 5)
			local code = tonumber(hex, 16)
			if code == nil then
				self:Fail("bad escape")
			end
			parts[#parts + 1] = utf8(code)
			self.at = stop + 6
		elseif UNESCAPE[e] then
			parts[#parts + 1] = UNESCAPE[e]
			self.at = stop + 2
		else
			self:Fail("bad escape")
		end
	end
end

function Parser:Value()
	local c = self:Peek()
	local text = self.text
	if c == "{" then
		self.at = self.at + 1
		local out = {}
		if self:Peek() == "}" then
			self.at = self.at + 1
			return out
		end
		while true do
			local key = self:String()
			self:Expect(":")
			local value = self:Value()
			local number = not self.ignoreConversions and tonumber(key) or nil
			out[number ~= nil and number or key] = value
			local sep = self:Peek()
			self.at = self.at + 1
			if sep == "}" then
				return out
			elseif sep ~= "," then
				self:Fail("expected , or }")
			end
		end
	elseif c == "[" then
		self.at = self.at + 1
		local out = {}
		if self:Peek() == "]" then
			self.at = self.at + 1
			return out
		end
		while true do
			out[#out + 1] = self:Value()
			local sep = self:Peek()
			self.at = self.at + 1
			if sep == "]" then
				return out
			elseif sep ~= "," then
				self:Fail("expected , or ]")
			end
		end
	elseif c == "\"" then
		return self:String()
	elseif text:sub(self.at, self.at + 3) == "true" then
		self.at = self.at + 4
		return true
	elseif text:sub(self.at, self.at + 4) == "false" then
		self.at = self.at + 5
		return false
	elseif text:sub(self.at, self.at + 3) == "null" then
		self.at = self.at + 4
		return nil
	end
	local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", self.at)
	if number == nil or number == "" or tonumber(number) == nil then
		self:Fail("unexpected " .. c)
	end
	self.at = self.at + #number
	return tonumber(number)
end

-- util.JSONToTable(text, ignoreLimits, ignoreConversions): nil if it is not valid JSON
-- of a table.
function Json.Decode(text, _, ignoreConversions)
	if type(text) ~= "string" then
		return nil
	end
	local parser = setmetatable({ text = text, at = 1, ignoreConversions = ignoreConversions == true }, Parser)
	local ok, value = pcall(parser.Value, parser)
	if not ok or type(value) ~= "table" then
		return nil
	end
	parser:Skip()
	if parser.at <= #text then
		return nil
	end
	return value
end

return Json
