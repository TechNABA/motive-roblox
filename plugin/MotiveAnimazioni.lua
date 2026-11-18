--[[
Animazioni Motive - plugin di Roblox Studio (https://github.com/TechNABA/motive-roblox)

Apre i pacchetti di animazioni registrate in Motive (il file .zip mandato dal docente, o i file .json delle take)
e le adatta agli avatar selezionati (R15 classico o R15 Plus, qualsiasi corpo). Ogni take viene salvata dove la
trova l'Animation Editor (Rig > AnimSaves): li' si guarda nella viewport e si modifica nella timeline.

Caricato come ModuleScript (senza `plugin`) restituisce le funzioni: lo usa tests/plugin_test.luau.
]]

local HttpService = game:GetService("HttpService") -- only JSONDecode: nothing is downloaded
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local VERSION = "1.0.0"
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
		if a:Dot(b) > 0 then
			return CFrame.identity
		end
		-- opposite directions: half turn about any axis perpendicular to a
		local perp = a:Cross(math.abs(a.X) < 0.9 and Vector3.xAxis or Vector3.yAxis).Unit
		return CFrame.fromAxisAngle(perp, math.pi)
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
	-- every R15 joint must hang on the root or on another R15 part (directly or through bones)
	for _, p in PARTS do
		local o = owner(joints[p].container)
		if not (o and o.Parent == rig and (o == hrp or table.find(PARTS, o.Name))) then
			fail("L'avatar '" .. rig.Name .. "' ha articolazioni non standard (" .. p .. " e' attaccata a "
				.. (o and o.Name or "niente") .. "). Usa un avatar creato da Avatar > Character.")
		end
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
	if type(data) ~= "table" or data.format ~= "motive-roblox" then
		fail("Il file non e' un'animazione Motive valida.")
	end
	if data.version ~= 1 then
		fail("Questa animazione e' di una versione diversa: aggiorna il plugin (Plugins > Manage Plugins).")
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
	-- the frames are composed with CANON_PARENT: a take built on another hierarchy must be refused
	if type(data.parents) ~= "table" or #data.parents ~= #parts then
		fail("Il file dell'animazione e' danneggiato: riscaricalo.")
	end
	for i, p in parts do
		if data.parents[i] ~= CANON_PARENT[p] then
			fail("Questa animazione e' di una versione diversa: aggiorna il plugin (Plugins > Manage Plugins).")
		end
	end
	local fps = data.fps
	if type(fps) ~= "number" or fps < 1 or fps > 1000 then
		fail("Il file dell'animazione e' danneggiato: riscaricalo.")
	end
	local np = #parts
	return n, fps, function(f: number)
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
	-- the holder must belong to this rig: a duplicated avatar still points at the original's holder
	if ref and ref:IsA("ObjectValue") and ref.Value and ref.Value.Parent
		and (not ref.Value:IsA("ObjectValue") or ref.Value.Value == rig) then
		return ref.Value
	end
	if ref and not ref:IsA("ObjectValue") then
		-- older Studio versions kept the saves in a folder inside the rig: keep using it, the editor migrates it
		return ref
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
	if not ref then
		ref = Instance.new("ObjectValue")
		ref.Name = "AnimSaves"
		ref.Parent = rig
	end
	ref.Value = holder
	return holder
end

-- Adapt a decoded take to the avatar. Yields; touches nothing in the place.
local function buildTake(rig: Model, data, progress: ((number) -> ())?): KeyframeSequence
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
	return ks
end

-- The saved animation with this name on this avatar, if any (looks only: creates nothing).
local function findSaved(rig: Model, name: string): Instance?
	local ref = rig:FindFirstChild("AnimSaves")
	if ref and not ref:IsA("ObjectValue") then
		return ref:FindFirstChild(name)
	end
	if ref and ref.Value and ref.Value.Parent and (not ref.Value:IsA("ObjectValue") or ref.Value.Value == rig) then
		return ref.Value:FindFirstChild(name)
	end
	local root = game:GetService("ServerStorage"):FindFirstChild("RBX_ANIMSAVES")
	if root then
		for _, c in root:GetChildren() do
			if c:IsA("ObjectValue") and c.Value == rig then return c:FindFirstChild(name) end
		end
	end
	return nil
end

-- Save an adapted take where the Animation Editor finds it. Does not yield.
local function saveTake(rig: Model, ks: KeyframeSequence, name: string): KeyframeSequence
	if not rig:IsDescendantOf(workspace) then
		fail("L'avatar e' stato tolto dalla scena mentre preparavo l'animazione: riprova.")
	end
	ks.Name = name
	ks.Parent = animSavesFolder(rig)
	return ks
end

local function isRig(inst: Instance): boolean
	return inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") ~= nil
end

-- The avatars to animate: the selected ones, or the only one in the scene.
local function pickRigs(): { Model }
	local rigs, seen = {}, {}
	for _, s in Selection:Get() do
		local r = s
		while r and r ~= workspace and r ~= game and not isRig(r) do r = r.Parent end
		if r and r ~= workspace and r ~= game and r:IsDescendantOf(workspace) and not seen[r] then
			seen[r] = true
			table.insert(rigs, r)
		end
	end
	if #rigs > 0 then return rigs end
	for _, m in workspace:GetDescendants() do
		if isRig(m) then table.insert(rigs, m) end
	end
	if #rigs == 0 then
		fail("Nella scena non c'e' nessun avatar.\nCrealo dalla scheda Avatar > Character, poi riprova.")
	elseif #rigs > 1 then
		fail("Nella scena ci sono " .. #rigs .. " avatar: selezionali (Ctrl+clic per sceglierne piu' di uno), poi riprova.")
	end
	return rigs
end

----------------------------------------------------------------------------------------------- packages (.zip)
-- Raw DEFLATE decoder (RFC 1951), for packages re-compressed by Windows or macOS. Converti.bat stores files
-- uncompressed, which needs no decoding at all.
local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
	3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function inflate(src: buffer, start: number, srcLen: number, outLen: number): buffer
	local out = buffer.create(outLen)
	local pos, stop, op = start, start + srcLen, 0
	local bitbuf, bitcnt = 0, 0
	local function damaged()
		fail("Il pacchetto e' danneggiato: chiedi al docente di rimandarlo.")
	end
	local function bits(n: number): number
		while bitcnt < n do
			if pos >= stop then damaged() end
			bitbuf = bit32.bor(bitbuf, bit32.lshift(buffer.readu8(src, pos), bitcnt))
			pos += 1
			bitcnt += 8
		end
		local v = bit32.band(bitbuf, bit32.lshift(1, n) - 1)
		bitbuf = bit32.rshift(bitbuf, n)
		bitcnt -= n
		return v
	end
	-- canonical Huffman table (as in zlib's puff.c): count[len] codes of each length, symbols in code order.
	-- Both tables are 0-based.
	local function build(lengths: { [number]: number }, n: number)
		local count, offs, symbol = {}, {}, {}
		for len = 0, 15 do count[len] = 0 end
		for i = 0, n - 1 do
			local len = lengths[i] or 0
			count[len] += 1
		end
		offs[1] = 0
		for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
		for i = 0, n - 1 do
			local len = lengths[i] or 0
			if len > 0 then
				symbol[offs[len]] = i
				offs[len] += 1
			end
		end
		return count, symbol
	end
	local function decode(count, symbol): number
		local code, first, index = 0, 0, 0
		for len = 1, 15 do
			code = bit32.bor(code, bits(1))
			local c = count[len]
			if code - c < first then
				return symbol[index + (code - first)]
			end
			index += c
			first = (first + c) * 2
			code *= 2
		end
		damaged()
		return 0
	end
	local function codes(lcount, lsym, dcount, dsym)
		while true do
			local sym = decode(lcount, lsym)
			if sym < 256 then
				if op >= outLen then damaged() end
				buffer.writeu8(out, op, sym)
				op += 1
			elseif sym == 256 then
				return
			else
				sym -= 257
				if sym >= 29 then damaged() end
				local len = LEN_BASE[sym + 1] + bits(LEN_EXTRA[sym + 1])
				local ds = decode(dcount, dsym)
				if ds >= 30 then damaged() end
				local dist = DIST_BASE[ds + 1] + bits(DIST_EXTRA[ds + 1])
				if dist > op or op + len > outLen then damaged() end
				for _ = 1, len do
					buffer.writeu8(out, op, buffer.readu8(out, op - dist))
					op += 1
				end
			end
		end
	end
	local fixedL, fixedD
	repeat
		local last = bits(1)
		local kind = bits(2)
		if kind == 0 then
			bitbuf, bitcnt = 0, 0 -- stored block: byte aligned
			if pos + 4 > stop then damaged() end
			local len = buffer.readu16(src, pos)
			pos += 4
			if pos + len > stop or op + len > outLen then damaged() end
			buffer.copy(out, op, src, pos, len)
			pos += len
			op += len
		elseif kind == 1 then
			if not fixedL then
				local l = {}
				for i = 0, 143 do l[i] = 8 end
				for i = 144, 255 do l[i] = 9 end
				for i = 256, 279 do l[i] = 7 end
				for i = 280, 287 do l[i] = 8 end
				local d = {}
				for i = 0, 29 do d[i] = 5 end
				fixedL = { build(l, 288) }
				fixedD = { build(d, 30) }
			end
			codes(fixedL[1], fixedL[2], fixedD[1], fixedD[2])
		elseif kind == 2 then
			local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
			local cl = {}
			for i = 0, 18 do cl[i] = 0 end
			for i = 1, ncode do cl[CL_ORDER[i]] = bits(3) end
			local ccount, csym = build(cl, 19)
			local lengths, i = {}, 0
			while i < nlen + ndist do
				local sym = decode(ccount, csym)
				if sym < 16 then
					lengths[i] = sym
					i += 1
				else
					local rep, val = 0, 0
					if sym == 16 then
						if i == 0 then damaged() end
						val, rep = lengths[i - 1], 3 + bits(2)
					elseif sym == 17 then
						rep = 3 + bits(3)
					else
						rep = 11 + bits(7)
					end
					if i + rep > nlen + ndist then damaged() end
					for _ = 1, rep do
						lengths[i] = val
						i += 1
					end
				end
			end
			local dl = {}
			for k = 0, ndist - 1 do dl[k] = lengths[nlen + k] end
			local lcount, lsym = build(lengths, nlen)
			local dcount, dsym = build(dl, ndist)
			codes(lcount, lsym, dcount, dsym)
		else
			damaged()
		end
	until last == 1
	if op ~= outLen then damaged() end
	return out
end

-- Files of a .zip: { [name] = contents }. Stored and deflated entries; macOS metadata is skipped.
local function readZip(bin: string): { [string]: string }
	local b = buffer.fromstring(bin)
	local size = buffer.len(b)
	local function notZip()
		fail("Questo file non e' un pacchetto valido: scegli il .zip che ti ha mandato il docente.")
	end
	local eocd
	for p = size - 22, math.max(0, size - 65557), -1 do
		if buffer.readu32(b, p) == 0x06054b50 then
			eocd = p
			break
		end
	end
	if not eocd then notZip() end
	local entries, cdPos = buffer.readu16(b, eocd + 10), buffer.readu32(b, eocd + 16)
	local files = {}
	for _ = 1, entries do
		if cdPos + 46 > size or buffer.readu32(b, cdPos) ~= 0x02014b50 then notZip() end
		local flags, method = buffer.readu16(b, cdPos + 8), buffer.readu16(b, cdPos + 10)
		local csize, usize = buffer.readu32(b, cdPos + 20), buffer.readu32(b, cdPos + 24)
		local nlen, elen, clen = buffer.readu16(b, cdPos + 28), buffer.readu16(b, cdPos + 30), buffer.readu16(b, cdPos + 32)
		local loc = buffer.readu32(b, cdPos + 42)
		local name = buffer.readstring(b, cdPos + 46, nlen)
		cdPos += 46 + nlen + elen + clen
		local skip = name:sub(-1) == "/" or name:find("__MACOSX", 1, true) or name:match("[/\\]%._") or name:match("^%._")
		if not skip then
			if bit32.band(flags, 1) ~= 0 then
				fail("Il pacchetto e' protetto da password: chiedi al docente un pacchetto senza password.")
			end
			if loc + 30 > size or buffer.readu32(b, loc) ~= 0x04034b50 then notZip() end
			local data = loc + 30 + buffer.readu16(b, loc + 26) + buffer.readu16(b, loc + 28)
			if data + csize > size then notZip() end
			if method == 0 then
				files[name] = buffer.readstring(b, data, csize)
			elseif method == 8 then
				files[name] = buffer.tostring(inflate(b, data, csize, usize))
			else
				fail("Il pacchetto usa una compressione non supportata: chiedi al docente di rimandarlo.")
			end
		end
	end
	return files
end

local function decodeJson(text: string)
	local ok, data = pcall(function() return HttpService:JSONDecode(text) end)
	return ok and data or nil
end

-- Takes from the chosen files: .zip packages and/or loose .json takes (a Mac may unpack the zip by itself).
-- Returns a list of { name = string, data = table }, in package order.
local function readTakes(files: { { name: string, contents: string } }, progress: ((number) -> ())?)
	local takes, seen = {}, {}
	local function add(data)
		if type(data) == "table" and data.format == "motive-roblox" and type(data.name) == "string" and not seen[data.name] then
			seen[data.name] = true
			table.insert(takes, { name = data.name, data = data })
		end
	end
	for i, f in files do
		if f.name:lower():match("%.zip$") then
			local entries = readZip(f.contents)
			local order = {}
			for path, text in entries do
				if path:match("pacchetto%.json$") then
					local manifest = decodeJson(text)
					if type(manifest) == "table" and type(manifest.takes) == "table" then
						local dir = path:match("^(.*/)") or ""
						for _, t in manifest.takes do
							if type(t) == "table" and type(t.file) == "string" then table.insert(order, dir .. t.file) end
						end
					end
				end
			end
			for path in entries do
				if path:lower():match("%.json$") and not path:match("pacchetto%.json$") and not table.find(order, path) then
					table.insert(order, path)
				end
			end
			for k, path in order do
				if entries[path] then add(decodeJson(entries[path])) end
				if progress then progress((i - 1 + k / #order) / #files) end
				if k % 5 == 0 then task.wait() end
			end
		else
			add(decodeJson(f.contents))
			if progress then progress(i / #files) end
		end
	end
	if #takes == 0 then
		fail("In questi file non ci sono animazioni Motive: scegli il .zip che ti ha mandato il docente.")
	end
	return takes
end

local Motive = {
	VERSION = VERSION, describeRig = describeRig, readTake = readTake, buildTake = buildTake, saveTake = saveTake,
	findSaved = findSaved, animSavesFolder = animSavesFolder, pickRigs = pickRigs, readZip = readZip,
	readTakes = readTakes,
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

local function label(size: number, font: Enum.Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Font = font
	l.TextSize = size
	return l
end

local status = label(17, Enum.Font.SourceSansSemibold)
status.Size = UDim2.new(1, -16, 0, 0)
status.AutomaticSize = Enum.AutomaticSize.Y -- long messages push everything below down
status.Position = UDim2.fromOffset(8, 8)
status.Parent = root

local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, -16, 0, 10)
bar.BorderSizePixel = 0
bar.Visible = false
bar.Parent = root
local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(0, 1)
fill.BorderSizePixel = 0
fill.Parent = bar

local open = Instance.new("TextButton")
open.Size = UDim2.new(1, -16, 0, 36)
open.Font = Enum.Font.SourceSansSemibold
open.TextSize = 18
open.Text = "Apri pacchetto..."
open.Parent = root

local list = Instance.new("ScrollingFrame")
list.BorderSizePixel = 0
list.ScrollBarThickness = 8
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.Parent = root
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 4)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list

local footer = label(13, Enum.Font.SourceSans)
footer.Size = UDim2.new(1, -16, 0, 20)
footer.Position = UDim2.new(0, 8, 1, -24)
footer.Text = "versione " .. VERSION
footer.Parent = root

-- everything sits right below the message, whatever its height
local function relayout()
	local y = 8 + status.AbsoluteSize.Y + 8
	bar.Position = UDim2.fromOffset(8, y)
	if bar.Visible then y += 18 end
	open.Position = UDim2.fromOffset(8, y)
	list.Position = UDim2.fromOffset(8, y + 44)
	list.Size = UDim2.new(1, -16, 1, -(y + 44 + 28))
end
status:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

local busy = false
local statusKind = "info"
local function paintStatus()
	status.TextColor3 = statusKind == "error" and color(Enum.StudioStyleGuideColor.ErrorText)
		or color(Enum.StudioStyleGuideColor.MainText)
end

local function paintButton(b: TextButton)
	b.AutoButtonColor = not busy
	b.BackgroundColor3 = color(Enum.StudioStyleGuideColor.Button,
		busy and Enum.StudioStyleGuideModifier.Disabled or Enum.StudioStyleGuideModifier.Default)
	b.TextColor3 = color(Enum.StudioStyleGuideColor.ButtonText,
		busy and Enum.StudioStyleGuideModifier.Disabled or Enum.StudioStyleGuideModifier.Default)
	b.BorderColor3 = color(Enum.StudioStyleGuideColor.ButtonBorder)
end

local function paint()
	root.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
	list.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
	bar.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
	fill.BackgroundColor3 = color(Enum.StudioStyleGuideColor.DialogMainButton)
	footer.TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
	paintStatus()
	paintButton(open)
	for _, c in list:GetChildren() do
		if c:IsA("TextButton") then paintButton(c) end
		if c:IsA("TextLabel") then c.TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText) end
	end
end
studio.ThemeChanged:Connect(paint)

local function say(text: string, kind: string?)
	status.Text = text
	statusKind = kind or "info"
	paintStatus()
end

-- progress bar: a fraction 0..1, or nil to hide it
local function progress(p: number?)
	bar.Visible = p ~= nil
	fill.Size = UDim2.fromScale(math.clamp(p or 0, 0, 1), 1)
	relayout()
end

-- Run an action with the busy guard: buttons greyed out, student errors shown in the panel.
local function run(action: () -> ())
	if busy then return end
	busy = true
	paint()
	local ok, err = pcall(action)
	busy = false
	progress(nil)
	paint()
	if not ok then
		if type(err) == "table" and err.student then
			say(err.student, "error")
		else
			say("Qualcosa non ha funzionato. Riprova; se succede ancora, avvisa il docente.\n(" .. tostring(err) .. ")", "error")
			warn("[Motive] " .. tostring(err))
		end
	end
end

local HELP = "1. Apri il pacchetto che ti ha mandato il docente.\n2. Crea l'avatar: scheda Avatar > Character.\n"
	.. "3. Seleziona l'avatar (Ctrl+clic per piu' avatar) e clicca un'animazione."

local function useTake(take)
	run(function()
		if RunService:IsRunning() then
			fail("Ferma il Play (tasto Stop) e riprova.")
		end
		local rigs = pickRigs()
		local todo, already = {}, {}
		for _, rig in rigs do
			if findSaved(rig, take.name) then
				table.insert(already, rig.Name)
			else
				table.insert(todo, rig)
			end
		end
		local built = {}
		for i, rig in todo do
			local prefix = #todo > 1 and string.format("Avatar %d di %d (%s): ", i, #todo, rig.Name) or ""
			say(prefix .. "adatto '" .. take.name .. "'...")
			table.insert(built, buildTake(rig, take.data, function(p)
				progress((i - 1 + p) / #todo)
			end))
		end
		if #built > 0 then
			-- the recording only wraps the instant save, so the student's own edits meanwhile stay separate
			local recording = ChangeHistoryService:TryBeginRecording("Animazione Motive")
			local ok, res = pcall(function()
				for i, rig in todo do saveTake(rig, built[i], take.name) end
			end)
			if recording then
				ChangeHistoryService:FinishRecording(recording, ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
			end
			if not ok then error(res, 0) end
		end
		local names = {}
		for _, rig in todo do table.insert(names, rig.Name) end
		local text = ""
		if #names > 0 then
			text = "Fatto! '" .. take.name .. "' aggiunta a: " .. table.concat(names, ", ") .. ".\n"
		end
		if #already > 0 then
			text ..= "'" .. take.name .. "' c'era gia' in: " .. table.concat(already, ", ") .. " (non l'ho aggiunta di nuovo).\n"
		end
		Selection:Set(rigs)
		say(text .. "\nOra: scheda Avatar > Animation Editor, poi scegli '" .. take.name
			.. "' dal menu dell'animazione. (Se l'Animation Editor era gia' aperto, chiudilo e riaprilo.)")
	end)
end

local loaded = {} -- takes of the opened packages, by name
local function showTakes(takes, title: string)
	local order = #list:GetChildren()
	local header = label(14, Enum.Font.SourceSansSemibold)
	header.Size = UDim2.new(1, -10, 0, 22)
	header.LayoutOrder = order
	header.Text = title
	header.Parent = list
	for i, take in takes do
		if loaded[take.name] then
			loaded[take.name].data = take.data -- reopened package: use the newer data
		else
			loaded[take.name] = take
			local b = Instance.new("TextButton")
			b.Size = UDim2.new(1, -10, 0, 34)
			b.LayoutOrder = order + i
			b.Font = Enum.Font.SourceSans
			b.TextSize = 16
			b.TextXAlignment = Enum.TextXAlignment.Left
			local seconds = type(take.data.seconds) == "number" and string.format("   (%.0f s)", take.data.seconds) or ""
			b.Text = "  " .. take.name .. seconds
			b.Parent = list
			b.Activated:Connect(function() useTake(loaded[take.name]) end)
		end
	end
	paint()
end

open.Activated:Connect(function()
	run(function()
		local chosen = game:GetService("StudioService"):PromptImportFilesAsync({ "zip", "json" })
		if not chosen or #chosen == 0 then return end -- choice cancelled
		say("Apro il pacchetto...")
		progress(0)
		local files, names = {}, {}
		for _, f in chosen do
			table.insert(files, { name = f.Name, contents = f:GetBinaryContents() })
			table.insert(names, f.Name)
		end
		local takes = readTakes(files, progress)
		showTakes(takes, table.concat(names, ", "))
		say(string.format("Pacchetto aperto: %d animazioni.\n\n", #takes) .. HELP)
	end)
end)

paint()
say(HELP)
relayout()
