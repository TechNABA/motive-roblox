--[[
Test of the plugin core in Roblox Studio (edit mode).

1. python tools/build_plugin.py                          -> build/MotiveAnimazioni_modulo.rbxmx
   python tools/build_test_package.py <261106_GorillaWave_T_001.fbx>   -> build/MotiveTestData.rbxmx
2. Drag both files into Studio and move the ModuleScripts "MotiveAnimazioni" and "MotiveTestData" into ServerStorage.
3. Paste this file into the Command Bar (or run it through the Studio MCP execute_luau) and run it.
It opens the same package in four zip variants (stored, deflated, macOS style) and as a loose .json, adapts the
take to a classic R15 and to an R15 Plus avatar created on the fly, compares the arm directions with the values
measured on the Motive skeleton, checks multi-avatar selection, duplicates and the student errors, and removes
everything it created. Prints PASS or the failures.
]]

local ServerStorage = game:GetService("ServerStorage")
local Selection = game:GetService("Selection")
local Motive = require(ServerStorage:WaitForChild("MotiveAnimazioni"))
local DATA = require(ServerStorage:WaitForChild("MotiveTestData"))
local TAKE = "261106_GorillaWave_T_001"

local failures = {}
local function check(cond: boolean, what: string)
	if not cond then table.insert(failures, what) end
end
local function studentError(f, ...)
	local ok, err = pcall(f, ...)
	return (not ok) and type(err) == "table" and err.student or nil
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function fromBase64(s: string): string
	local map = {}
	for i = 1, 64 do map[B64:byte(i)] = i - 1 end
	local out, acc, nbits = {}, 0, 0
	for i = 1, #s do
		local v = map[s:byte(i)]
		if v then
			acc = bit32.bor(bit32.lshift(bit32.band(acc, 0xFFFF), 6), v)
			nbits += 6
			if nbits >= 8 then
				nbits -= 8
				table.insert(out, string.char(bit32.band(bit32.rshift(acc, nbits), 255)))
			end
		end
	end
	return table.concat(out)
end

local hadSaves = ServerStorage:FindFirstChild("RBX_ANIMSAVES") ~= nil
local oldSelection = Selection:Get()
local created = {}

local function jointPos(rig, name)
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 and d.Part1.Name == name then return (d.Part0.CFrame * d.C0).Position end
		if d:IsA("AnimationConstraint") and d.Attachment1 and d.Attachment1.Parent.Name == name then
			return d.Attachment0.WorldPosition
		end
	end
end

local ok, err = pcall(function()
	-- the same package in every zip variant gives the same take
	local reference
	for _, variant in { "stored", "deflate9", "deflate0", "mac" } do
		local okRead, takes = pcall(Motive.readTakes, { { name = "pacchetto.zip", contents = fromBase64(DATA[variant]) } })
		if not okRead then
			check(false, variant .. ": " .. tostring(type(takes) == "table" and takes.student or takes))
			continue
		end
		check(#takes == 1 and takes[1].name == TAKE, variant .. ": wrong takes")
		local data = takes[1].data
		if not reference then
			reference = data
		else
			check(#data.rot == #reference.rot and data.rot[1234] == reference.rot[1234]
				and data.root[#data.root] == reference.root[#reference.root], variant .. ": data differs from the stored zip")
		end
	end
	local gw = reference

	-- loose .json takes (a Mac may unpack the zip by itself)
	local files = Motive.readZip(fromBase64(DATA.stored))
	local loose = Motive.readTakes({ { name = TAKE .. ".json", contents = files[TAKE .. ".json"] } })
	check(#loose == 1 and loose[1].name == TAKE, "loose .json not read")

	-- files that are not packages
	check(studentError(Motive.readTakes, { { name = "x.zip", contents = "not a zip at all" } }) ~= nil, "garbage zip not refused")
	local broken = fromBase64(DATA.deflate9)
	broken = broken:sub(1, 200) .. string.rep("\255", 300) .. broken:sub(501)
	check(studentError(Motive.readTakes, { { name = "x.zip", contents = broken } }) ~= nil, "damaged zip not refused")
	check(studentError(Motive.readTakes, { { name = "x.json", contents = "{}" } }) ~= nil, "empty json not refused")

	local plus = game:GetService("Players"):CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	local classic = game:GetObjects("rbxasset://avatar/characterR15.rbxm")[1]
	for i, rig in { plus, classic } do
		table.insert(created, rig) -- first, so the cleanup removes it whatever fails next
		rig.Name = "MotiveTest" .. i
		rig:PivotTo(CFrame.new(500 + 20 * i, 5, 0))
		rig.Parent = workspace
		rig.HumanoidRootPart.Anchored = true
		if not rig.Humanoid:FindFirstChildOfClass("Animator") then Instance.new("Animator", rig.Humanoid) end
	end

	-- multi-avatar selection
	Selection:Set({ created[1].Head, created[2] })
	local picked = Motive.pickRigs()
	check(#picked == 2 and table.find(picked, created[1]) ~= nil and table.find(picked, created[2]) ~= nil,
		"selection of two avatars")

	-- expected at t = 3 s, measured on the Motive skeleton (Roblox axes)
	local expectUA, expectFA = Vector3.new(-0.81, 0.27, -0.51), Vector3.new(0.59, -0.77, 0.25)
	for _, rig in { created[1], created[2] } do
		for _, d in rig:GetDescendants() do
			if d:IsA("Motor6D") or d:IsA("AnimationConstraint") then d.Transform = CFrame.identity end
		end
		local seg = (jointPos(rig, "LeftHand") - jointPos(rig, "LeftLowerArm")).Unit
		local ua = rig.LeftUpperArm.CFrame:VectorToObjectSpace(seg)
		local fa = rig.LeftLowerArm.CFrame:VectorToObjectSpace(seg)
		check(Motive.findSaved(rig, gw.name) == nil, rig.Name .. ": take found before saving")
		local ks = Motive.saveTake(rig, Motive.buildTake(rig, gw), gw.name, gw.id)
		check(ks.Parent == rig.AnimSaves.Value, rig.Name .. ": take not saved under AnimSaves")
		check(Motive.findSaved(rig, gw.name) == ks, rig.Name .. ": saved take not found (duplicate check would fail)")
		local anim = Instance.new("Animation")
		anim.AnimationId = game:GetService("KeyframeSequenceProvider"):RegisterKeyframeSequence(ks)
		local animator = rig.Humanoid:FindFirstChildOfClass("Animator")
		local track = animator:LoadAnimation(anim)
		local t0 = os.clock()
		while track.Length == 0 and os.clock() - t0 < 5 do task.wait(0.1) end
		track:Play(0)
		track:AdjustSpeed(0)
		track.TimePosition = 3
		animator:StepAnimations(0)
		local gotUA = rig.LeftUpperArm.CFrame:VectorToWorldSpace(ua)
		local gotFA = rig.LeftLowerArm.CFrame:VectorToWorldSpace(fa)
		check((gotUA - expectUA).Magnitude < 0.05, rig.Name .. ": upper arm " .. tostring(gotUA))
		check((gotFA - expectFA).Magnitude < 0.05, rig.Name .. ": forearm " .. tostring(gotFA))
		track:Stop(0)
	end

	-- versions: the same take again is "same"; a corrected take with the same name becomes "<name> (v2)"
	local rig1 = created[1]
	local action, name = Motive.planSave(rig1, { name = gw.name, data = gw })
	check(action == "same" and name == gw.name, "same version: " .. tostring(action) .. " " .. tostring(name))
	local fixed = table.clone(gw)
	fixed.id = "0123456789abcdef"
	action, name = Motive.planSave(rig1, { name = gw.name, data = fixed })
	check(action == "add" and name == gw.name .. " (v2)", "new version: " .. tostring(action) .. " " .. tostring(name))
	Motive.saveTake(rig1, Motive.buildTake(rig1, fixed), name, fixed.id)
	action, name = Motive.planSave(rig1, { name = gw.name, data = fixed })
	check(action == "same" and name == gw.name .. " (v2)", "new version clicked again: " .. tostring(action) .. " " .. tostring(name))
	check(Motive.findSaved(rig1, gw.name):GetAttribute("MotiveId") == gw.id, "old version changed")

	-- a duplicated avatar (Ctrl+D) copies AnimSaves pointing at the original's holder: it must get its own
	local copy = created[2]:Clone()
	table.insert(created, copy)
	copy.Name = "MotiveTestCopia"
	copy.Parent = workspace
	check(Motive.findSaved(copy, gw.name) == nil, "duplicated avatar sees the original's take")
	local ksCopy = Motive.saveTake(copy, Motive.buildTake(copy, gw), gw.name)
	check(ksCopy.Parent ~= created[2].AnimSaves.Value and ksCopy.Parent:IsA("ObjectValue") and ksCopy.Parent.Value == copy,
		"duplicated avatar saved into the original's slot")

	-- a joint hanging on a part that is not R15 (custom rig): clear message, no Lua error
	local odd = created[2]:Clone()
	table.insert(created, odd)
	odd.Name = "MotiveTestStrano"
	odd.Parent = workspace
	local extra = Instance.new("Part")
	extra.Name = "Zaino"
	extra.Parent = odd
	for _, d in odd:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 and d.Part1.Name == "LeftUpperArm" then d.Part0 = extra end
	end
	local oddMsg = studentError(Motive.buildTake, odd, gw)
	check(oddMsg ~= nil and oddMsg:find("non standard") ~= nil, "joint on an extra part: " .. tostring(oddMsg))

	-- take files that are not right
	local bad = table.clone(gw)
	bad.fps = 0
	check(studentError(Motive.buildTake, created[1], bad) ~= nil, "fps 0 not rejected")
	local newer = table.clone(gw)
	newer.version = 2
	local newerMsg = studentError(Motive.buildTake, created[1], newer)
	check(newerMsg ~= nil and newerMsg:find("aggiorna il plugin") ~= nil, "newer format message")
	local otherTree = table.clone(gw)
	otherTree.parents = table.clone(gw.parents)
	otherTree.parents[table.find(gw.parts, "Head")] = "LowerTorso"
	check(studentError(Motive.buildTake, created[1], otherTree) ~= nil, "different hierarchy not rejected")
	local orphan = Motive.buildTake(created[1], gw)
	created[1].Parent = nil
	check(studentError(Motive.saveTake, created[1], orphan, "x") ~= nil, "removed avatar not reported")
end)
if not ok then
	table.insert(failures, "error: " .. tostring(type(err) == "table" and err.student or err))
end

Selection:Set(oldSelection)
local saves = ServerStorage:FindFirstChild("RBX_ANIMSAVES")
if saves then
	for _, holder in saves:GetChildren() do -- only the entries of the test avatars
		if holder:IsA("ObjectValue") and table.find(created, holder.Value) then holder:Destroy() end
	end
	if not hadSaves then saves:Destroy() end
end
for _, rig in created do rig:Destroy() end

local result = #failures == 0 and "PASS" or ("FAIL\n" .. table.concat(failures, "\n"))
print("[plugin_test] " .. result)
return result
