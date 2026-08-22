--[[
	Anime Origin rarity probe (read-only)

	Select any unit in the inventory before running. The probe records visible
	rarity text from the selected-unit panel and searches loaded runtime tables
	for definitions matching the owned unit names. It never clicks UI or fires a remote.

	Results are saved as AnimeOrigin_RarityProbe.json in the executor workspace.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local mainUI = player:WaitForChild("PlayerGui"):WaitForChild("MainUI")
local rarityWords = {
	common = true,
	uncommon = true,
	rare = true,
	epic = true,
	legendary = true,
	mythic = true,
	secret = true,
	exclusive = true,
}

local function safePath(instance)
	local ok, value = pcall(function() return instance:GetFullName() end)
	return ok and value or tostring(instance)
end

local function simple(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then return value end
	if kind ~= "table" then return "<" .. kind .. ">" end
	if visited[value] then return "<circular>" end
	if depth >= 5 then return "<max-depth>" end
	visited[value] = true
	local output, count = {}, 0
	for key, child in next, value do
		count += 1
		if count > 150 then output._truncated = true; break end
		output[tostring(key)] = simple(child, depth + 1, visited)
	end
	visited[value] = nil
	return output
end

local Report = {
	selectedUI = {},
	runtimeMatches = {},
}

-- Record exact paths of currently rendered rarity words. Requiring visible text
-- avoids unrelated templates while retaining the selected Legendary/Mythic label.
for _, instance in ipairs(mainUI:GetDescendants()) do
	if instance:IsA("TextLabel") or instance:IsA("TextButton") then
		local text = tostring(instance.Text or "")
		local normalized = string.lower(text:gsub("<.->", ""):match("^%s*(.-)%s*$") or "")
		if rarityWords[normalized] then
			local visible = instance.Visible
			local ancestor = instance.Parent
			while visible and ancestor and ancestor ~= mainUI do
				if ancestor:IsA("GuiObject") and not ancestor.Visible then visible = false end
				ancestor = ancestor.Parent
			end
			table.insert(Report.selectedUI, {
				value = text,
				path = safePath(instance) .. ".Text",
				visible = visible,
			})
		end
	end
end

-- Search tables safely with rawget. Runtime definitions may be nested deeper
-- than the earlier four-level scan, so each root gets an independent traversal.
local function scanRoot(root, source)
	local visited = {}
	local function visit(value, path, depth)
		if typeof(value) ~= "table" or visited[value] or depth > 10 then return end
		visited[value] = true

		local rarity = rawget(value, "Rarity") or rawget(value, "rarity")
		local name = rawget(value, "Name") or rawget(value, "TowerName")
			or rawget(value, "UnitName") or rawget(value, "DisplayName")
		if typeof(rarity) == "string" and rarityWords[string.lower(rarity)] then
			table.insert(Report.runtimeMatches, {
				name = typeof(name) == "string" and name or nil,
				rarity = rarity,
				path = source .. path,
				record = simple(value),
			})
		end

		local count = 0
		for key, child in next, value do
			count += 1
			if count > 1000 then break end
			if typeof(child) == "table" then
				visit(child, path .. "[" .. string.format("%q", tostring(key)) .. "]", depth + 1)
			end
		end
	end
	pcall(visit, root, "", 0)
end

if typeof(getgc) == "function" then
	local ok, objects = pcall(getgc, true)
	if ok and typeof(objects) == "table" then
		for index, object in ipairs(objects) do
			if typeof(object) == "table" then scanRoot(object, "getgc[" .. index .. "]") end
		end
	end
end

getgenv().AnimeOriginRarityProbe = Report
for _, match in ipairs(Report.selectedUI) do
	print("[OriginRarity][UI] " .. HttpService:JSONEncode(match))
end
print("[OriginRarity][SUMMARY] UI=" .. #Report.selectedUI .. " Runtime=" .. #Report.runtimeMatches)

if typeof(writefile) == "function" then
	writefile("AnimeOrigin_RarityProbe.json", HttpService:JSONEncode(Report))
	print("[OriginRarity][FILE] AnimeOrigin_RarityProbe.json")
end

return Report
