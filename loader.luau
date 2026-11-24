--[[
	Sentinel loader.

	Paste the raw URL of Sentinel.luau in place of RAW_URL, then execute this file.
	It only needs to exist so the long script can be hosted and updated server-side
	while the executor command stays one line.
]]

local RAW_URL = "https://raw.githubusercontent.com/urosevicemanuel54-maker/Blade-Ball-Script/main/Sentinel.luau"

assert(type(RAW_URL) == "string" and RAW_URL:find("^https://"), "loader: set RAW_URL first")

local ok, result = pcall(function()
	return loadstring(game:HttpGet(RAW_URL))()
end)

if not ok then
	warn("[Sentinel] load failed: " .. tostring(result))
end
