-- Next-City core: translations — language catalogs, fallback chains, plural rules and
-- placeholders.
--
-- Pure Lua (LuaJIT 2.x), no GMod API. The platform loads lang/<code>/*.lua files and
-- picks the language of the player; see docs/ARCHITECTURE.md, section 12.
--
--   local catalog = I18n.New({ default = "en" })
--   catalog:AddLanguage("ru", { name = "Русский", plural = "east_slavic", fallback = "en" })
--   catalog:Add("ru", "rounds", {
--       win = "Победила команда {team}",
--       players = { one = "{count} игрок", few = "{count} игрока", many = "{count} игроков" },
--   })
--   local L = catalog:Translator("ru")       -- chain: ru -> en
--   L:T("rounds.win", { team = "красных" })  -- "Победила команда красных"
--   L:T("rounds.players", { count = 3 })     -- "3 игрока"
--
-- Keys are "<namespace>.<key>"; a namespace is a file name (a module id or "common").
-- A value is a string or a table of plural forms (zero, one, two, few, many, other)
-- chosen by params.count with the rule of the language the value came from. A param
-- value { key = "...", params = {...} } is translated too. Missing params stay visible
-- as "{name}"; a missing key returns the key itself and is logged once.
-- Lookups are cached per translator; a string without placeholders costs one table read.

local I18n = {}

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local setmetatable = setmetatable
local next = next
local format = string.format
local gsub = string.gsub
local find = string.find
local sort = table.sort
local floor = math.floor
local abs = math.abs

local NAMESPACE_PATTERN = "^[a-z][a-z0-9_]*$"
local SEGMENT_PATTERN = "^[%w_]+$"
local PLACEHOLDER_PATTERN = "{([%w_]+)}"
local MAX_CODE = 16
local MAX_DEPTH = 4
local META_KEYS = { name = true, english = true, plural = true, fallback = true }
local CATEGORIES = { zero = true, one = true, two = true, few = true, many = true, other = true }
-- Order of forms tried when the selected category is missing.
local FALLBACK_FORMS = { "other", "many", "few", "one", "two", "zero" }

local function noop() end
local NULL_LOG = { Trace = noop, Debug = noop, Info = noop, Warn = noop, Error = noop }

-- Language codes ----------------------------------------------------------------------

-- "pt_BR" -> "pt-br". Returns nil for anything that is not a language code.
function I18n.Normalize(code)
	if type(code) ~= "string" then
		return nil
	end
	code = gsub(code:lower(), "_", "-")
	code = code:match("^%s*(.-)%s*$")
	if #code > MAX_CODE or not find(code, "^[a-z][a-z][a-z]?$") and not find(code, "^[a-z][a-z][a-z]?%-[%w%-]*%w$") then
		return nil
	end
	if find(code, "%-%-") then
		return nil
	end
	return code
end
local normalize = I18n.Normalize

-- "zh-hant-tw" -> { "zh-hant-tw", "zh-hant", "zh" }.
function I18n.Parents(code)
	local out = { code }
	while true do
		local parent = code:match("^(.+)%-[^%-]+$")
		if parent == nil then
			return out
		end
		out[#out + 1] = parent
		code = parent
	end
end
local parents = I18n.Parents

-- Plural rules (CLDR, cardinal) ----------------------------------------------------------

local function isInt(n)
	return n == floor(n)
end

local RULES = {}

-- Adds a plural rule: def = { required = { categories for integers }, select = fn(n) }.
function I18n.AddPluralRule(id, def)
	assert(type(id) == "string" and find(id, NAMESPACE_PATTERN), "I18n.AddPluralRule: id must be snake_case")
	assert(type(def) == "table" and type(def.select) == "function", "I18n.AddPluralRule: def.select is required")
	assert(type(def.required) == "table" and def.required[1] ~= nil, "I18n.AddPluralRule: def.required is required")
	for _, category in ipairs(def.required) do
		assert(CATEGORIES[category], "I18n.AddPluralRule: unknown category " .. tostring(category))
	end
	RULES[id] = { id = id, required = def.required, select = def.select }
end

-- English, German, Spanish, Italian, Swedish, Turkish...
I18n.AddPluralRule("one_other", {
	required = { "one", "other" },
	select = function(n)
		if n == 1 then
			return "one"
		end
		return "other"
	end,
})

-- French, Brazilian Portuguese: 0 and 1 are singular.
I18n.AddPluralRule("zero_one", {
	required = { "one", "other" },
	select = function(n)
		if n < 2 then
			return "one"
		end
		return "other"
	end,
})

-- Russian, Ukrainian, Belarusian: 1, 21 one; 2-4, 22-24 few; 0, 5-20, 25 many.
I18n.AddPluralRule("east_slavic", {
	required = { "one", "few", "many" },
	select = function(n)
		if not isInt(n) then
			return "other"
		end
		local m10, m100 = n % 10, n % 100
		if m10 == 1 and m100 ~= 11 then
			return "one"
		end
		if m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then
			return "few"
		end
		return "many"
	end,
})

-- Polish: 1 one; 2-4, 22-24 few; others many.
I18n.AddPluralRule("polish", {
	required = { "one", "few", "many" },
	select = function(n)
		if not isInt(n) then
			return "other"
		end
		local m10, m100 = n % 10, n % 100
		if n == 1 then
			return "one"
		end
		if m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then
			return "few"
		end
		return "many"
	end,
})

-- Czech, Slovak: 1 one; 2-4 few; fractions many; others other.
I18n.AddPluralRule("czech", {
	required = { "one", "few", "other" },
	select = function(n)
		if not isInt(n) then
			return "many"
		end
		if n == 1 then
			return "one"
		end
		if n >= 2 and n <= 4 then
			return "few"
		end
		return "other"
	end,
})

-- Lithuanian.
I18n.AddPluralRule("lithuanian", {
	required = { "one", "few", "other" },
	select = function(n)
		if not isInt(n) then
			return "many"
		end
		local m10, m100 = n % 10, n % 100
		if m100 >= 11 and m100 <= 19 then
			return "other"
		end
		if m10 == 1 then
			return "one"
		end
		if m10 >= 2 then
			return "few"
		end
		return "other"
	end,
})

-- Latvian.
I18n.AddPluralRule("latvian", {
	required = { "zero", "one", "other" },
	select = function(n)
		local m10, m100 = n % 10, n % 100
		if m10 == 0 or (m100 >= 11 and m100 <= 19) then
			return "zero"
		end
		if m10 == 1 and m100 ~= 11 then
			return "one"
		end
		return "other"
	end,
})

-- Romanian.
I18n.AddPluralRule("romanian", {
	required = { "one", "few", "other" },
	select = function(n)
		if n == 1 then
			return "one"
		end
		local m100 = n % 100
		if not isInt(n) or n == 0 or (m100 >= 2 and m100 <= 19) then
			return "few"
		end
		return "other"
	end,
})

-- Arabic.
I18n.AddPluralRule("arabic", {
	required = { "zero", "one", "two", "few", "many", "other" },
	select = function(n)
		if n == 0 then
			return "zero"
		end
		if n == 1 then
			return "one"
		end
		if n == 2 then
			return "two"
		end
		local m100 = n % 100
		if isInt(n) and m100 >= 3 and m100 <= 10 then
			return "few"
		end
		if isInt(n) and m100 >= 11 then
			return "many"
		end
		return "other"
	end,
})

-- Hebrew.
I18n.AddPluralRule("hebrew", {
	required = { "one", "two", "other" },
	select = function(n)
		if n == 1 then
			return "one"
		end
		if n == 2 then
			return "two"
		end
		return "other"
	end,
})

-- Chinese, Japanese, Korean, Thai, Vietnamese: one form.
I18n.AddPluralRule("none", {
	required = { "other" },
	select = function()
		return "other"
	end,
})

-- Category of `n` under a rule ("east_slavic", 22 -> "few").
function I18n.Plural(rule, n)
	local def = RULES[rule]
	assert(def ~= nil, "I18n.Plural: unknown rule " .. tostring(rule))
	return def.select(abs(n))
end

function I18n.PluralRules()
	local out = {}
	for id in pairs(RULES) do
		out[#out + 1] = id
	end
	sort(out)
	return out
end

-- Placeholders -----------------------------------------------------------------------

local function placeholders(value, out)
	out = out or {}
	if type(value) == "string" then
		for name in value:gmatch(PLACEHOLDER_PATTERN) do
			out[name] = true
		end
	else
		for _, form in pairs(value) do
			placeholders(form, out)
		end
	end
	return out
end

-- gsub with a function: one shared function and saved state instead of a closure per call.
local active, activeTranslator, depth = nil, nil, 0

local function replace(name)
	local value = active[name]
	local kind = type(value)
	if kind == "string" or kind == "number" then
		return value
	end
	if value == nil then
		return nil
	end
	if kind == "table" and type(value.key) == "string" then
		if depth >= MAX_DEPTH then
			return value.key
		end
		local savedParams, savedTranslator = active, activeTranslator
		depth = depth + 1
		local text = activeTranslator:T(value.key, value.params)
		depth = depth - 1
		active, activeTranslator = savedParams, savedTranslator
		return text
	end
	return tostring(value)
end

local function render(translator, text, params)
	local savedParams, savedTranslator = active, activeTranslator
	active, activeTranslator = params, translator
	local out = gsub(text, PLACEHOLDER_PATTERN, replace)
	active, activeTranslator = savedParams, savedTranslator
	return out
end

-- Validation ---------------------------------------------------------------------------

local function validKey(key)
	if type(key) ~= "string" or key == "" then
		return false
	end
	for segment in (key .. "."):gmatch("([^.]*)%.") do
		if not find(segment, SEGMENT_PATTERN) then
			return false
		end
	end
	return true
end

local function validateValue(value)
	if type(value) == "string" then
		return true
	end
	if type(value) ~= "table" then
		return false, "must be a string or a table of plural forms, got " .. type(value)
	end
	local count = 0
	for category, form in pairs(value) do
		if not CATEGORIES[category] then
			return false, format("unknown plural form %s (zero, one, two, few, many, other)", tostring(category))
		end
		if type(form) ~= "string" then
			return false, format("plural form '%s' must be a string", category)
		end
		count = count + 1
	end
	if count == 0 then
		return false, "plural table has no forms"
	end
	return true
end

-- Catalog ------------------------------------------------------------------------------

local Catalog = {}
Catalog.__index = Catalog

local Translator = {}
Translator.__index = Translator

-- opts: default (language used when nothing else matches, "en"), log.
function I18n.New(opts)
	opts = opts or {}
	local default = normalize(opts.default or "en")
	assert(default ~= nil, "I18n.New: default must be a language code")
	return setmetatable({
		default = default,
		log = opts.log or NULL_LOG,
		languages = {},
		strings = {},
		translators = {},
		reported = {},
		version = 0,
	}, Catalog)
end

-- Registers a language. meta: name (native name), english, plural (rule id, default
-- "one_other"), fallback (code). Returns true, or false and a message.
function Catalog:AddLanguage(code, meta)
	local normalized = normalize(code)
	if normalized == nil or normalized ~= code then
		return false, format("language code %s must be normalized (lowercase, '-')", tostring(code))
	end
	meta = meta or {}
	if type(meta) ~= "table" then
		return false, format("language '%s': meta must be a table", code)
	end
	for key in pairs(meta) do
		if not META_KEYS[key] then
			return false, format("language '%s': unknown meta key '%s'", code, tostring(key))
		end
	end
	for _, key in ipairs({ "name", "english" }) do
		if meta[key] ~= nil and type(meta[key]) ~= "string" then
			return false, format("language '%s': %s must be a string", code, key)
		end
	end
	local plural = meta.plural or "one_other"
	if RULES[plural] == nil then
		return false, format("language '%s': unknown plural rule '%s'", code, tostring(plural))
	end
	local fallback = nil
	if meta.fallback ~= nil then
		fallback = normalize(meta.fallback)
		if fallback == nil or fallback == code then
			return false, format("language '%s': bad fallback %s", code, tostring(meta.fallback))
		end
	end
	self.languages[code] = {
		code = code,
		name = meta.name or code,
		english = meta.english or meta.name or code,
		plural = plural,
		rule = RULES[plural],
		fallback = fallback,
	}
	self.strings[code] = self.strings[code] or {}
	self.version = self.version + 1
	return true
end

function Catalog:HasLanguage(code)
	return self.languages[code] ~= nil
end

-- Adds the strings of one namespace: keys become "<namespace>.<key>". Validates
-- everything first, so a bad file adds nothing. Returns true, or false and a message.
function Catalog:Add(code, namespace, strings)
	if self.languages[code] == nil then
		return false, format("unknown language '%s' (AddLanguage first)", tostring(code))
	end
	if type(namespace) ~= "string" or not find(namespace, NAMESPACE_PATTERN) then
		return false, format("namespace must be a snake_case id, got %s", tostring(namespace))
	end
	if type(strings) ~= "table" then
		return false, format("%s/%s: strings must be a table", code, namespace)
	end
	for key, value in pairs(strings) do
		if not validKey(key) then
			return false, format("%s/%s: bad key %s (segments of letters, digits, _ joined by dots)",
				code, namespace, tostring(key))
		end
		local ok, err = validateValue(value)
		if not ok then
			return false, format("%s/%s: %s %s", code, namespace, key, err)
		end
	end
	local target = self.strings[code]
	for key, value in pairs(strings) do
		target[namespace .. "." .. key] = value
	end
	self.version = self.version + 1
	return true
end

-- Languages ordered by code: { code, name, english, plural, fallback, keys }.
function Catalog:Languages()
	local out = {}
	for code, lang in pairs(self.languages) do
		local keys = 0
		for _ in pairs(self.strings[code]) do
			keys = keys + 1
		end
		out[#out + 1] = {
			code = code, name = lang.name, english = lang.english, plural = lang.plural,
			fallback = lang.fallback, keys = keys,
		}
	end
	sort(out, function(a, b) return a.code < b.code end)
	return out
end

local function addChain(self, code, chain, seen, level)
	if code == nil or level > MAX_DEPTH * 2 then
		return
	end
	for _, candidate in ipairs(parents(code)) do
		if not seen[candidate] then
			seen[candidate] = true
			local lang = self.languages[candidate]
			if lang ~= nil then
				chain[#chain + 1] = candidate
				addChain(self, lang.fallback, chain, seen, level + 1)
			end
		end
	end
end

-- Registered languages tried for `code`, best first: the code, its parents ("pt-br" ->
-- "pt"), their fallbacks, then the default language.
function Catalog:Chain(code)
	local chain, seen = {}, {}
	addChain(self, normalize(code), chain, seen, 0)
	addChain(self, self.default, chain, seen, 0)
	return chain
end

-- The language a player asking for `code` actually gets (nil if no languages are loaded).
function Catalog:Resolve(code)
	return self:Chain(code)[1]
end

-- Keys of a language, sorted.
function Catalog:Keys(code)
	local out = {}
	for key in pairs(self.strings[code] or {}) do
		out[#out + 1] = key
	end
	sort(out)
	return out
end

-- Returns the translator for `code` (cached).
function Catalog:Translator(code)
	code = normalize(code) or self.default
	local translator = self.translators[code]
	if translator == nil then
		translator = setmetatable({ catalog = self, requested = code, version = -1 }, Translator)
		self.translators[code] = translator
	end
	return translator
end

function Catalog:_ReportMissing(key, code)
	local id = code .. "\0" .. key
	if self.reported[id] then
		return
	end
	self.reported[id] = true
	self.log:Warn("missing translation '%s' (language '%s')", key, code)
end

-- Problems of every language compared to `reference` (default: the default language),
-- sorted by language and key: { code, key, kind, message }. Kinds: missing (key absent,
-- the fallback is used), extra (key unknown to the reference), placeholder, plural.
function Catalog:Check(reference)
	reference = reference or self.default
	local problems = {}
	local function add(code, key, kind, message)
		problems[#problems + 1] = { code = code, key = key, kind = kind, message = message }
	end
	local refStrings = self.strings[reference]
	if refStrings == nil then
		add(reference, "", "missing", "reference language is not loaded")
		return problems
	end
	for code, strings in pairs(self.strings) do
		local rule = self.languages[code].rule
		for key, value in pairs(strings) do
			local refValue = refStrings[key]
			if refValue == nil then
				add(code, key, "extra", "key is not in the reference language")
			elseif (type(value) == "table") ~= (type(refValue) == "table") then
				add(code, key, "plural", type(refValue) == "table" and "must have plural forms" or "must be a plain string")
			else
				local mine, theirs = placeholders(value), placeholders(refValue)
				for name in pairs(theirs) do
					if not mine[name] then
						add(code, key, "placeholder", "missing {" .. name .. "}")
					end
				end
				for name in pairs(mine) do
					if not theirs[name] then
						add(code, key, "placeholder", "unknown {" .. name .. "}")
					end
				end
			end
			if type(value) == "table" then
				for _, category in ipairs(rule.required) do
					if value[category] == nil then
						add(code, key, "plural", format("missing form '%s' (rule %s)", category, rule.id))
					end
				end
			end
		end
		if code ~= reference then
			for key in pairs(refStrings) do
				if strings[key] == nil then
					add(code, key, "missing", "not translated")
				end
			end
		end
	end
	sort(problems, function(a, b)
		if a.code ~= b.code then
			return a.code < b.code
		end
		if a.key ~= b.key then
			return a.key < b.key
		end
		return a.message < b.message
	end)
	return problems
end

-- Translator ---------------------------------------------------------------------------

function Translator:_Refresh()
	local catalog = self.catalog
	self.chain = catalog:Chain(self.requested)
	self.code = self.chain[1] or catalog.default
	self.cache = {}
	self.version = catalog.version
end

-- Finds a key along the chain and caches its entry: a plain string, or a table
-- { text | forms, select, fallback, placeholders, missing }. Returns nil if no language
-- of the chain has the key.
function Translator:_Lookup(key)
	local catalog = self.catalog
	for _, code in ipairs(self.chain) do
		local value = catalog.strings[code][key]
		if value ~= nil then
			local entry
			if type(value) == "string" then
				if find(value, "{", 1, true) then
					entry = { text = value, placeholders = true }
				else
					entry = value
				end
			else
				local fallback
				for _, category in ipairs(FALLBACK_FORMS) do
					if value[category] ~= nil then
						fallback = value[category]
						break
					end
				end
				entry = {
					forms = value,
					select = catalog.languages[code].rule.select,
					fallback = fallback,
					placeholders = next(placeholders(value)) ~= nil,
				}
			end
			self.cache[key] = entry
			return entry
		end
	end
	return nil
end

-- Translates `key`. params: values for {placeholders}; params.count selects plural forms.
function Translator:T(key, params)
	if self.version ~= self.catalog.version then
		self:_Refresh()
	end
	local entry = self.cache[key]
	if entry == nil then
		entry = self:_Lookup(key)
		if entry == nil then
			self.catalog:_ReportMissing(key, self.code)
			entry = { text = key, missing = true }
			self.cache[key] = entry
		end
	end
	if type(entry) == "string" then
		return entry
	end
	local text = entry.text
	local forms = entry.forms
	if forms ~= nil then
		local n = params and params.count
		local category = type(n) == "number" and n == n and entry.select(abs(n)) or "other"
		text = forms[category] or entry.fallback
	end
	if params == nil or not entry.placeholders then
		return text
	end
	return render(self, text, params)
end

-- True if some language of the chain has the key.
function Translator:Has(key)
	if self.version ~= self.catalog.version then
		self:_Refresh()
	end
	local entry = self.cache[key] or self:_Lookup(key)
	return entry ~= nil and (type(entry) == "string" or not entry.missing)
end

-- The language this translator actually uses first.
function Translator:Code()
	if self.version ~= self.catalog.version then
		self:_Refresh()
	end
	return self.code
end

return I18n
