--[[=============================================================================
    DirectorLink UniFi Protect - JSON
    Decoder for the Protect API's answers and a small encoder for request bodies.
    JSON null becomes nil in objects (JSON_NULL with keepNull) and JSON_NULL in arrays (so ipairs keeps going).

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })
local gKeepNull = false

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function Utf8(n)
	if n < 0x80 then return string.char(n) end
	if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
	if n < 0x10000 then
		return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
	end
	return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
		0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

local Value -- forward

local function SkipSpace(s, i)
	return string.find(s, "[^ \t\r\n]", i) or (#s + 1)
end

local function String(s, i)
	-- s:sub(i, i) == '"'
	local out, j = {}, i + 1
	while true do
		local k = string.find(s, '["\\]', j)
		if not k then error("unterminated string at " .. i) end
		out[#out + 1] = string.sub(s, j, k - 1)
		if string.sub(s, k, k) == '"' then return table.concat(out), k + 1 end
		local e = string.sub(s, k + 1, k + 1)
		if e == "u" then
			local hex = string.sub(s, k + 2, k + 5)
			local n = tonumber(hex, 16)
			if not n or #hex ~= 4 then error("bad \\u escape at " .. k) end
			j = k + 6
			if n >= 0xD800 and n <= 0xDBFF and string.sub(s, j, j + 1) == "\\u" then
				local lo = tonumber(string.sub(s, j + 2, j + 5), 16)
				if lo and lo >= 0xDC00 and lo <= 0xDFFF then
					n = 0x10000 + (n - 0xD800) * 1024 + (lo - 0xDC00)
					j = j + 6
				end
			end
			out[#out + 1] = Utf8(n)
		elseif ESCAPES[e] then
			out[#out + 1] = ESCAPES[e]
			j = k + 2
		else
			error("bad escape at " .. k)
		end
	end
end

local function Number(s, i)
	local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
	if not num or num == "" or num == "-" then error("bad number at " .. i) end
	local n = tonumber(num)
	if not n then error("bad number at " .. i) end
	return n, i + #num
end

local function Array(s, i, depth)
	local arr, n = {}, 0
	i = SkipSpace(s, i + 1)
	if string.sub(s, i, i) == "]" then return arr, i + 1 end
	while true do
		local v
		v, i = Value(s, i, depth + 1)
		n = n + 1
		if v == nil then v = JSON_NULL end
		arr[n] = v
		i = SkipSpace(s, i)
		local c = string.sub(s, i, i)
		if c == "]" then return arr, i + 1 end
		if c ~= "," then error("expected , or ] at " .. i) end
		i = SkipSpace(s, i + 1)
	end
end

local function Object(s, i, depth)
	local obj = {}
	i = SkipSpace(s, i + 1)
	if string.sub(s, i, i) == "}" then return obj, i + 1 end
	while true do
		if string.sub(s, i, i) ~= '"' then error("expected a key at " .. i) end
		local k
		k, i = String(s, i)
		i = SkipSpace(s, i)
		if string.sub(s, i, i) ~= ":" then error("expected : at " .. i) end
		local v
		v, i = Value(s, SkipSpace(s, i + 1), depth + 1)
		if v == nil and gKeepNull then v = JSON_NULL end
		obj[k] = v
		i = SkipSpace(s, i)
		local c = string.sub(s, i, i)
		if c == "}" then return obj, i + 1 end
		if c ~= "," then error("expected , or } at " .. i) end
		i = SkipSpace(s, i + 1)
	end
end

Value = function(s, i, depth)
	if depth > 64 then error("nested too deeply") end
	i = SkipSpace(s, i)
	local c = string.sub(s, i, i)
	if c == "{" then return Object(s, i, depth) end
	if c == "[" then return Array(s, i, depth) end
	if c == '"' then return String(s, i) end
	if string.sub(s, i, i + 3) == "true" then return true, i + 4 end
	if string.sub(s, i, i + 4) == "false" then return false, i + 5 end
	if string.sub(s, i, i + 3) == "null" then return nil, i + 4 end
	return Number(s, i)
end

-- value, or nil and an error message. keepNull: null object fields become JSON_NULL (to list every field)
function JsonDecode(s, keepNull)
	if type(s) ~= "string" then return nil, "no text" end
	gKeepNull = keepNull == true
	local ok, v, i = pcall(Value, s, 1, 0)
	gKeepNull = false
	if not ok then return nil, tostring(v) end
	if SkipSpace(s, i) <= #s then return nil, "text after the value" end
	return v
end

local function EncodeString(s)
	return '"' .. string.gsub(s, '[%c"\\]', function(c)
		local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
		return map[c] or string.format("\\u%04x", string.byte(c))
	end) .. '"'
end

-- Strings, numbers, booleans, arrays (tables with [1]) and objects with string keys
function JsonEncode(v)
	local t = type(v)
	if v == nil or v == JSON_NULL then return "null" end
	if t == "boolean" then return v and "true" or "false" end
	if t == "number" then return (v == math.floor(v) and math.abs(v) < 1e15 and string.format("%.0f", v)) or tostring(v) end
	if t == "string" then return EncodeString(v) end
	if t == "table" then
		if v[1] ~= nil or next(v) == nil then
			local out = {}
			for i = 1, #v do out[i] = JsonEncode(v[i]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		local out = {}
		for _, k in ipairs(keys) do out[#out + 1] = EncodeString(k) .. ":" .. JsonEncode(v[k]) end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return "null"
end
