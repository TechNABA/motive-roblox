--[[
Animazioni Motive - plugin di Roblox Studio (https://github.com/TechNABA/motive-roblox)

Mostra le animazioni registrate in Motive. Un clic su una take la adatta all'avatar nella scena
(R15 classico o R15 Plus, qualsiasi corpo) e la salva dove la trova l'Animation Editor (Rig > AnimSaves):
li' si guarda nella viewport e si modifica nella timeline.

Caricato come ModuleScript (senza `plugin`) restituisce le funzioni, per i test.
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local VERSION = "1.0.0"
local BASE_URL = "https://raw.githubusercontent.com/TechNABA/motive-roblox/master/animazioni/"
local CANON_LEG = 1.748 -- hip->ankle (studs) of the classic R15 the takes are computed on
local DOWN = Vector3.new(0, -1, 0)

local PARTS = { "LowerTorso", "UpperTorso", "Head", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot" }
local CANON_PARENT = { LowerTorso = "HumanoidRootPart", UpperTorso = "LowerTorso", Head = "UpperTorso",
	LeftUpperArm = "UpperTorso", LeftLowerArm = "LeftUpperArm", LeftHand = "LeftLowerArm",
	RightUpperArm = "UpperTorso", RightLowerArm = "RightUpperArm", RightHand = "RightLowerArm",
	LeftUpperLeg = "LowerTorso", LeftLowerLeg = "LeftUpperLeg", LeftFoot = "LeftLowerLeg",
	RightUpperLeg = "LowerTorso", RightLowerLeg = "RightUpperLeg", RightFoot = "RightLowerLeg" }
-- segment whose rest direction drives each limb part: {from joint, to joint}. Arms use elbow->wrist for all three
-- parts: rest arms are straight on every R15, and on classic rigs the shoulder joint sits off the arm axis.
local SEGMENT = { LeftUpperArm = { "LeftLowerArm", "LeftHand" }, LeftLowerArm = { "LeftLowerArm", "LeftHand" },
	LeftHand = { "LeftLowerArm", "LeftHand" }, RightUpperArm = { "RightLowerArm", "RightHand" },
	RightLowerArm = { "RightLowerArm", "RightHand" }, RightHand = { "RightLowerArm", "RightHand" },
	LeftUpperLeg = { "LeftUpperLeg", "LeftLowerLeg" }, LeftLowerLeg = { "LeftLowerLeg", "LeftFoot" },
	RightUpperLeg = { "RightUpperLeg", "RightLowerLeg" }, RightLowerLeg = { "RightLowerLeg", "RightFoot" } }

local function rot(cf: CFrame): CFrame
	return cf - cf.Position
end

local function align(a: Vector3, b: Vector3): CFrame
	a, b = a.Unit, b.Unit
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-6 then
		return CFrame.identity
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(a:Dot(b), -1, 1)))
end

-- Errors meant for the student: shown as they are, without the Lua location.
local function fail(message: string)
	error({ student = message }, 0)
end

-- Joint description of an avatar: for each R15 part, its container (part or bone), C0/C1 and the pose path.
local function describeRig(rig: Model)
	local hrp = rig:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		fail("L'avatar '" .. rig.Name .. "' non ha HumanoidRootPart: crealo da Avatar > Character.")
	end
	local joints = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 and d.Part0 then
			joints[d.Part1.Name] = { container = d.Part0, c0 = d.C0, c1 = d.C1 }
		elseif d:IsA("AnimationConstraint") and d.Attachment0 and d.Attachment1 and d.Attachment1.Parent then
			joints[d.Attachment1.Parent.Name] = { container = d.Attachment0.Parent, c0 = d.Attachment0.CFrame, c1 = d.Attachment1.CFrame }
		end
	end
	for _, p in PARTS do
		if not (joints[p] and rig:FindFirstChild(p)) then
			fail("L'avatar '" .. rig.Name .. "' non e' R15 (manca " .. p .. "). Crealo da Avatar > Character scegliendo R15.")
		end
	end
	local function owner(inst: Instance): Instance
		while inst and not inst:IsA("BasePart") do
			inst = inst.Parent
		end
		return inst
	end
	-- rest CFrames relative to HumanoidRootPart, computed from the joints (independent of the current pose)
	local rest, visiting = {}, {}
	local function restCF(inst: Instance): CFrame
		if rest[inst] then return rest[inst] end
		if visiting[inst] or not inst or not inst:IsDescendantOf(rig) then
			fail("Le articolazioni dell'avatar '" .. rig.Name .. "' non sono collegate correttamente.")
		end
		visiting[inst] = true
		local cf
		if inst == hrp then
			cf = CFrame.identity
		elseif inst:IsA("Bone") then
			cf = restCF(inst.Parent) * inst.CFrame
		else
			local j = joints[inst.Name]
			if not j then
				fail("Le articolazioni dell'avatar '" .. rig.Name .. "' non sono collegate correttamente.")
			end
			cf = restCF(j.container) * j.c0 * j.c1:Inverse()
		end
		rest[inst] = cf
		return cf
	end
	local jointPos, path = {}, {}
	for _, p in PARTS do
		local j = joints[p]
		jointPos[p] = (restCF(j.container) * j.c0).Position
		local chain = { p }
		local c = j.container
		while c ~= hrp do
			table.insert(chain, 1, c.Name)
			c = c:IsA("Bone") and c.Parent or joints[c.Name].container
		end
		table.insert(chain, 1, "HumanoidRootPart")
		path[p] = chain
	end
	local corr = {}
	for _, p in PARTS do
		local s = SEGMENT[p]
		corr[p] = s and align(jointPos[s[2]] - jointPos[s[1]], DOWN) or CFrame.identity
	end
	local leg = (jointPos.LeftLowerLeg - jointPos.LeftUpperLeg).Magnitude + (jointPos.LeftFoot - jointPos.LeftLowerLeg).Magnitude
	return {
		rig = rig, hrp = hrp, joints = joints, owner = owner, restCF = restCF, path = path, corr = corr,
		scale = leg / CANON_LEG,
	}
end

-- One frame of a take adapted to the avatar: Keyframe with poses along the avatar's own joint chain.
local function adaptFrame(time: number, canon, info): Keyframe
	local Wn = { HumanoidRootPart = CFrame.identity }
	local Wc = { HumanoidRootPart = CFrame.identity }
	for _, p in PARTS do
		Wc[p] = Wc[CANON_PARENT[p]] * canon[p]
		Wn[p] = Wc[p] * info.corr[p]
	end
	local out = Instance.new("Keyframe")
	out.Time = time
	local nodes = {}
	local function node(chain, upto: number): Pose
		local key = table.concat(chain, "/", 1, upto)
		if nodes[key] then return nodes[key] end
		local pose = Instance.new("Pose")
		pose.Name = chain[upto]
		pose.Weight = 1
		pose.Parent = upto == 1 and out or node(chain, upto - 1)
		nodes[key] = pose
		return pose
	end
	for _, p in PARTS do
		local j = info.joints[p]
		local container = j.container
		local Pc = Wn[info.owner(container).Name] * rot(info.restCF(container))
		local P1 = Wn[p] * rot(info.restCF(info.rig[p]))
		local r = rot(j.c0):Inverse() * Pc:Inverse() * P1 * rot(j.c1)
		local pos = Vector3.zero
		if p == "LowerTorso" then
			pos = rot(j.c0):Inverse() * (canon.root * info.scale)
		end
		node(info.path[p], #info.path[p]).CFrame = CFrame.new(pos) * r
	end
	return out
end

-- Check a decoded take file and return a reader for its frames.
local function readTake(data)
	if type(data) ~= "table" or data.format ~= "motive-roblox" or data.version ~= 1 then
		fail("Il file non e' un'animazione Motive valida.")
	end
	local n, parts = data.frames, data.parts
	if type(n) ~= "number" or n < 1 or type(parts) ~= "table" or #parts ~= #PARTS
		or type(data.rot) ~= "table" or #data.rot ~= n * #parts * 4
		or type(data.root) ~= "table" or #data.root ~= n * 3 then
		fail("Il file dell'animazione e' danneggiato: riscaricalo.")
	end
	local index = {}
	for i, p in parts do index[p] = i end
	for _, p in PARTS do
		if not index[p] then fail("Il file dell'animazione e' danneggiato: riscaricalo.") end
	end
	local np = #parts
	return n, (data.fps or 30), function(f: number)
		local canon = {}
		for _, p in PARTS do
			local b = ((f - 1) * np + index[p] - 1) * 4
			canon[p] = CFrame.new(0, 0, 0, data.rot[b + 1], data.rot[b + 2], data.rot[b + 3], data.rot[b + 4])
		end
		local r = (f - 1) * 3
		canon.root = Vector3.new(data.root[r + 1], data.root[r + 2], data.root[r + 3])
		return canon
	end
end

-- Animation Editor storage, as the editor itself creates it (observed in Studio 2026-11-18):
-- ServerStorage.RBX_ANIMSAVES [Model] > <rig name> [ObjectValue, Value = rig] holds the saved animations,
-- and the rig has AnimSaves [ObjectValue] pointing at that ObjectValue.
local function animSavesFolder(rig: Model): Instance
	local ref = rig:FindFirstChild("AnimSaves")
	if ref and ref:IsA("ObjectValue") and ref.Value and ref.Value.Parent then
		return ref.Value
	end
	local ss = game:GetService("ServerStorage")
	local root = ss:FindFirstChild("RBX_ANIMSAVES")
	if not root then
		root = Instance.new("Model")
		root.Name = "RBX_ANIMSAVES"
		root.Parent = ss
	end
	local holder
	for _, c in root:GetChildren() do
		if c:IsA("ObjectValue") and c.Value == rig then holder = c end
	end
	if not holder then
		holder = Instance.new("ObjectValue")
		holder.Name = rig.Name
		holder.Value = rig
		holder.Parent = root
	end
	if not (ref and ref:IsA("ObjectValue")) then
		if ref then ref.Name = "AnimSaves_vecchio" end
		ref = Instance.new("ObjectValue")
		ref.Name = "AnimSaves"
		ref.Parent = rig
	end
	ref.Value = holder
	return holder
end

-- Adapt a decoded take to the avatar and save it for the Animation Editor. Returns the saved KeyframeSequence.
local function applyTake(rig: Model, data, name: string, progress: ((number) -> ())?): KeyframeSequence
	local info = describeRig(rig)
	local n, fps, frame = readTake(data)
	local ks = Instance.new("KeyframeSequence")
	ks.Loop = true
	ks.Priority = Enum.AnimationPriority.Action
	for f = 1, n do
		adaptFrame((f - 1) / fps, frame(f), info).Parent = ks
		if f % 60 == 0 then
			if progress then progress(f / n) end
			task.wait()
		end
	end
	local folder = animSavesFolder(rig)
	-- never overwrite: a saved animation may hold a student's edits
	local final, k = name, 1
	while folder:FindFirstChild(final) do
		k += 1
		final = name .. " (" .. k .. ")"
	end
	ks.Name = final
	ks.Parent = folder
	return ks
end

local function isRig(inst: Instance): boolean
	return inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") ~= nil
end

-- The avatar to animate: the selected one, or the only one in the scene.
local function pickRig(): Model
	for _, s in Selection:Get() do
		local r = s
		while r and r ~= workspace and r ~= game and not isRig(r) do r = r.Parent end
		if r and r ~= workspace and r ~= game and r:IsDescendantOf(workspace) then return r end
	end
	local rigs = {}
	for _, m in workspace:GetDescendants() do
		if isRig(m) then table.insert(rigs, m) end
	end
	if #rigs == 0 then
		fail("Nella scena non c'e' nessun avatar.\nCrealo dalla scheda Avatar > Character, poi riprova.")
	elseif #rigs > 1 then
		fail("Nella scena ci sono " .. #rigs .. " avatar.\nClicca sull'avatar da animare, poi riprova.")
	end
	return rigs[1]
end

local function httpGetJson(url: string)
	local ok, res = pcall(function()
		return HttpService:GetAsync(url .. "?v=" .. tostring(os.time()), true)
	end)
	if not ok then
		local msg = tostring(res)
		if msg:lower():find("permission") or msg:lower():find("not allowed") or msg:lower():find("denied") then
			fail("Studio non lascia scaricare le animazioni.\nVai in Plugins > Manage Plugins, apri 'Animazioni Motive' e consenti l'accesso a raw.githubusercontent.com.")
		end
		fail("Non riesco a scaricare le animazioni: controlla la connessione a internet e riprova.\n(" .. msg .. ")")
	end
	local okJson, data = pcall(function() return HttpService:JSONDecode(res) end)
	if not okJson then
		fail("Il server ha risposto in modo strano: riprova tra qualche minuto.")
	end
	return data
end

local Motive = {
	VERSION = VERSION, describeRig = describeRig, readTake = readTake, applyTake = applyTake,
	animSavesFolder = animSavesFolder, pickRig = pickRig,
}

if not plugin then
	return Motive
end

---------------------------------------------------------------------------------------------------------- UI
local studio = settings().Studio
local function color(c: Enum.StudioStyleGuideColor, m: Enum.StudioStyleGuideModifier?)
	return studio.Theme:GetColor(c, m or Enum.StudioStyleGuideModifier.Default)
end

local toolbar = plugin:CreateToolbar("Motive")
local toggle = toolbar:CreateButton("MotiveAnimazioni", "Mostra le animazioni Motive", "", "Animazioni Motive")
toggle.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGuiAsync("MotiveAnimazioni",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, true, false, 320, 520, 260, 300))
widget.Title = "Animazioni Motive"
widget.Name = "AnimazioniMotive"
toggle:SetActive(widget.Enabled)
toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggle:SetActive(widget.Enabled)
end)

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BorderSizePixel = 0
root.Parent = widget

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 96)
status.Position = UDim2.fromOffset(8, 8)
status.BackgroundTransparency = 1
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Font = Enum.Font.SourceSansSemibold
status.TextSize = 17
status.Parent = root

local refresh = Instance.new("TextButton")
refresh.Size = UDim2.new(1, -16, 0, 30)
refresh.Position = UDim2.fromOffset(8, 108)
refresh.Font = Enum.Font.SourceSans
refresh.TextSize = 16
refresh.Text = "Aggiorna elenco"
refresh.Parent = root

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -16, 1, -176)
list.Position = UDim2.fromOffset(8, 146)
list.BorderSizePixel = 0
list.ScrollBarThickness = 8
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.Parent = root
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 4)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list

local footer = Instance.new("TextLabel")
footer.Size = UDim2.new(1, -16, 0, 20)
footer.Position = UDim2.new(0, 8, 1, -24)
footer.BackgroundTransparency = 1
footer.Font = Enum.Font.SourceSans
footer.TextSize = 13
footer.TextXAlignment = Enum.TextXAlignment.Left
footer.Text = "versione " .. VERSION
footer.Parent = root

local statusKind = "info"
local function paint()
	root.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
	list.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
	footer.TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
	status.TextColor3 = statusKind == "error" and color(Enum.StudioStyleGuideColor.ErrorText)
		or color(Enum.StudioStyleGuideColor.MainText)
	for _, b in { refresh, table.unpack(list:GetChildren()) } do
		if b:IsA("TextButton") then
			b.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button)
			b.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText)
			b.BorderColor3 = color(Enum.StudioStyleGuideColor.ButtonBorder)
		end
	end
end
studio.ThemeChanged:Connect(paint)

local function say(text: string, kind: string?)
	status.Text = text
	statusKind = kind or "info"
	paint()
end

local busy = false
local cache = {}

-- Run an action with the busy guard, showing student errors in the panel.
local function run(action: () -> ())
	if busy then return end
	busy = true
	local ok, err = pcall(action)
	busy = false
	if not ok then
		if type(err) == "table" and err.student then
			say(err.student, "error")
		else
			say("Qualcosa non ha funzionato. Riprova; se succede ancora, avvisa il docente.\n(" .. tostring(err) .. ")", "error")
			warn("[Motive] " .. tostring(err))
		end
	end
end

local function useTake(entry)
	run(function()
		if RunService:IsRunning() then
			fail("Ferma il Play (tasto Stop) e riprova.")
		end
		local rig = pickRig()
		say("Scarico '" .. entry.name .. "'...")
		local data = cache[entry.file]
		if not data then
			data = httpGetJson(BASE_URL .. HttpService:UrlEncode(entry.file))
			cache[entry.file] = data
		end
		local recording = ChangeHistoryService:TryBeginRecording("Animazione Motive")
		local ok, res = pcall(applyTake, rig, data, entry.name, function(p)
			say(string.format("Adatto '%s' all'avatar... %d%%", entry.name, math.floor(p * 100)))
		end)
		if recording then
			ChangeHistoryService:FinishRecording(recording, ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
		end
		if not ok then error(res, 0) end
		Selection:Set({ rig })
		say("Fatto! '" .. res.Name .. "' e' pronta.\n\nOra: scheda Avatar > Animation Editor, poi scegli '" .. res.Name
			.. "' dal menu dell'animazione.\n(Se l'Animation Editor era gia' aperto, chiudilo e riaprilo.)")
	end)
end

local function loadList()
	run(function()
		say("Carico l'elenco delle animazioni...")
		local index = httpGetJson(BASE_URL .. "index.json")
		if type(index) ~= "table" or type(index.takes) ~= "table" then
			fail("L'elenco delle animazioni e' danneggiato: avvisa il docente.")
		end
		for _, c in list:GetChildren() do
			if c:IsA("TextButton") then c:Destroy() end
		end
		for i, entry in index.takes do
			if type(entry) == "table" and type(entry.name) == "string" and type(entry.file) == "string" then
				local b = Instance.new("TextButton")
				b.Size = UDim2.new(1, -10, 0, 34)
				b.LayoutOrder = i
				b.Font = Enum.Font.SourceSans
				b.TextSize = 16
				b.TextXAlignment = Enum.TextXAlignment.Left
				b.Text = "  " .. entry.name .. (type(entry.seconds) == "number" and string.format("   (%.0f s)", entry.seconds) or "")
				b.Parent = list
				b.Activated:Connect(function() useTake(entry) end)
			end
		end
		say("1. Crea il tuo avatar: scheda Avatar > Character.\n2. Clicca un'animazione qui sotto.", "info")
	end)
end

refresh.Activated:Connect(loadList)
paint()
say("Carico l'elenco delle animazioni...")
task.defer(loadList)
