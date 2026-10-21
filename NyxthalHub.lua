-- Nyxthal Hub: integrated collector edition. Load this entire file once.
local HubEnv = (type(getgenv) == "function" and getgenv()) or _G
if HubEnv.__NyxthalHub and type(HubEnv.__NyxthalHub.Destroy) == "function" then pcall(HubEnv.__NyxthalHub.Destroy) end
if HubEnv.__CandyTween and type(HubEnv.__CandyTween.Stop) == "function" then pcall(HubEnv.__CandyTween.Stop) end
local HubRuntime = { alive = true, connections = {}, threads = {}, cleanup = {} }
HubEnv.__NyxthalHub = HubRuntime
local function HubConnect(signal, fn)
    local connection = signal:Connect(function(...)
        if HubRuntime.alive then return fn(...) end
    end)
    HubRuntime.connections[connection] = true
    return connection
end
local function HubSpawn(fn, ...)
    local args = table.pack(...)
    local thread = coroutine.create(function()
        if HubRuntime.alive then
            local ok, err = xpcall(function() fn(table.unpack(args, 1, args.n)) end, debug.traceback)
            if not ok and HubRuntime.alive then warn("[Nyxthal] " .. tostring(err)) end
        end
        HubRuntime.threads[coroutine.running()] = nil
    end)
    HubRuntime.threads[thread] = true
    task.spawn(thread)
    return thread
end
function HubRuntime.Destroy()
    if not HubRuntime.alive then return end
    HubRuntime.alive = false
    if HubRuntime.Collector then HubRuntime.Collector.Destroy() end
    for connection in pairs(HubRuntime.connections) do pcall(function() connection:Disconnect() end) end
    for thread in pairs(HubRuntime.threads) do if thread ~= coroutine.running() then pcall(task.cancel, thread) end end
    for i = #HubRuntime.cleanup, 1, -1 do pcall(HubRuntime.cleanup[i]) end
    if HubRuntime.gui then pcall(function() HubRuntime.gui:Destroy() end) end
    if HubEnv.__NyxthalHub == HubRuntime then HubEnv.__NyxthalHub = nil end
end


-- Coin collector controller. Observes the game's pickup acknowledgements.
local function CreateCoinCollector(options)
    options = options or {}
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local TweenService = game:GetService("TweenService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local player = Players.LocalPlayer
    local touch = type(firetouchinterest) == "function" and firetouchinterest or nil
    local settings = { Speed = 24, Range = 600, Mode = "All", Noclip = true, Underground = true, Depth = 7, ResetOnFull = true, MurdererOnFull = false, SheriffOnFull = false }
    for key, value in pairs(options.Settings or {}) do if settings[key] ~= nil then settings[key] = value end end
    local c = { Enabled = false, Alive = true, Generation = 0, Settings = settings }
    local state = { phase = "Stopped", detail = "Enable Auto collect to begin", confirmed = 0, attempts = 0, missed = 0, resets = 0, available = 0, map = "-", target = "-", distance = 0, lastError = "", touch = touch ~= nil }
    local containers = setmetatable({}, { __mode = "k" })
    local retry = setmetatable({}, { __mode = "k" })
    local bags, connections, bound = {}, {}, {}
    local lastScan, lastBind, startedAt = -10, -10, os.clock()
    local movement, target, worker
    local resetForRound, resetPending = false, nil
    local motionOwner, roundAction = nil, ""
    local roundEpoch = options.Round and options.Round.Epoch or 0
    local function activeRound()
        if options.Round then return options.Round.IsActive(player) end
        return player:GetAttribute("Alive") == true
    end
    local function fullActionEnabled()
        return settings.ResetOnFull or settings.MurdererOnFull or settings.SheriffOnFull
    end

    local function connect(signal, fn)
        local connection = signal:Connect(fn)
        table.insert(connections, connection)
        return connection
    end
    function c.GetSnapshot()
        local snapshot = table.clone(state)
        snapshot.enabled = c.Enabled
        snapshot.elapsed = math.floor(os.clock() - startedAt)
        snapshot.roundAction = roundAction
        snapshot.round = options.Round and options.Round.GetSnapshot() or nil
        snapshot.bags = {}
        for id, bag in pairs(bags) do snapshot.bags[id] = table.clone(bag) end
        return snapshot
    end
    local function notify(phase, detail)
        if phase then state.phase = phase end
        if detail then state.detail = detail end
        if options.OnStatus then
            local ok, err = pcall(options.OnStatus, c.GetSnapshot())
            if not ok then warn("[Collector UI] " .. tostring(err)) end
        end
    end
    local function cleanMove(restorePosition)
        local move = movement
        movement = nil
        if not move then return end
        if move.step then move.step:Disconnect() end
        if move.tween then pcall(function() move.tween:Cancel() end) end
        if move.force then move.force:Destroy() end
        if move.attachment then move.attachment:Destroy() end
        for part, original in pairs(move.collisions) do
            pcall(function() if part.Parent then part.CanCollide = original end end)
        end
        pcall(function()
            if move.root.Parent and move.humanoid.Health > 0 and player.Character == move.character
                and activeRound() then
                if restorePosition ~= false and move.underground then move.root.CFrame = move.recovery end
                local _, yaw = move.root.CFrame:ToOrientation()
                move.root.CFrame = CFrame.new(move.root.Position) * CFrame.Angles(0, yaw, 0)
            end
            if move.humanoid.Parent then
                move.humanoid.AutoRotate = move.autoRotate
                move.humanoid.PlatformStand = move.platformStand
                if move.humanoid.Health > 0 and not move.platformStand then move.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end
            end
            if move.root.Parent then move.root.AssemblyLinearVelocity = Vector3.zero; move.root.AssemblyAngularVelocity = Vector3.zero end
        end)
    end
    function c.SetEnabled(value)
        if not c.Alive then return end
        value = value == true
        if c.Enabled == value then return end
        c.Enabled = value
        if not value and options.OnStop then pcall(options.OnStop) end
        c.Generation += 1
        cleanMove()
        target = nil
        state.target, state.distance = "-", 0
        notify(value and "Starting" or "Stopped", value and "Checking round and pickups" or "Movement restored")
    end
    function c.SetOption(key, value)
        if key == "Speed" then
            value = tonumber(value)
            if not value or value ~= value then return false end
            value = math.clamp(value, 10, 60)
        elseif key == "Range" then
            value = tonumber(value)
            if not value or value ~= value then return false end
            value = math.clamp(value, 50, 1500)
        elseif key == "Mode" then
            if value ~= "All" and value ~= "Coin" and value ~= "Candy" then return false end
        elseif key == "Depth" then
            value = tonumber(value)
            if not value or value ~= value then return false end
            value = math.clamp(value, 3, 16)
        elseif key == "Noclip" or key == "Underground" or key == "ResetOnFull" or key == "MurdererOnFull" or key == "SheriffOnFull" then value = value == true
        else return false end
        settings[key] = value
        if key == "Mode" or key == "ResetOnFull" then resetPending = nil end
        c.Generation += 1
        cleanMove()
        return true
    end
    -- Normalize any settings loaded from an older or hand-edited file.
    for key, default in pairs({ Speed = 24, Range = 600, Mode = "All", Noclip = true, Underground = true, Depth = 7, ResetOnFull = true, MurdererOnFull = false, SheriffOnFull = false }) do
        if not c.SetOption(key, settings[key]) then settings[key] = default end
    end
    function c.SkipTarget()
        if target then retry[target] = { at = os.clock() + 15, failures = 1 } end
        c.Generation += 1
        cleanMove()
        notify(c.Enabled and "Skipping" or "Stopped", "Target skipped for 15 seconds")
    end
    function c.AcquireMovement()
        if motionOwner then return nil end
        local owner = {}
        motionOwner = owner
        c.Generation += 1
        cleanMove()
        return function() if motionOwner == owner then motionOwner = nil end end
    end
    function c.ResetStats()
        state.confirmed, state.attempts, state.missed, state.resets, state.lastError = 0, 0, 0, 0, ""
        startedAt = os.clock()
        notify()
    end
    local function child(root, name) return root and root:FindFirstChild(name) end
    local function syncRound()
        if not options.Round or options.Round.Epoch==roundEpoch then return end
        roundEpoch=options.Round.Epoch
        resetForRound,resetPending,roundAction=false,nil,""
        bags={}
        table.clear(retry)
        c.Generation+=1
        cleanMove(false)
        if options.OnRound then pcall(options.OnRound) end
    end
    local function readInitialBags()
        local gui = child(player, "PlayerGui")
        local container = child(child(child(child(gui, "MainGUI"), "Game"), "CoinBags"), "Container")
        if not container then return end
        for _, frame in ipairs(container:GetChildren()) do
            if frame:IsA("Frame") and frame.Visible and not bags[frame.Name] then
                local label = child(child(child(frame, "CurrencyFrame"), "Icon"), "Coins")
                local full = child(frame, "Full")
                bags[frame.Name] = { count = label and tonumber((label.Text:gsub(",", ""))) or 0, full = full and full.Visible or false }
            end
        end
    end
    local function bindEvents()
        local gameplay = child(child(ReplicatedStorage, "Remotes"), "Gameplay")
        local collected = child(gameplay, "CoinCollected")
        local started = child(gameplay, "CoinsStarted")
        if collected and collected:IsA("RemoteEvent") and not bound[collected] then
            bound[collected] = true
            connect(collected.OnClientEvent, function(id, amount, maximum)
                syncRound()
                if type(id) ~= "string" or type(amount) ~= "number" or type(maximum) ~= "number" then return end
                local previous = bags[id] and bags[id].count or 0
                if amount < 0 or maximum <= 0 or amount ~= amount or maximum ~= maximum then return end
                bags[id] = { count = amount, capacity = maximum, full = amount >= maximum, confirmed = true }
                if c.Enabled then state.confirmed += math.max(0, amount - previous) end
                if c.Enabled and fullActionEnabled() and amount >= maximum and not resetForRound
                    and (settings.Mode == "All" or settings.Mode == id) then resetPending = id end
                notify()
            end)
        end
        if started and started:IsA("RemoteEvent") and not bound[started] then
            bound[started] = true
            connect(started.OnClientEvent, function(definitions)
                bags = {}
                resetForRound, resetPending = false, nil
                roundAction = ""
                if options.OnRound then pcall(options.OnRound) end
                if type(definitions) == "table" then
                    for id in pairs(definitions) do bags[id] = { count = 0, full = false } end
                end
                table.clear(retry)
                c.Generation += 1
                cleanMove()
                if c.Enabled then notify("Starting", "New round; checking fresh spawns") end
            end)
        end
        readInitialBags()
    end
    function c.Rescan()
        table.clear(containers)
        for _, object in ipairs(workspace:GetDescendants()) do
            if object.Name == "CoinContainer" and (object:IsA("Model") or object:IsA("Folder")) then containers[object] = true end
        end
        lastScan = os.clock()
    end
    local function coinInfo(coin)
        if not coin:IsA("BasePart") or coin.Name ~= "Coin_Server" or not coin:IsDescendantOf(workspace)
            or not coin.CanTouch or coin:GetAttribute("Collected") == true then return nil end
        local visual = coin:FindFirstChild("CoinVisual")
        if not visual or not visual:IsA("BasePart") or visual.Transparency >= 0.99
            or visual:GetAttribute("Collected") == true or visual:GetAttribute("RoundEnd") == true
            or visual:GetAttribute("Delete") == true then return nil end
        local id = coin:GetAttribute("CoinID") or visual:GetAttribute("CoinID")
        if type(id) ~= "string" then return nil end
        if settings.Mode ~= "All" and id ~= settings.Mode then return nil end
        return id, visual
    end
    local function characterReady()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not character or not root or not humanoid then return nil, "Waiting for character" end
        if humanoid.Health <= 0 then return nil, "Waiting for respawn" end
        if not activeRound() then return nil, "Waiting for an active round" end
        if root.Anchored then return nil, "Character is temporarily anchored" end
        return { character = character, root = root, humanoid = humanoid }
    end
    local function choose(root)
        local closest, selectedId, best = nil, nil, settings.Range
        local total, inRange, fullCount, cooling, mapName = 0, 0, 0, 0, "-"
        for container in pairs(containers) do
            if not container:IsDescendantOf(workspace) then containers[container] = nil
            else
                mapName = container.Parent and container.Parent.Name or "Map"
                for _, coin in ipairs(container:GetChildren()) do
                    local id = coinInfo(coin)
                    if id then
                        total += 1
                        local distance = (coin.Position - root.Position).Magnitude
                        if bags[id] and bags[id].full then fullCount += 1
                        elseif distance <= settings.Range then
                            inRange += 1
                            if retry[coin] and retry[coin].at > os.clock() then cooling += 1
                            elseif distance < best then closest, selectedId, best = coin, id, distance end
                        end
                    end
                end
            end
        end
        state.available, state.map = total, mapName
        if closest then return closest, selectedId, best end
        local allBagsFull, relevantBags = true, 0
        for id, bag in pairs(bags) do
            if settings.Mode == "All" or id == settings.Mode then relevantBags += 1; if not bag.full then allBagsFull = false end end
        end
        if (relevantBags > 0 and allBagsFull) or (total > 0 and fullCount == total) then
            notify("Bag full", "Waiting for the next round")
        elseif mapName == "-" then notify("Waiting for map", "No live CoinContainer yet")
        elseif total == 0 then notify("Waiting for spawns", "No uncollected pickups match the filter")
        elseif inRange == 0 then notify("Out of range", "No pickups inside the search radius")
        elseif cooling == inRange then notify("Retry cooldown", "Missed targets will be retried shortly")
        else notify("Waiting for spawns", "Looking for the next pickup") end
    end
    local function validRun(generation, actor)
        return c.Alive and c.Enabled and c.Generation == generation and player.Character == actor.character
            and actor.root.Parent and actor.humanoid.Health > 0 and activeRound()
    end
    local function beginMove(actor)
        if movement and movement.root == actor.root then return movement end
        cleanMove()
        local _, yaw = actor.root.CFrame:ToOrientation()
        local move = { character = actor.character, root = actor.root, humanoid = actor.humanoid,
            autoRotate = actor.humanoid.AutoRotate, platformStand = actor.humanoid.PlatformStand,
            recovery = actor.root.CFrame, underground = settings.Underground,
            rotation = CFrame.Angles(0, yaw, 0) * CFrame.Angles(settings.Underground and math.pi / 2 or 0, 0, 0), collisions = {} }
        movement = move
        actor.humanoid.AutoRotate = false
        actor.humanoid.PlatformStand = true
        actor.humanoid:Move(Vector3.zero)
        move.attachment = Instance.new("Attachment")
        move.attachment.Name = "NyxthalCollectorAttachment"
        move.attachment.Parent = actor.root
        move.force = Instance.new("VectorForce")
        move.force.Name = "NyxthalCollectorGravity"
        move.force.Attachment0 = move.attachment
        move.force.ApplyAtCenterOfMass = true
        move.force.RelativeTo = Enum.ActuatorRelativeTo.World
        move.force.Force = Vector3.new(0, workspace.Gravity * actor.root.AssemblyMass, 0)
        move.force.Parent = actor.root
        local function step()
            if movement ~= move or not actor.root.Parent then return end
            move.force.Force = Vector3.new(0, workspace.Gravity * actor.root.AssemblyMass, 0)
            actor.root.AssemblyLinearVelocity = Vector3.zero
            actor.root.AssemblyAngularVelocity = Vector3.zero
            if move.hold and (not move.tween or move.tween.PlaybackState ~= Enum.PlaybackState.Playing) then
                actor.root.CFrame = move.hold
            end
            if settings.Noclip or settings.Underground then
                for _, part in ipairs(actor.character:GetDescendants()) do
                    if part:IsA("BasePart") then
                        if move.collisions[part] == nil then move.collisions[part] = part.CanCollide end
                        part.CanCollide = false
                    end
                end
            end
        end
        step()
        move.step = RunService.Stepped:Connect(step)
        return move
    end
    local function travel(move, actor, coin, generation, position, maxTime)
        if not validRun(generation, actor) or movement ~= move then return false end
        local distance = (position - actor.root.Position).Magnitude
        local duration = math.max(0.12, distance / settings.Speed)
        if duration > maxTime then return false end
        if move.tween then move.tween:Cancel() end
        move.hold = nil
        move.tween = TweenService:Create(actor.root, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
            CFrame = CFrame.new(position) * move.rotation,
        })
        move.tween:Play()
        local deadline, bestDistance, lastProgress = os.clock() + duration + 1.5, distance, os.clock()
        local reached = false
        while validRun(generation, actor) and movement == move and coinInfo(coin) and not resetPending do
            local remaining = (actor.root.Position - position).Magnitude
            state.distance = math.floor((actor.root.Position - coin.Position).Magnitude)
            if remaining < bestDistance - 0.25 then bestDistance, lastProgress = remaining, os.clock() end
            if remaining <= 0.45 then reached = true; break end
            if os.clock() >= deadline or os.clock() - lastProgress > 2 then break end
            if move.tween.PlaybackState ~= Enum.PlaybackState.Playing then reached = remaining <= 2; break end
            task.wait(0.05)
        end
        if movement == move then
            move.tween:Cancel()
            move.hold = CFrame.new(actor.root.Position) * move.rotation
        end
        return reached
    end
    local function attempt(coin, id, actor)
        target = coin
        local generation = c.Generation
        local before = bags[id] and bags[id].count or 0
        state.attempts += 1
        state.target = id .. " / " .. (coin.Parent.Parent and coin.Parent.Parent.Name or "Map")
        local move = beginMove(actor)
        move.recovery = CFrame.new(coin.Position + Vector3.new(0, 3, 0))
        local reached
        if settings.Underground then
            notify("Below map", "Lying face-up beneath the floor")
            local minY = workspace.FallenPartsDestroyHeight + 20
            local laneY = math.max(minY, math.min(actor.root.Position.Y, coin.Position.Y) - settings.Depth)
            -- Once below the surface, do not descend another full depth on each pickup.
            if move.inLane then laneY = math.max(minY, coin.Position.Y - settings.Depth) end
            local lowered = move.inLane or travel(move, actor, coin, generation, Vector3.new(actor.root.Position.X, laneY, actor.root.Position.Z), 5)
            if lowered then
                move.inLane = true
                reached = travel(move, actor, coin, generation, Vector3.new(coin.Position.X, laneY, coin.Position.Z), 45)
                if reached then
                    -- Lying on the back makes root Z its vertical thickness.
                    local pickupDepth = math.clamp(coin.Size.Y / 2 + actor.root.Size.Z / 2 - 0.35, 0.5, 4.5)
                    move.pickupDepth = pickupDepth
                    reached = travel(move, actor, coin, generation, coin.Position - Vector3.new(0, pickupDepth, 0), 5)
                end
            end
        else
            notify("Moving", "Approaching the nearest " .. id)
            reached = travel(move, actor, coin, generation, coin.Position + Vector3.new(0, 1, 0), 45)
        end
        if validRun(generation, actor) and movement == move and coinInfo(coin) and reached then
            notify("Collecting", "Waiting for a server-confirmed bag update")
            local deadline, nextTouch = os.clock() + 2, 0
            while validRun(generation, actor) and movement == move and os.clock() < deadline do
                if (bags[id] and bags[id].count or 0) > before then break end
                if not coinInfo(coin) or resetPending then break end
                if (actor.root.Position - coin.Position).Magnitude <= 5 and touch and os.clock() >= nextTouch then
                    -- Only touch a pickup already reached by the character.
                    pcall(touch, actor.root, coin, 0)
                    task.wait(0.05)
                    pcall(touch, actor.root, coin, 1)
                    nextTouch = os.clock() + 0.4
                elseif not touch and os.clock() >= nextTouch then
                    -- A small physical pass through the pickup volume is the fallback.
                    local height = settings.Underground and -(move.pickupDepth or 1) + 0.3 or 1
                    travel(move, actor, coin, generation, coin.Position + Vector3.new(0.4, height, 0), 2)
                    nextTouch = os.clock() + 0.4
                end
                task.wait(0.05)
            end
        end
        if movement == move and not settings.Underground then cleanMove() end
        -- Leave a short acknowledgement grace period; disappearing alone is not success.
        if validRun(generation, actor) then task.wait(0.25) end
        if not validRun(generation, actor) then return end
        if (bags[id] and bags[id].count or 0) > before then
            retry[coin] = nil
            notify("Collected", "Bag updated by the game server")
        elseif coinInfo(coin) then
            local failures = (retry[coin] and retry[coin].failures or 0) + 1
            retry[coin] = { failures = failures, at = os.clock() + math.min(30, 3 * 2 ^ math.min(failures - 1, 4)) }
            state.missed += 1
            notify(reached and "Pickup not confirmed" or "Movement interrupted", "Skipping this target temporarily; trying another")
        else notify("Target disappeared", "Selecting a fresh pickup") end
        target = nil
        state.target, state.distance = "-", 0
    end
    connect(workspace.DescendantAdded, function(object)
        if object.Name == "CoinContainer" and (object:IsA("Model") or object:IsA("Folder")) then containers[object] = true end
    end)
    connect(workspace.DescendantRemoving, function(object)
        containers[object] = nil
        if object == target and movement and movement.tween then
            movement.tween:Cancel()
            movement.hold = CFrame.new(movement.root.Position) * movement.rotation
        end
    end)
    connect(player.CharacterRemoving, function()
        c.Generation += 1
        cleanMove()
        if c.Enabled then notify("Waiting for character", "Movement cleaned up for respawn") end
    end)
    connect(player:GetAttributeChangedSignal("Alive"), function()
        if not activeRound() then
            c.Generation += 1
            cleanMove()
            if c.Enabled then notify("Waiting for round", "The player is not active in this round") end
        end
    end)
    function c.Destroy()
        if not c.Alive then return end
        c.SetEnabled(false)
        c.Alive = false
        for _, connection in ipairs(connections) do connection:Disconnect() end
        table.clear(connections)
        if worker and worker ~= coroutine.running() then pcall(task.cancel, worker) end
        cleanMove()
    end
    c.Rescan()
    bindEvents()
    worker = task.spawn(function()
        while c.Alive do
            local ok, err = xpcall(function()
                if os.clock() - lastBind > 2 then lastBind = os.clock(); bindEvents() end
                syncRound()
                if c.Enabled then
                    if motionOwner then return end
                    if fullActionEnabled() and not resetForRound and not resetPending then
                        for id, bag in pairs(bags) do
                            if bag.full and bag.confirmed and (settings.Mode == "All" or settings.Mode == id) then resetPending = id; break end
                        end
                    end
                    if resetPending and fullActionEnabled() and not resetForRound then
                        local actor = characterReady()
                        if actor then
                            resetForRound = true
                            resetPending = nil
                            c.Generation += 1
                            cleanMove()
                            local generation = c.Generation
                            local handled, detail = false, nil
                            if options.OnFullBag then
                                notify("Bag full", "Checking role action")
                                handled, detail = options.OnFullBag(settings,function()
                                    return c.Alive and c.Enabled and generation==c.Generation and activeRound()
                                end)
                            end
                            if generation ~= c.Generation or not c.Enabled then return end
                            if handled then
                                roundAction = detail or "Role action completed"
                            elseif settings.ResetOnFull then
                                roundAction = "Full-bag reset complete"
                                state.resets += 1
                                notify("Bag full - resetting", "Full bag confirmed; waiting for the next round")
                                actor.humanoid.Health = 0
                            else roundAction = "Full bag reached; reset disabled" end
                        end
                    end
                    if resetForRound then
                        notify("Waiting for next round", roundAction .. "; auto collect stays enabled")
                        return
                    end
                    if os.clock() - lastScan > 8 then c.Rescan() end
                    local actor, reason = characterReady()
                    if actor then
                        local coin, id = choose(actor.root)
                        if coin then attempt(coin, id, actor) end
                    else cleanMove(false); state.target, state.distance = "-", 0; notify("Waiting", reason) end
                end
            end, debug.traceback)
            if not ok then
                cleanMove()
                c.Enabled = false
                c.Generation += 1
                state.lastError = tostring(err)
                notify("Error - paused", string.sub(tostring(err), 1, 180))
                warn("[Coin collector] " .. tostring(err))
            end
            task.wait(0.2)
        end
    end)
    -- Read-only helpers are kept for local regression tests.
    c.IsCollectible = function(coin) return coinInfo(coin) ~= nil end
    return c
end

-- Nyxthal: familiar settings layout with restrained color and readable type.
local AevryxLib = { Theme = { AccentColor = Color3.fromRGB(124, 162, 230), HideKey = "RightShift", ReducedMotion = false, Scale = 1 } }
function AevryxLib.Main(preferences)
    preferences=preferences or {}
    local TweenService = game:GetService("TweenService")
    local UIS = game:GetService("UserInputService")
    local palettes={
        Dark={bg={27,29,34},sidebar={23,25,29},surface={34,37,43},hover={44,48,56},line={67,72,83},text={235,237,242},muted={163,169,181},success={113,199,151}},
        Darker={bg={15,16,19},sidebar={11,12,15},surface={23,25,30},hover={34,37,44},line={54,59,70},text={235,237,242},muted={161,168,181},success={113,199,151}},
        Light={bg={244,245,247},sidebar={249,250,251},surface={255,255,255},hover={238,241,247},line={218,222,230},text={36,42,53},muted={108,116,131},success={42,128,78}},
    }
    local accents={Blue={{124,162,230},{66,105,187}},Lavender={{176,155,222},{112,82,171}},Green={{116,187,153},{44,123,89}},Amber={{220,178,104},{151,104,28}},Rose={{218,145,164},{167,69,100}},Slate={{170,184,205},{92,110,137}}}
    local themeName=palettes[preferences.Theme] and preferences.Theme or "Dark"
    local accentName=accents[preferences.Accent] and preferences.Accent or "Blue"
    local panelTransparency=math.clamp(tonumber(preferences.Transparency) or 0,0,25)/100
    local P={}
    local bindings=setmetatable({}, {__mode="k"})
    local themeListeners={}
    local activeTweens=setmetatable({}, {__mode="k"})
    local colorTweens=setmetatable({}, {__mode="k"})
    local panelTokens={bg=true,sidebar=true,surface=true,hover=true,selected=true}
    local function palette()
        for token,rgb in pairs(palettes[themeName]) do P[token]=Color3.fromRGB(table.unpack(rgb)) end
        P.accent=Color3.fromRGB(table.unpack(accents[accentName][themeName=="Light" and 2 or 1]))
        P.selected=P.sidebar:Lerp(P.accent,themeName=="Light" and .12 or .16)
        P.onAccent=Color3.fromRGB(249,250,255)
        AevryxLib.Theme.AccentColor=P.accent
        AevryxLib.Theme.SuccessColor=P.success
    end
    palette()
    local function bind(object,property,token)
        bindings[object]=bindings[object] or {}
        bindings[object][property]=token
        object[property]=P[token]
        if property=="BackgroundColor3" and panelTokens[token] then object.BackgroundTransparency=panelTransparency end
    end
    local function rememberColor(object,property,value)
        if typeof(value)~="Color3" then return false end
        for token,color in pairs(P) do if color==value then
            bindings[object]=bindings[object] or {};bindings[object][property]=token
            return true
        end end
        if bindings[object] then bindings[object][property]=nil end
        return false
    end
    local function make(class, properties, parent)
        local object = Instance.new(class)
        for key,value in pairs(properties or {}) do object[key] = value;rememberColor(object,key,value) end
        local token=bindings[object] and bindings[object].BackgroundColor3
        if token and panelTokens[token] and properties.BackgroundTransparency~=1 then object.BackgroundTransparency=panelTransparency end
        object.Parent = parent
        return object
    end
    local function corner(parent, radius) make("UICorner", {CornerRadius=UDim.new(0,radius or 8)}, parent) end
    local function stroke(parent, color) return make("UIStroke", {Color=color or P.line,Thickness=1,Transparency=0.25},parent) end
    local function label(parent, text, size, color, font)
        return make("TextLabel", {Name=text, BackgroundTransparency=1, Text=text, TextSize=size or 14,
            TextColor3=color or P.text, Font=font or Enum.Font.Gotham, TextXAlignment=Enum.TextXAlignment.Left,
            Size=UDim2.new(1,0,0,22), BorderSizePixel=0},parent)
    end
    local function animate(object, goals, duration)
        if activeTweens[object] then activeTweens[object]:Cancel() end
        local colored=false
        for property,value in pairs(goals) do if rememberColor(object,property,value) then colored=true end end
        if AevryxLib.Theme.ReducedMotion then for k,v in pairs(goals) do object[k]=v end; return end
        local tween=TweenService:Create(object,TweenInfo.new(duration or 0.16,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),goals)
        colorTweens[object]=colored and tween or nil
        activeTweens[object]=tween; tween:Play()
    end
    local gui=make("ScreenGui",{Name="NyxthalHub",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=90,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},game:GetService("CoreGui"))
    AevryxLib.ScreenGui=gui; HubRuntime.gui=gui
    local window=make("CanvasGroup",{Name="Window",AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),Size=UDim2.fromOffset(900,610),BackgroundColor3=P.bg,BorderSizePixel=0,GroupTransparency=1},gui)
    corner(window,14); stroke(window)
    local uiScale=make("UIScale",{Scale=1},window)
    local function resize()
        local camera=workspace.CurrentCamera
        local viewport=camera and camera.ViewportSize or Vector2.new(1280,720)
        uiScale.Scale=math.max(0.35,math.min(AevryxLib.Theme.Scale,(viewport.X-32)/900,(viewport.Y-32)/610))
        local half=Vector2.new(900,610)*uiScale.Scale/2
        local x=window.Position.X.Scale*viewport.X+window.Position.X.Offset
        local y=window.Position.Y.Scale*viewport.Y+window.Position.Y.Offset
        window.Position=UDim2.fromOffset(math.clamp(x,half.X+8,math.max(half.X+8,viewport.X-half.X-8)),math.clamp(y,half.Y+8,math.max(half.Y+8,viewport.Y-half.Y-8)))
    end
    resize()
    if workspace.CurrentCamera then HubConnect(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"),resize) end
    local sidebar=make("Frame",{Name="Sidebar",Size=UDim2.new(0,174,1,0),BackgroundColor3=P.sidebar,BorderSizePixel=0},window)
    make("Frame",{Position=UDim2.new(1,-1,0,0),Size=UDim2.new(0,1,1,0),BackgroundColor3=P.line,BorderSizePixel=0},sidebar)
    local wordmark=label(sidebar,"Nyxthal",22,P.text,Enum.Font.GothamBold)
    wordmark.Position=UDim2.fromOffset(22,26);wordmark.Size=UDim2.fromOffset(142,34)
    local edition=label(sidebar,"Game tools",12,P.muted)
    edition.Position=UDim2.fromOffset(23,61)
    local nav=make("Frame",{Name="Navigation",Position=UDim2.fromOffset(12,117),Size=UDim2.new(1,-24,0,340),BackgroundTransparency=1},sidebar)
    make("UIListLayout",{Padding=UDim.new(0,7),SortOrder=Enum.SortOrder.LayoutOrder},nav)
    local localName=game:GetService("Players").LocalPlayer.Name
    local user=label(sidebar,localName,14);user.Position=UDim2.new(0,22,1,-72);user.Size=UDim2.fromOffset(132,24);user.TextTruncate=Enum.TextTruncate.AtEnd
    local hideHint=label(sidebar,"Right Shift to hide",11,P.muted);hideHint.Position=UDim2.new(0,22,1,-44)
    local header=make("Frame",{Name="Header",Position=UDim2.fromOffset(174,0),Size=UDim2.new(1,-174,0,95),BackgroundTransparency=1,Active=true},window)
    local heading=label(header,"Auto collect",25,P.text,Enum.Font.GothamBold);heading.Position=UDim2.fromOffset(25,20);heading.Size=UDim2.new(1,-100,0,34)
    local subtitle=label(header,"Collect coins and candy with controls that fit your play style.",12,P.muted);subtitle.Position=UDim2.fromOffset(26,58);subtitle.Size=UDim2.new(1,-82,0,22)
    local close=make("TextButton",{Name="HideMenu",Text="−",Font=Enum.Font.Gotham,TextSize=24,TextColor3=P.muted,AutoButtonColor=false,Size=UDim2.fromOffset(36,34),Position=UDim2.new(1,-56,0,25),BackgroundColor3=P.bg,BorderSizePixel=0},header);corner(close)
    local openChip=make("TextButton",{Name="OpenMenu",Text="Nyxthal",Font=Enum.Font.GothamMedium,TextSize=14,TextColor3=P.text,AutoButtonColor=false,Size=UDim2.fromOffset(112,36),Position=UDim2.new(0,18,1,-58),BackgroundColor3=P.sidebar,Visible=false,BorderSizePixel=0},gui);corner(openChip);stroke(openChip)
    local content=make("Frame",{Name="Pages",Position=UDim2.fromOffset(198,96),Size=UDim2.new(1,-222,1,-150),BackgroundTransparency=1},window)
    local footer=make("Frame",{Name="StatusBar",Position=UDim2.new(0,174,1,-40),Size=UDim2.new(1,-174,0,40),BackgroundColor3=P.sidebar,BorderSizePixel=0},window)
    local dot=make("Frame",{Position=UDim2.fromOffset(23,17),Size=UDim2.fromOffset(6,6),BackgroundColor3=P.accent,BorderSizePixel=0},footer);corner(dot,6)
    local statusLabel=label(footer,"Collector stopped",12,P.muted);statusLabel.Position=UDim2.fromOffset(38,9);statusLabel.Size=UDim2.new(1,-52,0,22);statusLabel.TextTruncate=Enum.TextTruncate.AtEnd
    local toast=make("Frame",{Name="Notification",Visible=false,AnchorPoint=Vector2.new(1,1),Position=UDim2.new(1,-18,1,-18),Size=UDim2.fromOffset(360,82),BackgroundColor3=P.surface,BorderSizePixel=0,ZIndex=20},gui);corner(toast);stroke(toast,P.accent)
    local toastTitle=label(toast,"",14,P.accent);toastTitle.Position=UDim2.fromOffset(16,10);toastTitle.Size=UDim2.new(1,-32,0,22)
    local toastText=label(toast,"",13,P.text);toastText.Position=UDim2.fromOffset(16,34);toastText.Size=UDim2.new(1,-32,0,38);toastText.TextWrapped=true;toastText.TextYAlignment=Enum.TextYAlignment.Top
    local api={Pages={},Controls={},Window=window,Scale=uiScale}
    HubRuntime.UI=api
    local noticeId=0
    function api.Notification(title, text)
        noticeId+=1;local id=noticeId
        toastTitle.Text=tostring(title);toastText.Text=tostring(text);toast.Visible=true
        task.delay(4,function() if HubRuntime.alive and id==noticeId then toast.Visible=false end end)
    end
    function api.SetStatus(text) statusLabel.Text=text end
    api.BindColor=bind
    local function applyTheme()
        palette()
        for object,properties in pairs(bindings) do
            if object.Parent then
                if colorTweens[object] then colorTweens[object]:Cancel();colorTweens[object]=nil end
                for property,token in pairs(properties) do bind(object,property,token) end
            end
        end
        for _,render in ipairs(themeListeners) do render() end
    end
    function api.SetTheme(name)
        themeName=palettes[name] and name or "Dark";applyTheme();return themeName
    end
    function api.SetAccent(name)
        accentName=accents[name] and name or "Blue";applyTheme();return accentName
    end
    function api.SetTransparency(percent)
        panelTransparency=math.clamp(tonumber(percent) or 0,0,25)/100
        for object,properties in pairs(bindings) do
            if object.Parent and panelTokens[properties.BackgroundColor3] then object.BackgroundTransparency=panelTransparency end
        end
        return panelTransparency*100
    end
    function api.GetAppearance()
        return {Theme=themeName,Accent=accentName,Transparency=panelTransparency*100,Scale=AevryxLib.Theme.Scale,ReducedMotion=AevryxLib.Theme.ReducedMotion}
    end
    function api.Center() window.Position=UDim2.fromScale(.5,.5);resize() end
    function api.IsPointerOver()
        local inset=game:GetService("GuiService"):GetGuiInset()
        local point=UIS:GetMouseLocation()-inset
        local function inside(object)
            if not object.Visible then return false end
            local pos,size=object.AbsolutePosition,object.AbsoluteSize
            return point.X>=pos.X and point.X<=pos.X+size.X and point.Y>=pos.Y and point.Y<=pos.Y+size.Y
        end
        return inside(window) or inside(openChip)
    end
    function api.SetScale(value) AevryxLib.Theme.Scale=math.clamp(value,0.6,1.25);resize() end
    function api.SetMotion(reduced) AevryxLib.Theme.ReducedMotion=reduced==true end
    local visibilityRevision=0
    function api.SetVisible(value)
        visibilityRevision+=1;local rev=visibilityRevision
        openChip.Visible=not value
        if value then window.Visible=true;animate(window,{GroupTransparency=0},0.2)
        else
            animate(window,{GroupTransparency=1},0.14)
            task.delay(0.15,function() if HubRuntime.alive and rev==visibilityRevision then window.Visible=false end end)
        end
    end
    HubConnect(close.Activated,function() api.SetVisible(false) end)
    HubConnect(openChip.Activated,function() api.SetVisible(true) end)
    local drag, sliderDrag, binding
    local function clampWindow(x,y)
        local viewport=workspace.CurrentCamera.ViewportSize
        local half=window.AbsoluteSize/2
        return math.clamp(x,half.X+8,math.max(half.X+8,viewport.X-half.X-8)),
            math.clamp(y,half.Y+8,math.max(half.Y+8,viewport.Y-half.Y-8))
    end
    HubConnect(header.InputBegan,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            drag={input=input,start=input.Position,position=window.Position}
        end
    end)
    HubConnect(UIS.InputChanged,function(input)
        if sliderDrag and (input.UserInputType==Enum.UserInputType.MouseMovement or input==sliderDrag.input) then sliderDrag.move(input.Position.X) end
        if drag and (input.UserInputType==Enum.UserInputType.MouseMovement or input==drag.input) then
            local d=input.Position-drag.start
            local viewport=workspace.CurrentCamera.ViewportSize
            local x,y=clampWindow(drag.position.X.Scale*viewport.X+drag.position.X.Offset+d.X,drag.position.Y.Scale*viewport.Y+drag.position.Y.Offset+d.Y)
            window.Position=UDim2.fromOffset(x,y)
        end
    end)
    HubConnect(UIS.WindowFocusReleased,function()
        drag=nil
        if sliderDrag then local s=sliderDrag;sliderDrag=nil;s.finish() end
    end)
    HubConnect(UIS.InputEnded,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            drag=nil
            if sliderDrag and (input.UserInputType==Enum.UserInputType.MouseButton1 or input==sliderDrag.input) then local s=sliderDrag;sliderDrag=nil;s.finish() end
        end
    end)
    local function clearBinding(commit, key)
        local b=binding;binding=nil;HubRuntime.BindingKey=false
        if b then b.finish(commit,key) end
    end
    HubConnect(UIS.InputBegan,function(input,gp)
        if binding then
            HubRuntime.ConsumedKeyInput=input
            if input.KeyCode==Enum.KeyCode.Escape then clearBinding(false)
            elseif input.KeyCode~=Enum.KeyCode.Unknown then clearBinding(true,input.KeyCode.Name) end
            return
        end
        if gp or UIS:GetFocusedTextBox() or HubRuntime.BindingKey then return end
        if input.KeyCode.Name==AevryxLib.Theme.HideKey then api.SetVisible(not window.Visible or window.GroupTransparency>0.5) end
    end)
    local selected, pageNumber= nil,0
    local descriptions={Collect={"Auto collect","Movement, pickups and full-bag actions."},ESP={"Visuals","Player highlights and world visibility."},Combat={"Combat","Optional assistance. Normal weapon controls stay available."},Scripts={"Extensions","Open your additional tools."},Misc={"Utilities","Manage your current game session."},Settings={"Settings","Make the menu comfortable for you."}}
    function api.SelectTab(name)
        local tab=api.Pages[name];if not tab then return false end
        if selected==tab then return true end
        if selected then selected.frame.Visible=false;animate(selected.button,{BackgroundColor3=P.sidebar,TextColor3=P.muted});selected.marker.Visible=false end
        selected=tab;tab.frame.Visible=true;tab.frame.GroupTransparency=1
        animate(tab.frame,{GroupTransparency=0},0.18);animate(tab.button,{BackgroundColor3=P.selected,TextColor3=P.accent});tab.marker.Visible=false
        heading.Text=tab.title;subtitle.Text=tab.category
        return true
    end
    function api.Tab(name)
        pageNumber+=1
        local info=descriptions[name] or {name,string.upper(name)}
        local button=make("TextButton",{Name=name,Size=UDim2.new(1,0,0,42),Text=info[1],TextXAlignment=Enum.TextXAlignment.Left,Font=Enum.Font.GothamMedium,TextSize=14,TextColor3=P.muted,BackgroundColor3=P.sidebar,AutoButtonColor=false,BorderSizePixel=0,LayoutOrder=pageNumber},nav);corner(button,7)
        make("UIPadding",{PaddingLeft=UDim.new(0,13)},button)
        local marker=make("Frame",{Name="Active",Visible=false,Position=UDim2.new(0,-10,0.5,-8),Size=UDim2.fromOffset(3,16),BackgroundColor3=P.accent,BorderSizePixel=0},button);corner(marker,2)
        local page=make("CanvasGroup",{Name=name,Visible=false,BackgroundTransparency=1,Size=UDim2.fromScale(1,1)},content)
        local columns={}
        for index=1,2 do
            local column=make("ScrollingFrame",{Name="Column"..index,Position=UDim2.new((index-1)*0.5,index==2 and 8 or 0,0,0),Size=UDim2.new(0.5,-8,1,0),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=P.line,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y},page)
            make("UIPadding",{PaddingRight=UDim.new(0,7),PaddingBottom=UDim.new(0,12)},column)
            make("UIListLayout",{Padding=UDim.new(0,16),SortOrder=Enum.SortOrder.LayoutOrder},column)
            columns[index]=column
        end
        local tab={frame=page,button=button,marker=marker,title=info[1],category=info[2],number=pageNumber,sections=0}
        api.Pages[name]=tab
        HubConnect(button.Activated,function() api.SelectTab(name) end)
        if not selected then api.SelectTab(name) end
        local inPage={}
        function inPage.Section(text,side)
            tab.sections+=1;side=side or (tab.sections%2==1 and 1 or 2)
            local section=make("Frame",{Name=text,BackgroundColor3=P.surface,BorderSizePixel=0,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,LayoutOrder=tab.sections},columns[side]);corner(section,10);stroke(section)
            make("UIPadding",{PaddingTop=UDim.new(0,12),PaddingBottom=UDim.new(0,12),PaddingLeft=UDim.new(0,12),PaddingRight=UDim.new(0,12)},section)
            make("UIListLayout",{Padding=UDim.new(0,3),SortOrder=Enum.SortOrder.LayoutOrder},section)
            local title=label(section,text,14,P.text,Enum.Font.GothamMedium);title.LayoutOrder=0;title.Size=UDim2.new(1,0,0,27)
            local order=0
            local function row(name,height)
                order+=1
                local frame=make("Frame",{Name=name,Size=UDim2.new(1,0,0,height or 42),BackgroundColor3=P.surface,BorderSizePixel=0,LayoutOrder=order},section);corner(frame,7)
                return frame
            end
            local function register(text, kind, object)
                api.Controls[name.."/"..text]={kind=kind,object=object}
            end
            local function caption(parent,text,right)
                local l=label(parent,text,13)
                l.Position=UDim2.fromOffset(6,0);l.Size=UDim2.new(1,-(right or 14),1,0);l.TextWrapped=true
                return l
            end
            local controls={}
            function controls.TextLabel(text)
                order+=1;local l=label(section,text,13,P.muted);l.LayoutOrder=order;l.Size=UDim2.new(1,-2,0,26);l.TextWrapped=true
                return l
            end
            function controls.Button(text,callback)
                local frame=row(text)
                bind(frame,"BackgroundColor3","bg")
                local b=make("TextButton",{Text="",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,AutoButtonColor=false},frame)
                caption(frame,text,30);local arrow=label(frame,"›",20,P.muted);arrow.Position=UDim2.new(1,-22,0,0);arrow.Size=UDim2.new(0,16,1,0)
                HubConnect(b.MouseEnter,function() animate(frame,{BackgroundColor3=P.hover}) end)
                HubConnect(b.MouseLeave,function() animate(frame,{BackgroundColor3=P.bg}) end)
                HubConnect(b.Activated,function() HubSpawn(function() local ok,err=pcall(callback);if not ok then api.Notification(text,tostring(err)) end end) end)
                register(text,"Button",b);return b
            end
            function controls.Checkbox(text,callback,initial)
                local frame=row(text)
                caption(frame,text,66)
                local b=make("TextButton",{Text="",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,AutoButtonColor=false},frame)
                local track=make("Frame",{Position=UDim2.new(1,-49,0.5,-10),Size=UDim2.fromOffset(36,20),BackgroundColor3=P.line,BorderSizePixel=0},frame);corner(track,10)
                local thumb=make("Frame",{Position=UDim2.fromOffset(3,3),Size=UDim2.fromOffset(14,14),BackgroundColor3=P.muted,BorderSizePixel=0},track);corner(thumb,7)
                local value=make("BoolValue",{Name="IsActive",Value=initial==true},frame)
                local function render()
                    animate(track,{BackgroundColor3=value.Value and P.accent or P.line})
                    animate(thumb,{Position=UDim2.fromOffset(value.Value and 19 or 3,3),BackgroundColor3=value.Value and P.onAccent or P.muted})
                end
                table.insert(themeListeners,render)
                render()
                HubConnect(value.Changed,function(v) render();callback(v) end)
                HubConnect(b.Activated,function() value.Value=not value.Value end)
                local result={IsActive=value,Button=b};register(text,"Checkbox",result);return result
            end
            function controls.Slider(text,minimum,maximum,callback,precise,initial)
                local frame=row(text,65);local l=caption(frame,text,75);l.Size=UDim2.new(1,-85,0,32)
                local display=label(frame,"",12,P.muted);display.Position=UDim2.new(1,-70,0,5);display.Size=UDim2.fromOffset(58,24);display.TextXAlignment=Enum.TextXAlignment.Right
                local track=make("Frame",{Position=UDim2.fromOffset(12,47),Size=UDim2.new(1,-24,0,3),BackgroundColor3=P.line,BorderSizePixel=0},frame);corner(track,2)
                local fill=make("Frame",{Size=UDim2.fromScale(0,1),BackgroundColor3=P.accent,BorderSizePixel=0},track);corner(fill,2)
                local knob=make("Frame",{AnchorPoint=Vector2.new(0.5,0.5),Size=UDim2.fromOffset(12,12),BackgroundColor3=P.accent,BorderSizePixel=0},track);corner(knob,6)
                local value=math.clamp(tonumber(initial) or minimum,minimum,maximum)
                local function render() local t=(value-minimum)/(maximum-minimum);fill.Size=UDim2.fromScale(t,1);knob.Position=UDim2.fromScale(t,0.5);display.Text=tostring(value) end
                render()
                local hit=make("TextButton",{Text="",BackgroundTransparency=1,Position=UDim2.new(0,0,0,30),Size=UDim2.new(1,0,0,35),AutoButtonColor=false},frame)
                HubConnect(hit.InputBegan,function(input)
                    if input.UserInputType~=Enum.UserInputType.MouseButton1 and input.UserInputType~=Enum.UserInputType.Touch then return end
                    local function move(x) local t=math.clamp((x-track.AbsolutePosition.X)/math.max(track.AbsoluteSize.X,1),0,1);local n=minimum+t*(maximum-minimum);value=precise and math.floor(n*100+0.5)/100 or math.floor(n+0.5);render() end
                    sliderDrag={input=input,move=move,finish=function() callback(value) end};move(input.Position.X)
                end)
                local result={Set=function(v) value=math.clamp(tonumber(v) or minimum,minimum,maximum);render();callback(value) end}
                register(text,"Slider",result);return result
            end
            function controls.Dropdown(text,values,_,callback)
                local frame=row(text,42)
                local b=make("TextButton",{Text="",BackgroundTransparency=1,Size=UDim2.new(1,0,0,42),AutoButtonColor=false},frame)
                local textLabel=caption(b,text,26)
                local list=make("Frame",{Name="Options",Visible=false,Position=UDim2.fromOffset(6,45),Size=UDim2.new(1,-12,0,0),BackgroundTransparency=1},frame)
                make("UIListLayout",{Padding=UDim.new(0,3),SortOrder=Enum.SortOrder.LayoutOrder},list)
                local choices={};for k,v in pairs(values) do table.insert(choices,{label=tostring(k),value=v}) end
                table.sort(choices,function(a,b) return a.label<b.label end)
                local selectedValue
                local function set(v,call)
                    for _,option in ipairs(choices) do if option.value==v then selectedValue=v;textLabel.Text=text.."  ·  "..option.label;if call then callback(option.label,v) end;return end end
                end
                local function expand(v) list.Visible=v;frame.Size=UDim2.new(1,0,0,v and (50+#choices*32) or 42) end
                for i,option in ipairs(choices) do
                    local item=make("TextButton",{Name=option.label,Text=option.label,TextSize=13,Font=Enum.Font.Gotham,TextColor3=P.text,Size=UDim2.new(1,0,0,29),BackgroundColor3=P.hover,AutoButtonColor=true,BorderSizePixel=0,LayoutOrder=i},list);corner(item,5)
                    HubConnect(item.Activated,function() set(option.value,true);expand(false) end)
                end
                HubConnect(b.Activated,function() expand(not list.Visible) end)
                if choices[1] then set(choices[1].value,false) end
                local result={Set=function(v) set(v,true) end,Expand=expand};register(text,"Dropdown",result);return result
            end
            function controls.KeyBind(text,callback,initial)
                local frame=row(text);caption(frame,text,100)
                local key=initial or "H"
                local b=make("TextButton",{Text=key,Font=Enum.Font.Gotham,TextSize=11,TextColor3=P.muted,Size=UDim2.fromOffset(88,28),Position=UDim2.new(1,-96,0.5,-14),BackgroundColor3=P.bg,AutoButtonColor=false,BorderSizePixel=0},frame);corner(b,5)
                HubConnect(b.Activated,function()
                    if binding then clearBinding(false) end
                    b.Text="PRESS KEY";HubRuntime.BindingKey=true
                    local owner={finish=function(commit,nextKey) if commit then key=nextKey;callback(key) end;b.Text=key end};binding=owner
                    task.delay(8,function() if HubRuntime.alive and binding==owner then clearBinding(false) end end)
                end)
                register(text,"KeyBind",b);return b
            end
            return controls
        end
        return inPage
    end
    HubSpawn(function()
        while HubRuntime.alive do hideHint.Text=AevryxLib.Theme.HideKey.." to hide";task.wait(1) end
    end)
    table.insert(HubRuntime.cleanup,function() for _,t in pairs(activeTweens) do t:Cancel() end end)
    animate(window,{GroupTransparency=0},0.25)
    return api
end

-- Observe the same player-data stream as the game's round UI. Never require game modules.
local function CreateRoundTracker()
    local players = game:GetService("Players")
    local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
    local gameplay = remotes and remotes:FindFirstChild("Gameplay")
    local tracker = { Alive=true, Epoch=0, Active=nil, Data={}, DataKnown=false, Source="Player attribute", Mode="Classic" }
    local connections, pending, revision = {}, nil, 0
    local function connect(name, callback)
        local remote = gameplay and gameplay:FindFirstChild(name)
        if remote and remote:IsA("RemoteEvent") then table.insert(connections,remote.OnClientEvent:Connect(callback)) end
    end
    local function begin(source)
        revision+=1
        if tracker.Active ~= true then
            tracker.Epoch+=1
            tracker.Data={}
            tracker.DataKnown=false
        end
        tracker.Active=true
        tracker.Source=source
    end
    local function update(data)
        if type(data)~="table" or tracker.Active==false then return end
        revision+=1
        tracker.Data=data
        tracker.DataKnown=true
        tracker.Source="Round player data"
        for _,record in pairs(data) do
            if type(record)=="table" and record.Dead==false then
                if tracker.Active~=true then tracker.Epoch+=1 end
                tracker.Active=true
                break
            end
        end
    end
    connect("LoadingMap",function() revision+=1;tracker.Active=false;tracker.Data={};tracker.Source="Loading map" end)
    connect("RoundStart",function(_,data) begin("Round started");update(data) end)
    connect("CoinsStarted",function() begin("Coin round started") end)
    connect("PlayerDataChanged",update)
    connect("GameOver",function() revision+=1;tracker.Active=false;tracker.Data={};tracker.Source="Round ended" end)
    connect("RoundEndFade",function() revision+=1;tracker.Active=false;tracker.Data={};tracker.Source="Round ended" end)
    function tracker.IsActive(p)
        p=p or players.LocalPlayer
        if tracker.Active==false then return false end
        local record=tracker.Data[p.Name]
        if type(record)=="table" and type(record.Dead)=="boolean" then return record.Dead==false end
        if tracker.DataKnown and record==nil then return false end
        return p:GetAttribute("Alive")==true
    end
    function tracker.GetRole(p)
        local record=tracker.Data[(p or players.LocalPlayer).Name]
        return type(record)=="table" and record.Role or nil
    end
    function tracker.GetSnapshot()
        tracker.Mode=workspace:GetAttribute("GameMode") or "Classic"
        for _,record in pairs(tracker.Data) do
            if type(record)=="table" and (record.Role=="Survivor" or record.Role=="Zombie") then
                tracker.Mode="Infection"
                break
            end
        end
        return {active=tracker.IsActive(),mode=tracker.Mode,source=tracker.Source,epoch=tracker.Epoch}
    end
    local current = gameplay and gameplay:FindFirstChild("GetCurrentPlayerData")
    if current and current:IsA("RemoteFunction") then
        -- One bounded startup request; subsequent state comes from pushed events.
        local requestRevision = revision
        pending=task.spawn(function()
            local ok,data=pcall(function() return current:InvokeServer() end)
            if tracker.Alive and revision==requestRevision and ok then update(data) end
            pending=nil
        end)
        task.delay(5,function() if pending then pcall(task.cancel,pending);pending=nil end end)
    end
    function tracker.Destroy()
        tracker.Alive=false
        for _,connection in ipairs(connections) do connection:Disconnect() end
        if pending then pcall(task.cancel,pending);pending=nil end
    end
    return tracker
end

-- Gun assistance follows normal input; never require or patch shared game modules.
local function CreateCombatController(options)
    local Players = game:GetService("Players")
    local player = Players.LocalPlayer
    local RunService = game:GetService("RunService")
    local settings = options.Settings
    local c = { Alive = true, Busy = false, Revision = 0, Status = "Ready", AimStatus = "Not installed", Requests = 0,
        AcceptedShots = 0, TargetHits = 0, InputStatus = "No shot input yet" }
    local active, lastShot = nil, -10
    local pendingShot, observedLatency
    local aimWorker, inputRelease, inputJob
    local inputConnections = {}
    local input = options.InputService
    local actions = options.ActionService or game:GetService("ContextActionService")
    local actionName = "NyxthalGunAim_" .. tostring(c)
    local actionBound = false
    local function inRound(p)
        if options.Round then return options.Round.IsActive(p) end
        return p:GetAttribute("Alive") == true
    end
    local function status(message)
        c.Status = message
        if options.OnStatus then options.OnStatus(message) end
    end
    local function actor(p)
        if not p or not inRound(p) then return end
        local ch = p.Character
        local h = ch and ch:FindFirstChildOfClass("Humanoid")
        local r = ch and ch:FindFirstChild("HumanoidRootPart")
        if h and r and h.Health > 0 and not r.Anchored then return ch, h, r end
    end
    local function isEliminated(p)
        local record=options.Round and options.Round.Data and options.Round.Data[p.Name]
        if type(record)=="table" and record.Dead==true then return true end
        local h=p.Character and p.Character:FindFirstChildOfClass("Humanoid")
        return h~=nil and h.Health<=0
    end
    local function tool(p, name)
        local ch, backpack = p.Character, p:FindFirstChild("Backpack")
        local t = (ch and ch:FindFirstChild(name)) or (backpack and backpack:FindFirstChild(name))
        if t and t:IsA("Tool") then return t end
    end
    function c.GetRole(p)
        p = p or player
        if not actor(p) then return "Inactive" end
        local role = options.Round and options.Round.GetRole(p)
        if role then
            if role=="Hero" or (role=="Innocent" and tool(p,"Gun")) then return "Sheriff" end
            return role
        end
        if tool(p, "Knife") then return "Murderer" end
        if tool(p, "Gun") then return "Sheriff" end
        return "Innocent"
    end
    function c.GetMurderer()
        for _, p in ipairs(Players:GetPlayers()) do if p ~= player and c.GetRole(p) == "Murderer" then return p end end
    end
    function c.GetTarget(weapon)
        if weapon == "Gun" then return c.GetMurderer() end
        local _, _, root = actor(player)
        if not root then return end
        local best, distance
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= player then
                local _, _, r = actor(p)
                local d = r and (r.Position - root.Position).Magnitude
                if d and (not distance or d < distance) then best, distance = p, d end
            end
        end
        return best
    end
    local function latency()
        local ok, ping = pcall(function() return player:GetNetworkPing() end)
        if not ok or type(ping) ~= "number" or ping ~= ping or ping < 0 then ping = 0.1 end
        return math.clamp(observedLatency or ping, 0.02, 0.6)
    end
    local function prediction(root, weapon)
        local lead = math.clamp(tonumber(settings.Lead) or 0.035, 0, 0.15)
        if weapon == "Gun" and settings.AutoLead ~= false then lead = math.clamp(latency() * 0.5 + 0.015, 0.025, 0.15) end
        if weapon == "Knife" then lead = math.max(lead, 0.08) end
        local velocity = root.AssemblyLinearVelocity
        if velocity.Magnitude ~= velocity.Magnitude or velocity.Magnitude > 100 then return Vector3.zero, 0 end
        local offset = velocity * lead
        -- Avoid aiming several body widths away after jumps, knockback, or a latency spike.
        offset = Vector3.new(offset.X, math.clamp(offset.Y, -0.8, 0.8), offset.Z)
        if offset.Magnitude > 2 then offset = offset.Unit * 2 end
        return offset, lead
    end
    function c.TargetCFrame(target, weapon)
        local ch, _, r = actor(target)
        if not r then return end
        local part = ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso") or r
        return CFrame.new(part.Position + prediction(r, weapon))
    end
    local function weaponRay(origin, destination, character)
        local ignore = {character}
        local collection = game:GetService("CollectionService")
        if collection then for _, item in ipairs(collection:GetTagged("WeaponPassthrough")) do table.insert(ignore, item) end end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = ignore
        for _ = 1, 24 do
            local hit = workspace:Raycast(origin, destination - origin, params)
            if not hit or not hit.Instance or hit.Instance.Transparency ~= 1 then return hit end
            table.insert(ignore, hit.Instance)
            params.FilterDescendantsInstances = ignore
        end
        return {Instance = workspace} -- Too many layers: do not assume a clear shot.
    end
    local function clearPath(origin, destination, character, targetCharacter)
        local hit = weaponRay(origin, destination, character)
        return not hit or (hit.Instance and hit.Instance:IsDescendantOf(targetCharacter)), hit
    end
    function c.SolveShot(target, origin, character)
        local ch, _, r = actor(target)
        if not r then return nil, "Target is no longer active" end
        if (r.Position - origin.Position).Magnitude > 300 then return nil, "Target is beyond gun range" end
        local offset, lead = prediction(r, "Gun")
        local head = character:FindFirstChild("Head")
        if head and not clearPath(head.Position, origin.Position, character, ch) then return nil, "Gun muzzle is blocked" end
        -- Prefer the largest body parts; use the head only when the torso is obstructed.
        for _, name in ipairs({"UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart", "Head"}) do
            local part = ch:FindFirstChild(name)
            if part and part:IsA("BasePart") then
                local point = part.Position + offset
                if clearPath(origin.Position, point, character, ch) then return CFrame.new(point), nil, lead, name end
            end
        end
        return nil, "No clear shot at the murderer"
    end
    local function finish(context)
        if not context or context.finished then return end
        context.finished = true
        if context.step then context.step:Disconnect() end
        pcall(function()
            if player.Character == context.character and context.root.Parent and context.humanoid.Health > 0
                and inRound(player) and context.moved then
                context.root.CFrame = context.origin
                context.root.AssemblyLinearVelocity = context.velocity
                context.root.AssemblyAngularVelocity = Vector3.zero
            end
            if context.humanoid.Parent then context.humanoid.AutoRotate = context.autoRotate end
        end)
        if context.release then context.release() end
        if active == context then active = nil; c.Busy = false end
    end
    function c.Cancel()
        c.Revision += 1
        finish(active)
        if inputRelease then inputRelease() end
        status("Cancelled")
    end
    local function begin(fromCollector)
        if not c.Alive or c.Busy or (options.IsMovementBusy and options.IsMovementBusy()) then return nil, "Another action is running" end
        local ch, h, r = actor(player)
        if not ch then return nil, "Waiting for an active round" end
        local release
        local collector = options.GetCollector()
        if collector and not fromCollector then
            release = collector.AcquireMovement()
            if not release then return nil, "Movement is busy" end
        end
        local context = { character = ch, humanoid = h, root = r, origin = r.CFrame,
            velocity = r.AssemblyLinearVelocity, autoRotate = h.AutoRotate, release = release,
            revision = c.Revision, moved = false }
        active, c.Busy = context, true
        return context
    end
    local function valid(context)
        return c.Alive and active == context and not context.finished and context.revision == c.Revision
            and player.Character == context.character and context.humanoid.Health > 0 and inRound(player)
    end
    local function equip(context, weapon)
        local t = tool(player, weapon)
        if not t then return nil, weapon .. " is not owned" end
        if t:GetAttribute("Disabled") == true then return nil, weapon .. " is disabled" end
        local newlyEquipped = t.Parent ~= context.character
        if newlyEquipped then context.humanoid:EquipTool(t) end
        local deadline = os.clock() + 0.8
        repeat
            if not valid(context) then return nil, "Cancelled" end
            if t.Parent == context.character then return t, nil, newlyEquipped end
            task.wait(0.03)
        until os.clock() > deadline
        return nil, "Weapon did not equip"
    end
    local function moveBehind(context, target, attachment)
        local _, _, targetRoot = actor(target)
        if not valid(context) or not targetRoot then return false, "Target is no longer active" end
        local look = Vector3.new(targetRoot.CFrame.LookVector.X, 0, targetRoot.CFrame.LookVector.Z)
        if look.Magnitude < 0.01 then look = Vector3.new(0, 0, -1) else look = look.Unit end
        -- Some gun skins place the ray origin over 3 studs ahead of the root.
        local muzzleForward = math.max(0, -attachment.Position.Z)
        local distance = math.clamp(muzzleForward + 4.5, 7, 12)
        local position = targetRoot.Position - look * distance
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = {context.character, target.Character}
        if workspace:Raycast(targetRoot.Position, position - targetRoot.Position, params) then
            return false, "Behind-target position is blocked"
        end
        context.humanoid.AutoRotate = false
        context.moved = true
        context.root.CFrame = CFrame.lookAt(position, targetRoot.Position)
        context.root.AssemblyLinearVelocity = Vector3.zero
        -- Keep the body steady while the shot's origin replicates.
        if not context.step then context.step = RunService.PreSimulation:Connect(function()
            if valid(context) then context.root.AssemblyLinearVelocity = Vector3.zero; context.root.AssemblyAngularVelocity = Vector3.zero end
        end) end
        task.wait(math.max(math.clamp(tonumber(settings.BlinkDelay) or 0.1, 0.06, 0.25), math.clamp(latency()*0.5+0.05,0.1,0.3)))
        return valid(context) and actor(target) ~= nil, "Target changed before firing"
    end
    function c.ShootMurderer(fromCollector, shotMode)
        if c.GetRole() ~= "Sheriff" then status("A live gun is required"); return false, c.Status end
        if os.clock() - lastShot < 2.6 then status("Gun cooldown"); return false, c.Status end
        local target = c.GetMurderer()
        if not target then status("No active murderer found"); return false, c.Status end
        local context, reason = begin(fromCollector)
        if not context then status(reason); return false, reason end
        local sent, shot = false, nil
        local ok, err = xpcall(function()
            local gun, why, newlyEquipped = equip(context, "Gun")
            if not gun then error(why, 0) end
            if newlyEquipped then task.wait(math.clamp(latency()*0.5+0.02,0.05,0.2)) end
            local remote = gun:FindFirstChild("Shoot")
            if not remote or not remote:IsA("RemoteEvent") then error("Unsupported gun: Shoot remote missing") end
            local deadline = os.clock() + 0.6
            local attachment = context.root:FindFirstChild("GunRaycastAttachment")
            while not attachment and os.clock() < deadline and valid(context) do
                task.wait(0.03); attachment = context.root:FindFirstChild("GunRaycastAttachment")
            end
            if not attachment then error("Gun origin attachment unavailable") end
            if (shotMode or settings.ShotMode) == "Blink" then
                local moved, message = moveBehind(context, target, attachment)
                if not moved then error(message, 0) end
            end
            if not valid(context) then error("Shot cancelled; character changed") end
            local origin = attachment.WorldCFrame
            local aim, aimError, lead, bodyPart = c.SolveShot(target, origin, context.character)
            if not aim then error(aimError, 0) end
            if gun.Parent ~= context.character or gun:GetAttribute("Disabled") == true then error("Gun is no longer ready") end
            shot = {SentAt=os.clock(),Origin=origin.Position,Aim=aim.Position,Target=target.Name,
                TargetCharacter=target.Character,Gun=gun,Accepted=false,HitTarget=false,Lead=lead,BodyPart=bodyPart}
            pendingShot, c.LastShot = shot, shot
            remote:FireServer(origin, aim)
            lastShot, sent = os.clock(), true
            c.Requests += 1
            status("Shot sent; waiting for game result")
            local deadline = os.clock() + math.clamp(latency()*2 + 0.2, 0.45, 1)
            while valid(context) and not shot.Accepted and not isEliminated(target) and os.clock()<deadline do task.wait(0.02) end
        end, debug.traceback)
        finish(context)
        if not ok then status(tostring(err):match("^[^\n]+")); return false, c.Status end
        if sent then
            local message
            if isEliminated(target) then message="Murderer eliminated"
            elseif shot.HitTarget then message="Server confirmed target contact"
            elseif shot.Accepted then message="Shot accepted; hit " .. (shot.HitName or "no target")
            else message="Shot sent; server acknowledgement unconfirmed" end
            shot.Result=message
            if c.Alive and context.revision==c.Revision then status(message) end
            return true, message
        end
        return sent, c.Status
    end
    function c.KillAll(fromCollector)
        if c.GetRole() ~= "Murderer" then status("A live knife is required"); return false, c.Status end
        local context, reason = begin(fromCollector)
        if not context then status(reason); return false, reason end
        local sent, eliminated = 0, 0
        local ok, err = xpcall(function()
            local knife, why = equip(context, "Knife")
            if not knife then error(why) end
            local events = knife:FindFirstChild("Events")
            local stab = events and events:FindFirstChild("KnifeStabbed")
            local touch = events and events:FindFirstChild("HandleTouched")
            if not stab or not touch or not stab:IsA("RemoteEvent") or not touch:IsA("RemoteEvent") then error("Unsupported knife events") end
            for _, target in ipairs(Players:GetPlayers()) do
                if not valid(context) then break end
                if target ~= player then
                    local _, _, r = actor(target)
                    if r then
                        stab:FireServer()
                        task.wait(0.05)
                        if valid(context) and actor(target) then
                            touch:FireServer(r)
                            sent += 1
                            c.Requests += 1
                            status("Kill All: " .. sent .. " requests sent")
                            task.wait(0.85)
                            if isEliminated(target) then eliminated += 1 end
                        end
                    end
                end
            end
        end, debug.traceback)
        finish(context)
        if not ok then status(tostring(err):match("^[^\n]+")); return false, c.Status end
        status("Kill All: " .. eliminated .. "/" .. sent .. " eliminations observed")
        return sent > 0, c.Status
    end
    function c.FullBag(collectorSettings, stillValid)
        local role = c.GetRole()
        if role == "Murderer" and collectorSettings.MurdererOnFull then
            c.KillAll(true)
            return true, c.Status
        elseif role == "Sheriff" and collectorSettings.SheriffOnFull then
            local revision, deadline = c.Revision, os.clock()+4
            local function canContinue()
                return c.Alive and revision==c.Revision and actor(player)~=nil
                    and collectorSettings.SheriffOnFull and (not stillValid or stillValid())
            end
            while canContinue() and (c.Busy or os.clock()-lastShot<2.7) and os.clock()<deadline do
                status("Full bag: waiting for gun cooldown")
                task.wait(0.1)
            end
            if not canContinue() then return true,"Full-bag shot cancelled" end
            local _, message = c.ShootMurderer(true)
            return true, message
        end
        return false
    end
    function c.RefreshAim()
        local ch = actor(player)
        local gun = ch and ch:FindFirstChild("Gun")
        local enabled = c.Alive and options.IsSilentEnabled()
        local mouseInput = not input or input.PreferredInput == Enum.PreferredInput.KeyboardAndMouse
        if not enabled or not mouseInput or not gun or c.GetRole()~="Sheriff" or not c.GetMurderer() then
            c.AimStatus = enabled and "Waiting for an equipped gun and murderer" or "Off · native weapon controls"
            return
        end
        if not actionBound then c.AimStatus="Input assist unavailable · native controls active";return end
        if gun.ManualActivationOnly and not inputRelease then c.AimStatus="Another controller owns this gun";return end
        c.AimStatus="On · left-click to aim; normal shooting remains available"
    end
    local function pointerOverGameUI()
        if input and input:GetFocusedTextBox() then return true end
        if options.IsUIBlocking and options.IsUIBlocking() then return true end
        local guiService=game:GetService("GuiService")
        if guiService and guiService.MenuIsOpen then return true end
        if not input or not input.GetMouseLocation or not guiService then return false end
        local point=input:GetMouseLocation()-guiService:GetGuiInset()
        for _,container in ipairs({player:FindFirstChild("PlayerGui"),game:GetService("CoreGui")}) do
            local ok,objects=pcall(function() return container:GetGuiObjectsAtPosition(point.X,point.Y) end)
            if ok then for _,object in ipairs(objects) do
                if object.Active and (object:IsA("GuiButton") or object:IsA("TextBox") or object:IsA("ScrollingFrame")) then return true end
            end end
        end
        return false
    end
    function c.HandlePrimaryInput(processed)
        if processed then c.InputStatus="Click used by game UI";return false end
        if input and input:GetFocusedTextBox() then c.InputStatus="Typing in a text box";return false end
        if not c.Alive or not options.IsSilentEnabled() or not actionBound then return false end
        if pointerOverGameUI() then c.InputStatus="Click used by menu";return false end
        if input and input.PreferredInput~=Enum.PreferredInput.KeyboardAndMouse then return false end
        if inputRelease then c.InputStatus="Waiting for current shot";return true end
        local character,_,root=actor(player)
        local gun=character and character:FindFirstChild("Gun")
        local target=c.GetMurderer()
        if not gun or not target or c.GetRole()~="Sheriff" or gun.ManualActivationOnly then
            c.InputStatus="Normal weapon controls";return false
        end
        if c.Busy or (options.IsMovementBusy and options.IsMovementBusy()) or os.clock()-lastShot<2.6 then
            c.InputStatus="Gun cooldown or action busy · normal controls";return false
        end
        local mode=settings.ClickMode=="Blink" and "Blink" or "Redirect"
        local attachment=root:FindFirstChild("GunRaycastAttachment")
        if not attachment then c.InputStatus="Gun not ready · normal controls";return false end
        if mode=="Redirect" then
            local aim,why=c.SolveShot(target,attachment.WorldCFrame,character)
            if not aim then c.InputStatus=why .. " · normal shot";return false end
        end
        -- Only suppress native activation for this accepted click, never while idle.
        local revision=c.Revision
        local released=false
        local function release()
            if released then return end
            released=true
            pcall(function() gun.ManualActivationOnly=false end)
            if inputRelease==release then inputRelease=nil end
        end
        inputRelease=release
        local locked,lockError=pcall(function() gun.ManualActivationOnly=true end)
        if not locked then release();c.InputStatus="Native controls: "..tostring(lockError);return false end
        c.InputStatus="Aiming at murderer"
        inputJob=task.spawn(function()
            if released or not c.Alive or c.Revision~=revision then release();return end
            local before=c.Requests
            local ok,sent,message=pcall(c.ShootMurderer,false,mode)
            if not ok then finish(active) end
            if not ok or not sent then task.wait() end
            release()
            if c.Alive and revision==c.Revision then
                c.InputStatus=ok and message or "Aim failed · normal shot"
                if (not ok or not sent) and c.Requests==before and gun.Parent==player.Character and not c.Busy then
                    pcall(function() gun:Activate() end)
                end
            end
        end)
        task.delay(1.8,function()
            if not released then
                local stalledJob=inputJob
                c.Cancel()
                if stalledJob and stalledJob~=coroutine.running() then pcall(task.cancel,stalledJob) end
                c.InputStatus="Aim timed out · native controls restored"
            end
        end)
        return true
    end
    function c.InstallAim() c.RefreshAim();return true end
    function c.Destroy()
        c.Cancel()
        c.Alive = false
        if actionBound then pcall(function() actions:UnbindAction(actionName) end);actionBound=false end
        for _, connection in ipairs(inputConnections) do connection:Disconnect() end
        if inputJob and inputJob~=coroutine.running() then pcall(task.cancel,inputJob) end
        if aimWorker and aimWorker ~= coroutine.running() then pcall(task.cancel,aimWorker) end
    end
    -- Observe accepted native shots so a full bag cannot race the normal gun cooldown.
    -- Reading a RemoteEvent child does not execute its parent ModuleScript.
    local services=game:GetService("ReplicatedStorage"):FindFirstChild("ClientServices")
    local weaponService=services and services:FindFirstChild("WeaponService")
    local fired=weaponService and weaponService:FindFirstChild("GunFired")
    if fired and fired:IsA("RemoteEvent") then
        table.insert(inputConnections,fired.OnClientEvent:Connect(function(handle, origin, destination, hit)
            if typeof(handle)=="Instance" and player.Character and handle:IsDescendantOf(player.Character) then
                lastShot=os.clock()
                local shot=pendingShot
                if shot and not shot.Accepted and os.clock()-shot.SentAt<=1.5 and handle:IsDescendantOf(shot.Gun)
                    and typeof(origin)=="Vector3" and (origin-shot.Origin).Magnitude<=6 then
                    shot.Accepted=true
                    shot.ResponseTime=os.clock()-shot.SentAt
                    observedLatency=math.clamp(shot.ResponseTime,0.02,0.6)
                    shot.ServerOrigin,shot.ServerDestination=origin,destination
                    shot.HitTarget=typeof(hit)=="Instance" and hit:IsDescendantOf(shot.TargetCharacter)
                    shot.HitName=typeof(hit)=="Instance" and hit.Name or nil
                    c.AcceptedShots+=1
                    if shot.HitTarget then c.TargetHits+=1 end
                end
            end
        end))
    end
    if input then
        local bound=pcall(function()
            actions:BindActionAtPriority(actionName,function(_,state)
                if state~=Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
                local ok,handled=pcall(c.HandlePrimaryInput,false)
                if not ok then c.Cancel();c.InputStatus="Aim error · native controls active";return Enum.ContextActionResult.Pass end
                return handled and Enum.ContextActionResult.Sink or Enum.ContextActionResult.Pass
            end,false,Enum.ContextActionPriority.High.Value+1,Enum.UserInputType.MouseButton1)
        end)
        actionBound=bound
        aimWorker=task.spawn(function()
            while c.Alive do
                local ok,err=pcall(c.RefreshAim)
                if not ok then c.AimStatus="Unavailable · native controls active: "..tostring(err) end
                task.wait(0.15)
            end
        end)
    end
    c.RefreshAim()
    return c
end


-- ============================
-- MM2 HUB LOGIC (integrated)
-- ============================
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local UIS = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- PERSISTENCE
local SETTINGS_FILE = "mm2_hub_settings.json"

local function safeReadSettings()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then
        return {}
    end
    local ok, data = pcall(function()
        if not isfile(SETTINGS_FILE) then return {} end
        return HttpService:JSONDecode(readfile(SETTINGS_FILE))
    end)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

local function safeWriteSettings(tbl)
    if type(writefile) ~= "function" then return end
    pcall(function()
        local json = HttpService:JSONEncode(tbl)
        writefile(SETTINGS_FILE, json)
    end)
end

local saved = safeReadSettings()
local function SafeKey(value, fallback)
    local ok, key = pcall(function() return Enum.KeyCode[tostring(value)] end)
    return ok and key and key ~= Enum.KeyCode.Unknown and key or Enum.KeyCode[fallback]
end
local CollectorKey = SafeKey(saved.CollectorKey, "H")

-- USER SETTINGS (load from file)
local HotkeyKey = SafeKey(saved.HotkeyKey, "RightShift")
local WaitingForKey = false

local XrayKey = SafeKey(saved.XrayKey, "X")
local WaitingForXrayKey = false

local AutoGrabKey = SafeKey(saved.AutoGrabKey, "G")
local WaitingForAutoGrabKey = false

local SilentAimKey = SafeKey(saved.SilentAimKey, "V")
local WaitingForSilentAimKey = false

local KillAllKey = SafeKey(saved.KillAllKey, "L")
local WaitingForKillAllKey = false

-- TOGGLES
local ChamsESPEnabled = saved.ChamsESPEnabled ~= false
local RoleESPEnabled = saved.RoleESPEnabled ~= false
local GunESPEnabled = saved.GunESPEnabled ~= false
local XrayEnabled = saved.XrayEnabled == true
local AutoGrabEnabled = saved.AutoGrabEnabled == true
local SilentAimEnabled = saved.InputAssistVersion == 2 and saved.SilentAimEnabled == true

local CombatSettings = type(saved.Combat) == "table" and saved.Combat or {}
CombatSettings.ShotMode = CombatSettings.ShotMode == "Blink" and "Blink" or "Redirect"
CombatSettings.ClickMode = CombatSettings.ClickMode == "Blink" and "Blink" or "Redirect"
CombatSettings.AutoLead = CombatSettings.AutoLead ~= false
CombatSettings.Lead = math.clamp(tonumber(CombatSettings.Lead) or 0.035, 0, 0.15)
CombatSettings.BlinkDelay = math.clamp(tonumber(CombatSettings.BlinkDelay) or 0.1, 0.06, 0.25)
local MenuSettings = type(saved.Menu) == "table" and saved.Menu or {Scale=1,ReducedMotion=false}
MenuSettings.Theme=({Dark=true,Darker=true,Light=true})[MenuSettings.Theme] and MenuSettings.Theme or "Dark"
MenuSettings.Accent=({Blue=true,Lavender=true,Green=true,Amber=true,Rose=true,Slate=true})[MenuSettings.Accent] and MenuSettings.Accent or "Blue"
MenuSettings.Transparency=math.clamp(tonumber(MenuSettings.Transparency) or 0,0,25)
local CollectorSettings = type(saved.Collector) == "table" and saved.Collector or { Speed = 24, Range = 600, Mode = "All", Noclip = true }
local function SaveAllSettings()
    safeWriteSettings({
        HotkeyKey = HotkeyKey.Name,
        CollectorKey = CollectorKey.Name,
        XrayKey = XrayKey.Name,
        AutoGrabKey = AutoGrabKey.Name,
        SilentAimKey = SilentAimKey.Name,
        KillAllKey = KillAllKey.Name,
        ChamsESPEnabled = ChamsESPEnabled,
        RoleESPEnabled = RoleESPEnabled,
        GunESPEnabled = GunESPEnabled,
        XrayEnabled = XrayEnabled,
        AutoGrabEnabled = AutoGrabEnabled,
        SilentAimEnabled = SilentAimEnabled,
        InputAssistVersion = 2,
        Collector = CollectorSettings,
        Combat = CombatSettings,
        Menu = MenuSettings,
    })
end

-- ROLE CACHE
local RoleCache = {}

-- REMOVE FUNCTIONS
local function RemoveChamsESP()
    for _,player in pairs(Players:GetPlayers()) do
        if player.Character then
            local esp = player.Character:FindFirstChild("ChamsESP")
            if esp then esp:Destroy() end
        end
    end
end

local function RemoveGunESP()
    for _,v in pairs(workspace:GetDescendants()) do
        if v.Name == "GunESP" then
            v:Destroy()
        end
    end
end

-- XRAY
local xrayCache = {}
local xrayConn

local function IsPlayerPart(part)
    for _,p in pairs(Players:GetPlayers()) do
        if p.Character and part:IsDescendantOf(p.Character) then
            return true
        end
    end
    return false
end

local function ApplyXrayToPart(part)
    if not part:IsA("BasePart") then return end
    if IsPlayerPart(part) then return end
    if xrayCache[part] == nil then
        xrayCache[part] = part.LocalTransparencyModifier
    end
    part.LocalTransparencyModifier = 0.65
end

local function EnableXray()
    for _,v in pairs(workspace:GetDescendants()) do
        ApplyXrayToPart(v)
    end
    if xrayConn then xrayConn:Disconnect() end
    xrayConn = HubConnect(workspace.DescendantAdded, function(v)
        ApplyXrayToPart(v)
    end)
end

local function DisableXray()
    if xrayConn then xrayConn:Disconnect() end
    xrayConn = nil
    for part,old in pairs(xrayCache) do
        if part and part.Parent then
            part.LocalTransparencyModifier = old
        end
    end
    xrayCache = {}
end

table.insert(HubRuntime.cleanup, DisableXray)
table.insert(HubRuntime.cleanup, RemoveChamsESP)
table.insert(HubRuntime.cleanup, RemoveGunESP)

-- ROLE DETECTION
local function ParseRoleText(t)
    t = (t or ""):lower()
    if t:find("murder") then return "Murderer" end
    if t:find("sheriff") then return "Sheriff" end
    if t:find("innocent") then return "Innocent" end
    return nil
end

local function SetLocalRole(role)
    if role then
        RoleCache[LocalPlayer] = role
    end
end

local HookedRoleLabels = setmetatable({}, { __mode = "k" })
local function HookRoleLabel(lbl)
    if not lbl or not lbl:IsA("TextLabel") or not lbl.Parent or lbl.Parent.Name ~= "RoleSelector" or HookedRoleLabels[lbl] then return end
    HookedRoleLabels[lbl] = true
    local role = ParseRoleText(lbl.Text)
    if role then SetLocalRole(role) end
    HubConnect(lbl:GetPropertyChangedSignal("Text"), function()
        local r = ParseRoleText(lbl.Text)
        if r then SetLocalRole(r) end
    end)
end

local function ScanRoleLabel()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    for _,d in ipairs(pg:GetDescendants()) do
        if d.Name == "Role" and d:IsA("TextLabel") then
            HookRoleLabel(d)
        end
    end
end

local function HookPlayerGui()
    local pg = LocalPlayer:WaitForChild("PlayerGui", 10)
    if not pg then return end

    HubConnect(pg.DescendantAdded, function(d)
        if d.Name == "Role" and d:IsA("TextLabel") then
            HookRoleLabel(d)
        end
    end)

    ScanRoleLabel()
end

HookPlayerGui()
HubConnect(LocalPlayer.CharacterAdded, function()
    task.wait(0.5)
    ScanRoleLabel()
end)

local function GetMurdererV1()
    for _,v in pairs(Players:GetPlayers()) do
        if v.Character and (v.Character:FindFirstChild("Knife") or (v:FindFirstChild("Backpack") and v.Backpack:FindFirstChild("Knife"))) then
            return v
        end
    end
end

local function GetSheriffV1()
    for _,v in pairs(Players:GetPlayers()) do
        if v.Character and (v.Character:FindFirstChild("Gun") or (v:FindFirstChild("Backpack") and v.Backpack:FindFirstChild("Gun"))) then
            return v
        end
    end
end

local function ResolveRoleFromCache(char)
    for plr,role in pairs(RoleCache) do
        if plr.Character == char then
            return role
        end
    end
    return nil
end

local function GetRoleColor(char)
    if RoleESPEnabled then
        local cached = ResolveRoleFromCache(char)
        if cached == "Murderer" then
            return Color3.fromRGB(255,60,60)
        elseif cached == "Sheriff" then
            return Color3.fromRGB(80,150,255)
        end

        local murderer = GetMurdererV1()
        local sheriff = GetSheriffV1()
        if murderer and char == murderer.Character then
            return Color3.fromRGB(255,60,60)
        elseif sheriff and char == sheriff.Character then
            return Color3.fromRGB(80,150,255)
        end
    end
    return Color3.fromRGB(0,255,0)
end

-- CHAMS
local function ApplyChams(char,color)
    if not ChamsESPEnabled or not char then return end

    local existing = char:FindFirstChild("ChamsESP")
    if existing then
        existing.FillColor = color
        existing.OutlineColor = color
        return
    end

    local h = Instance.new("Highlight")
    h.Name = "ChamsESP"
    h.FillTransparency = 0.75
    h.OutlineTransparency = 0.25
    h.FillColor = color
    h.OutlineColor = color
    h.Parent = char
end

-- GUN ESP
local function CreateGunESP(gun)
    if not GunESPEnabled then return end
    if gun:FindFirstChild("GunESP") then return end

    local highlight = Instance.new("Highlight")
    highlight.Name = "GunESP"
    highlight.FillColor = Color3.fromRGB(170,120,255)
    highlight.FillTransparency = 0.7
    highlight.OutlineTransparency = 0.2
    highlight.Parent = gun

    local billboard = Instance.new("BillboardGui",gun)
    billboard.Name = "GunESP"
    billboard.Size = UDim2.new(0,120,0,20)
    billboard.StudsOffset = Vector3.new(0,2,0)
    billboard.AlwaysOnTop = true

    local text = Instance.new("TextLabel",billboard)
    text.Size = UDim2.new(1,0,1,0)
    text.BackgroundTransparency = 1
    text.Text = "Gun Dropped"
    text.TextColor3 = Color3.fromRGB(210,190,255)
    text.Font = Enum.Font.GothamBold
    text.TextScaled = true
    text.TextStrokeTransparency = 0
end

HubConnect(workspace.DescendantAdded, function(obj)
    if obj.Name == "GunDrop" and obj:IsA("BasePart") and GunESPEnabled then
        CreateGunESP(obj)
    end
end)

local function ScanGunESP()
    if not GunESPEnabled then return end
    for _, object in ipairs(workspace:GetDescendants()) do
        if object.Name == "GunDrop" and object:IsA("BasePart") then CreateGunESP(object) end
    end
end
ScanGunESP()

-- AUTO-GRAB LOOP
HubSpawn(function()
    while task.wait(0.1) do
        if not AutoGrabEnabled or (HubRuntime.Collector and HubRuntime.Collector.Enabled) or (HubRuntime.Combat and HubRuntime.Combat.Busy) then continue end
        local char = LocalPlayer.Character
        if not char then continue end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end

        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 or LocalPlayer:GetAttribute("Alive") ~= true then continue end
        local gun = workspace:FindFirstChild("GunDrop", true)
        if not gun then continue end

        local target = gun:IsA("BasePart") and gun or gun:FindFirstChildWhichIsA("BasePart")
        if not target then continue end

        HubRuntime.AutoGrabBusy = true
        local originalCFrame = hrp.CFrame
        hrp.CFrame = target.CFrame + Vector3.new(0,2,0)
        task.wait(0.2)
        if HubRuntime.alive and LocalPlayer.Character == char and hrp.Parent and hum.Health > 0 and not (HubRuntime.Collector and HubRuntime.Collector.Enabled) then hrp.CFrame = originalCFrame end
        HubRuntime.AutoGrabBusy = false
    end
end)

-- SILENT AIM (advanced, safely wrapped)
local Round = CreateRoundTracker()
HubRuntime.Round = Round
table.insert(HubRuntime.cleanup, Round.Destroy)
local UI
local Combat = CreateCombatController({Settings=CombatSettings, Round=Round, InputService=UIS,
    IsSilentEnabled=function() return SilentAimEnabled end,
    IsUIBlocking=function() return UI and UI.IsPointerOver() end,
    GetCollector=function() return HubRuntime.Collector end,
    IsMovementBusy=function() return HubRuntime.AutoGrabBusy == true end,
})
HubRuntime.Combat = Combat
table.insert(HubRuntime.cleanup, Combat.Destroy)
HubConnect(LocalPlayer.CharacterRemoving, Combat.Cancel)
HubConnect(LocalPlayer:GetAttributeChangedSignal("Alive"), function()
    if not Round.IsActive() then Combat.Cancel() end
end)
local function killAll() HubSpawn(function() Combat.KillAll(false) end) end

-- ============================
-- BUILD UI WITH AevryxLib
-- ============================
UI = AevryxLib.Main(MenuSettings)
UI.SetScale(tonumber(MenuSettings.Scale) or 1)
UI.SetMotion(MenuSettings.ReducedMotion == true)

-- Set the initial hide key from saved settings
AevryxLib["Theme"]["HideKey"] = HotkeyKey.Name

-- COLLECT TAB
local collectTab = UI.Tab("Collect")
local collectControls = collectTab.Section("Collection", 1)
local movementControls = collectTab.Section("Movement", 1)
local collectActions = collectTab.Section("Quick actions", 1)
local fullBagControls = collectTab.Section("When the bag is full", 2)
local collectStatus = collectTab.Section("Current session", 2)
local collectorToggle
local phaseLabel = collectStatus.TextLabel("Stopped")
phaseLabel.TextColor3 = AevryxLib.Theme.AccentColor
phaseLabel.TextSize = 18
phaseLabel.Font = Enum.Font.GothamMedium
local detailLabel = collectStatus.TextLabel("Enable Auto collect to begin")
detailLabel.TextWrapped = true
detailLabel.Size = UDim2.new(0.95, 0, 0, 48)
detailLabel.TextYAlignment = Enum.TextYAlignment.Top
local countLabel = collectStatus.TextLabel("Confirmed: 0")
local availableLabel = collectStatus.TextLabel("Available: 0")
local bagLabel = collectStatus.TextLabel("Bag: waiting for round")
local targetLabel = collectStatus.TextLabel("Target: -")
local mapLabel = collectStatus.TextLabel("Map: -")
local roundLabel = collectStatus.TextLabel("Round: waiting")
roundLabel.TextWrapped=true
roundLabel.Size=UDim2.new(1,-2,0,40)
local attemptsLabel = collectStatus.TextLabel("Attempts: 0 / Missed: 0")
local resetsLabel = collectStatus.TextLabel("Full-bag resets: 0")
local actionLabel = collectStatus.TextLabel("Round action: none")
local methodLabel = collectStatus.TextLabel("Pickup: detecting runtime")
for _, label in ipairs({ targetLabel, mapLabel, bagLabel }) do label.TextTruncate = Enum.TextTruncate.AtEnd end

local function RenderCollector(snapshot)
    if not HubRuntime.alive then return end
    phaseLabel.Text = snapshot.phase
    UI.BindColor(phaseLabel,"TextColor3",snapshot.phase == "Collected" and "success" or "accent")
    detailLabel.Text = snapshot.detail
    countLabel.Text = "Confirmed: " .. snapshot.confirmed
    availableLabel.Text = "Available: " .. snapshot.available
    targetLabel.Text = "Target: " .. snapshot.target .. (snapshot.distance > 0 and (" / " .. snapshot.distance .. " studs") or "")
    mapLabel.Text = "Map: " .. snapshot.map
    if snapshot.round then roundLabel.Text="Round: "..snapshot.round.mode.." · "..(snapshot.round.active and "Playing" or "Waiting") end
    attemptsLabel.Text = "Attempts: " .. snapshot.attempts .. " / Missed: " .. snapshot.missed
    resetsLabel.Text = "Full-bag resets: " .. snapshot.resets
    actionLabel.Text = "Round action: " .. (snapshot.roundAction ~= "" and snapshot.roundAction or "none")
    actionLabel.TextWrapped = true
    actionLabel.Size = UDim2.new(1, 0, 0, 42)
    UI.SetStatus(snapshot.phase .. " · " .. snapshot.confirmed .. " pickups · " .. Combat.GetRole())
    methodLabel.Text = snapshot.touch and "Pickup: touch + server confirmation" or "Pickup: natural touch"
    methodLabel.TextSize = 11
    local amounts = {}
    for id, bag in pairs(snapshot.bags) do
        if CollectorSettings.Mode == "All" or id == CollectorSettings.Mode then
            table.insert(amounts, id .. " " .. tostring(bag.count) .. (bag.capacity and ("/" .. bag.capacity) or "") .. (bag.full and " FULL" or ""))
        end
    end
    table.sort(amounts)
    bagLabel.Text = "Bag: " .. (#amounts > 0 and table.concat(amounts, ", ") or "waiting for round")
    if collectorToggle and collectorToggle.IsActive.Value ~= snapshot.enabled then
        collectorToggle.IsActive.Value = snapshot.enabled
    end
end
local Collector = CreateCoinCollector({ Settings = CollectorSettings, OnStatus = RenderCollector, Round = Round,
    OnFullBag = Combat.FullBag,
    OnStop = Combat.Cancel,
    OnRound = function() Combat.Cancel(); table.clear(RoleCache) end,
})
HubRuntime.Collector = Collector
CollectorSettings = Collector.Settings
collectorToggle = collectControls.Checkbox("Auto collect", function(enabled)
    if enabled then
        AutoGrabEnabled = false
        if HubRuntime.AutoGrabControl then HubRuntime.AutoGrabControl.IsActive.Value = false end
    end
    Collector.SetEnabled(enabled)
end, false)
local filters = collectControls.Dropdown("Pickups", { All = "All", Coins = "Coin", Candy = "Candy" }, 1, function(_, value)
    Collector.SetOption("Mode", value)
    SaveAllSettings()
end)
filters.Set(CollectorSettings.Mode)
movementControls.Slider("Travel speed", 10, 60, function(value)
    Collector.SetOption("Speed", value)
    SaveAllSettings()
end, false, CollectorSettings.Speed)
collectControls.Slider("Search radius", 50, 1500, function(value)
    Collector.SetOption("Range", value)
    SaveAllSettings()
end, false, CollectorSettings.Range)
movementControls.Checkbox("Pass through obstacles", function(value)
    Collector.SetOption("Noclip", value)
    SaveAllSettings()
end, CollectorSettings.Noclip)
movementControls.Checkbox("Underground, face up", function(value)
    Collector.SetOption("Underground", value)
    SaveAllSettings()
end, CollectorSettings.Underground)
movementControls.Slider("Travel depth", 3, 16, function(value)
    Collector.SetOption("Depth", value)
    SaveAllSettings()
end, false, CollectorSettings.Depth)
fullBagControls.Checkbox("Reset character", function(value)
    Collector.SetOption("ResetOnFull", value)
    SaveAllSettings()
end, CollectorSettings.ResetOnFull)
fullBagControls.Checkbox("Murderer: use Kill All", function(value)
    Collector.SetOption("MurdererOnFull", value)
    SaveAllSettings()
end, CollectorSettings.MurdererOnFull)
fullBagControls.Checkbox("Sheriff: shoot murderer", function(value)
    Collector.SetOption("SheriffOnFull", value)
    SaveAllSettings()
end, CollectorSettings.SheriffOnFull)
local fullNote = fullBagControls.TextLabel("With Auto collect on, the selected role action replaces reset at a full bag. Runs once per round.")
fullNote.Size = UDim2.new(1, -2, 0, 56)
local fullBagPlan = fullBagControls.TextLabel("Auto collect is off")
fullBagPlan.Size = UDim2.new(1,-2,0,36)
UI.BindColor(fullBagPlan,"TextColor3","accent")
local function RenderFullBagPlan()
    local role=Combat.GetRole()
    local action=role=="Murderer" and CollectorSettings.MurdererOnFull and "Use Kill All"
        or role=="Sheriff" and CollectorSettings.SheriffOnFull and "Shoot murderer"
        or CollectorSettings.ResetOnFull and "Reset character" or "Wait for next round"
    fullBagPlan.Text=Collector.Enabled and ("At full bag: "..action) or "Auto collect is off"
end
collectControls.KeyBind("Collect hotkey", function(key)
    CollectorKey = SafeKey(key, "H")
    SaveAllSettings()
end, CollectorKey.Name)
collectActions.Button("Skip current pickup", Collector.SkipTarget)
collectActions.Button("Rescan spawns", function() Collector.Rescan() end)
collectActions.Button("Stop collecting", function() Collector.SetEnabled(false) end)
collectStatus.Button("Reset session stats", Collector.ResetStats)
collectStatus.TextLabel("Counted from server bag updates").TextSize = 11
local belowNote = collectStatus.TextLabel("Lies flat on your back below the floor; rises only enough to touch. Visibility depends on the map.")
belowNote.TextSize = 11
belowNote.TextWrapped = true
belowNote.Size = UDim2.new(0.95, 0, 0, 44)
RenderCollector(Collector.GetSnapshot())
HubConnect(AevryxLib.ScreenGui.Destroying, HubRuntime.Destroy)


-- ESP TAB
local espTab = UI.Tab("ESP")
local espSection = espTab.Section("Player ESP")
-- Chams ESP
espSection.Checkbox("Chams ESP", function(val)
    ChamsESPEnabled = val
    if not val then RemoveChamsESP() end
    SaveAllSettings()
end, ChamsESPEnabled)

-- Role Detection
espSection.Checkbox("Role Detection", function(val)
    RoleESPEnabled = val
    SaveAllSettings()
end, RoleESPEnabled)

-- World ESP section
local worldSection = espTab.Section("World ESP")
-- Gun ESP
worldSection.Checkbox("Gun ESP", function(val)
    GunESPEnabled = val
    if val then ScanGunESP() else RemoveGunESP() end
    SaveAllSettings()
end, GunESPEnabled)

-- Xray Toggle
HubRuntime.XrayControl = worldSection.Checkbox("Xray", function(val)
    XrayEnabled = val
    if XrayEnabled then EnableXray() else DisableXray() end
    SaveAllSettings()
end, XrayEnabled)

-- Xray Hotkey
worldSection.KeyBind("Xray Hotkey", function(key)
    XrayKey = SafeKey(key, "X")
    SaveAllSettings()
end, XrayKey.Name)

-- COMBAT TAB
local combatTab = UI.Tab("Combat")
local autoSection = combatTab.Section("Gun recovery", 2)
HubRuntime.AutoGrabControl = autoSection.Checkbox("Auto Grab Gun", function(val)
    if val then Collector.SetEnabled(false) end
    AutoGrabEnabled = val
    SaveAllSettings()
end, AutoGrabEnabled)

autoSection.KeyBind("Auto Grab Hotkey", function(key)
    AutoGrabKey = SafeKey(key, "G")
    SaveAllSettings()
end, AutoGrabKey.Name)

local silentSection = combatTab.Section("Aim assistance", 1)
HubRuntime.SilentControl = silentSection.Checkbox("Gun aim assist", function(val)
    SilentAimEnabled = val
    Combat.Cancel()
    Combat.RefreshAim()
    SaveAllSettings()
end, SilentAimEnabled)

silentSection.KeyBind("Aim assist hotkey", function(key)
    SilentAimKey = SafeKey(key, "V")
    SaveAllSettings()
end, SilentAimKey.Name)

local clickMode = silentSection.Dropdown("On left-click", { ["Aim from here"]="Redirect", ["Blink behind"]="Blink" }, 1, function(_,value)
    CombatSettings.ClickMode=value;SaveAllSettings()
end)
clickMode.Set(CombatSettings.ClickMode)
silentSection.Checkbox("Automatic target prediction", function(value) CombatSettings.AutoLead=value;SaveAllSettings() end, CombatSettings.AutoLead)
local aimMode = silentSection.Dropdown("Button / full-bag shot", { ["Aim from here"]="Redirect", ["Blink behind"]="Blink" }, 1, function(_,value)
    CombatSettings.ShotMode=value
    SaveAllSettings()
end)
aimMode.Set(CombatSettings.ShotMode)
silentSection.Slider("Manual lead (auto off)", 0, 0.15, function(value) CombatSettings.Lead=value;SaveAllSettings() end, true, CombatSettings.Lead)
silentSection.Slider("Blink settle (seconds)", 0.06, 0.25, function(value) CombatSettings.BlinkDelay=value;SaveAllSettings() end, true, CombatSettings.BlinkDelay)
local aimNote = silentSection.TextLabel("Aim from here needs a clear path. Blink allows room for the muzzle and waits briefly for shot feedback before returning.")
aimNote.Size = UDim2.new(1,-2,0,62)
local actionSection = combatTab.Section("Sheriff action", 1)
actionSection.Button("Shoot murderer now", function() Combat.ShootMurderer(false) end)
actionSection.Button("Cancel combat action", Combat.Cancel)
local diagnosticSection = combatTab.Section("Action status", 2)
local aimStatusLabel = diagnosticSection.TextLabel(Combat.AimStatus)
aimStatusLabel.Size = UDim2.new(1,-2,0,44)
local actionStatusLabel = diagnosticSection.TextLabel("Ready")
actionStatusLabel.Size = UDim2.new(1,-2,0,62)
local roleStatusLabel = diagnosticSection.TextLabel("Role: waiting")
local inputStatusLabel = diagnosticSection.TextLabel(Combat.InputStatus)
inputStatusLabel.Size = UDim2.new(1,-2,0,62)
local shotCountLabel = diagnosticSection.TextLabel("Shots: 0 accepted / 0 target contacts")
diagnosticSection.Button("Refresh aim assist", function() Combat.RefreshAim();UI.Notification("Aim assistance", Combat.AimStatus) end)
HubSpawn(function()
    while HubRuntime.alive do
        aimStatusLabel.Text=Combat.AimStatus
        actionStatusLabel.Text=Combat.Status
        roleStatusLabel.Text="Role: " .. Combat.GetRole() .. "  /  Requests: " .. Combat.Requests
        inputStatusLabel.Text=Combat.InputStatus
        shotCountLabel.Text="Shots: " .. Combat.AcceptedShots .. " accepted / " .. Combat.TargetHits .. " target contacts"
        RenderFullBagPlan()
        RenderCollector(Collector.GetSnapshot())
        task.wait(0.4)
    end
end)
local killSection = combatTab.Section("Murderer action", 2)
killSection.KeyBind("Kill All Hotkey", function(key)
    KillAllKey = SafeKey(key, "L")
    SaveAllSettings()
end, KillAllKey.Name)

-- Optionally, a button to kill all (for convenience)
killSection.Button("Kill All Now", function()
    killAll()
end)

-- [修改4] 新增 "Scripts" 标签页
local scriptsTab = UI.Tab("Scripts")

local function LoadExternalScript(label, url)
    HubSpawn(function()
        local ok, err = pcall(function()
            local source = game:HttpGet(url)
            if type(source) ~= "string" or source == "" then error("Empty script response") end
            local fn, compileError = loadstring(source, label)
            if not fn then error(compileError) end
            fn()
        end)
        if not ok then UI.Notification(label, string.sub(tostring(err), 1, 180)) end
    end)
end
-- 创建一个分区来容纳加载按钮
local loadSection = scriptsTab.Section("Load Scripts")

-- 第一个按钮: Ultimate Fling GUI
loadSection.Button("Load Fling Script", function()
    LoadExternalScript("Fling script", "https://raw.githubusercontent.com/K1LAS1K/Ultimate-Fling-GUI/main/flingscript.lua")
end)

-- 第二个按钮: Infinite Yield
loadSection.Button("Load Infinite Yield", function()
    LoadExternalScript("Infinite Yield", "https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source")
end)

-- MISC TAB
local miscTab = UI.Tab("Misc")
miscTab.Section("Utilities").Button("Rejoin Server", function()
    TeleportService:Teleport(game.PlaceId, LocalPlayer)
end)

-- SETTINGS TAB (for GUI hotkey)
local settingsTab = UI.Tab("Settings")
local appearance = settingsTab.Section("Appearance", 1)
local themeControl=appearance.Dropdown("Theme",{Dark="Dark",Darker="Darker",Light="Light"},1,function(_,value)
    MenuSettings.Theme=UI.SetTheme(value);SaveAllSettings()
end)
themeControl.Set(MenuSettings.Theme)
local accentControl=appearance.Dropdown("Accent",{Blue="Blue",Lavender="Lavender",Green="Green",Amber="Amber",Rose="Rose",Slate="Slate"},1,function(_,value)
    MenuSettings.Accent=UI.SetAccent(value);SaveAllSettings()
end)
accentControl.Set(MenuSettings.Accent)
local transparencyControl=appearance.Slider("Panel transparency (%)",0,25,function(value)
    MenuSettings.Transparency=UI.SetTransparency(value);SaveAllSettings()
end,false,MenuSettings.Transparency)
local appearanceNote=appearance.TextLabel("Changes apply immediately and save automatically.")
appearanceNote.Size=UDim2.new(1,-2,0,42)
local layoutSection=settingsTab.Section("Layout & motion",2)
local scaleControl=layoutSection.Slider("Interface scale (%)", 60, 125, function(value)
    MenuSettings.Scale=value/100;UI.SetScale(MenuSettings.Scale);SaveAllSettings()
end, false, math.floor((tonumber(MenuSettings.Scale) or 1)*100))
local motionControl=layoutSection.Checkbox("Reduce motion", function(value) MenuSettings.ReducedMotion=value;UI.SetMotion(value);SaveAllSettings() end, MenuSettings.ReducedMotion)
layoutSection.Button("Center menu",UI.Center)
layoutSection.Button("Reset appearance",function()
    themeControl.Set("Dark");accentControl.Set("Blue");transparencyControl.Set(0);scaleControl.Set(100)
    motionControl.IsActive.Value=false;MenuSettings.ReducedMotion=false;UI.SetMotion(false);UI.Center();SaveAllSettings()
end)
local menuSection = settingsTab.Section("Session controls", 2)
menuSection.Button("Stop all automation", function()
    Collector.SetEnabled(false);Combat.Cancel();HubRuntime.AutoGrabControl.IsActive.Value=false;HubRuntime.SilentControl.IsActive.Value=false
end)
menuSection.Button("Unload menu", HubRuntime.Destroy)
settingsTab.Section("GUI Hotkey").KeyBind("GUI Toggle", function(key)
    HotkeyKey = SafeKey(key, "RightShift")
    AevryxLib["Theme"]["HideKey"] = key  -- update the library's hide key
    SaveAllSettings()
end, HotkeyKey.Name)

-- ============================
-- HOTKEY HANDLING (global)
-- ============================
HubConnect(UIS.InputBegan, function(i, gp)
    if gp then return end

    if UIS:GetFocusedTextBox() or HubRuntime.BindingKey or HubRuntime.ConsumedKeyInput == i then return end
    if i.KeyCode == CollectorKey then
        collectorToggle.IsActive.Value = not collectorToggle.IsActive.Value
        return
    end
    -- Xray toggle via its own hotkey
    if i.KeyCode == XrayKey then
        HubRuntime.XrayControl.IsActive.Value = not HubRuntime.XrayControl.IsActive.Value
    end

    if i.KeyCode == AutoGrabKey then
        AutoGrabEnabled = not AutoGrabEnabled
        if AutoGrabEnabled then Collector.SetEnabled(false) end
        if HubRuntime.AutoGrabControl then HubRuntime.AutoGrabControl.IsActive.Value = AutoGrabEnabled end
        SaveAllSettings()
    end

    if i.KeyCode == SilentAimKey then
        HubRuntime.SilentControl.IsActive.Value = not HubRuntime.SilentControl.IsActive.Value
    end

    if i.KeyCode == KillAllKey then
        killAll()
    end
end)

-- ============================
-- PLAYER ESP LOOP
-- ============================
HubSpawn(function()
    while task.wait(0.4) do
        if not ChamsESPEnabled then continue end
        for _,player in pairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                local color = GetRoleColor(player.Character)
                ApplyChams(player.Character,color)
            end
        end
    end
end)

-- ============================
-- PLAYER ADDED / REMOVED
-- ============================
local function OnPlayerAdded(player)
    if player == LocalPlayer then return end
    HubConnect(player:GetAttributeChangedSignal("Alive"), function() if player:GetAttribute("Alive") ~= true then RoleCache[player] = nil end end)
    HubConnect(player.CharacterAdded, function(char)
        RoleCache[player] = nil
        if ChamsESPEnabled and char then
            local color = GetRoleColor(char)
            ApplyChams(char, color)
        end
    end)
    if player.Character then
        local color = GetRoleColor(player.Character)
        ApplyChams(player.Character, color)
    end
end

HubConnect(Players.PlayerAdded, OnPlayerAdded)
for _, player in pairs(Players:GetPlayers()) do
    if player ~= LocalPlayer then
        OnPlayerAdded(player)
    end
end

HubConnect(Players.PlayerRemoving, function(player)
    RoleCache[player] = nil
    if player.Character then
        local esp = player.Character:FindFirstChild("ChamsESP")
        if esp then esp:Destroy() end
    end
end)

-- ============================
-- INITIAL STATE
-- ============================
if XrayEnabled then
    EnableXray()
end

-- 提示加载成功
print("Nyxthal Hub loaded successfully!")