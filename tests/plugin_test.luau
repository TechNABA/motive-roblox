--[[
Test of the plugin core in Roblox Studio (edit mode).

1. python tools/build_plugin.py   -> build/MotiveAnimazioni_modulo.rbxmx
2. Drag that file into Studio and move the ModuleScript "MotiveAnimazioni" into ServerStorage.
3. Paste this file into the Command Bar (or run it through the Studio MCP execute_luau) and run it.
It downloads takes from GitHub, adapts them to a classic R15 and to an R15 Plus avatar created on the fly,
compares the arm directions with the values measured on the Motive skeleton, checks the student errors, and
removes everything it created. Prints PASS or the failures.
]]

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Motive = require(ServerStorage:WaitForChild("MotiveAnimazioni"))
local BASE = "https://raw.githubusercontent.com/TechNABA/motive-roblox/master/animazioni/"

local failures = {}
local function check(cond: boolean, what: string)
	if not cond then table.insert(failures, what) end
end
local function studentError(f, ...)
	local ok, err = pcall(f, ...)
	return (not ok) and type(err) == "table" and err.student or nil
end

local hadSaves = ServerStorage:FindFirstChild("RBX_ANIMSAVES") ~= nil
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
	local index = HttpService:JSONDecode(HttpService:GetAsync(BASE .. "index.json", true))
	check(type(index.takes) == "table" and #index.takes > 0, "index.json has no takes")
	local gw = HttpService:JSONDecode(HttpService:GetAsync(BASE .. "261106_GorillaWave_T_001.json", true))

	local plus = game:GetService("Players"):CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	local classic = game:GetObjects("rbxasset://avatar/characterR15.rbxm")[1]
	for i, rig in { plus, classic } do
		rig.Name = "MotiveTest" .. i
		rig:PivotTo(CFrame.new(500 + 20 * i, 5, 0))
		rig.Parent = workspace
		rig.HumanoidRootPart.Anchored = true
		if not rig.Humanoid:FindFirstChildOfClass("Animator") then Instance.new("Animator", rig.Humanoid) end
		table.insert(created, rig)
	end

	-- expected at t = 3 s, measured on the Motive skeleton (Roblox axes)
	local expectUA, expectFA = Vector3.new(-0.81, 0.27, -0.51), Vector3.new(0.59, -0.77, 0.25)
	for _, rig in created do
		for _, d in rig:GetDescendants() do
			if d:IsA("Motor6D") or d:IsA("AnimationConstraint") then d.Transform = CFrame.identity end
		end
		local seg = (jointPos(rig, "LeftHand") - jointPos(rig, "LeftLowerArm")).Unit
		local ua = rig.LeftUpperArm.CFrame:VectorToObjectSpace(seg)
		local fa = rig.LeftLowerArm.CFrame:VectorToObjectSpace(seg)
		local ks = Motive.saveTake(rig, Motive.buildTake(rig, gw), gw.name)
		check(ks.Parent == rig.AnimSaves.Value, rig.Name .. ": take not saved under AnimSaves")
		local again = Motive.saveTake(rig, Motive.buildTake(rig, gw), gw.name)
		check(again.Name == gw.name .. " (2)", rig.Name .. ": second save overwrote the first")
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

	local bad = table.clone(gw)
	bad.fps = 0
	check(studentError(Motive.buildTake, created[1], bad) ~= nil, "fps 0 not rejected")
	check(studentError(Motive.buildTake, created[1], { format = "x" }) ~= nil, "foreign file not rejected")
	local orphan = Motive.buildTake(created[1], gw)
	created[1].Parent = nil
	check(studentError(Motive.saveTake, created[1], orphan, "x") ~= nil, "removed avatar not reported")
end)
if not ok then
	table.insert(failures, "error: " .. tostring(type(err) == "table" and err.student or err))
end

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
