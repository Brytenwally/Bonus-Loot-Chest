-- =============================================================================
-- BossLootChest.lua  –  AzerothCore | Eluna LUA Engine (ALE)
-- Version: 6.0.0 (Verbose Debug Mode)
-- =============================================================================

------------------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------------------
local CFG = {
    CHEST_ENTRY       = 2843,   -- GO entry
    CHEST_DESPAWN_SEC = 300,      -- seconds

    MIN_ITEM_ID  = 91000,
    MAX_ITEM_ID  = 5000000,

    MIN_ITEMS = 1,
    MAX_ITEMS = 3,

    MIN_QUALITY = 2,
    MAX_QUALITY = 4,

    CHANCE_UNCOMMON = 50,
    CHANCE_RARE     = 35,
    CHANCE_EPIC     = 15,

    -- Tight range: boss level -5 to +0
    LEVEL_BELOW_TIGHT = 5,
    LEVEL_ABOVE_TIGHT = 0,
    -- Wide fallback: boss level -10 to +3
    LEVEL_BELOW_WIDE  = 10,
    LEVEL_ABOVE_WIDE  = 3,

    ALLOWED_CLASSES = { [2] = true, [4] = true },

    -- Cooldown in ms to prevent double-spawns from multiple kill credits
    SPAWN_COOLDOWN_MS = 100,

    DEBUG = true,
}

------------------------------------------------------------------------
-- Cooldown tracker  { [bossGuid] = true }
------------------------------------------------------------------------
local recentlySpawned = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local GO_NOT_READY = 0
local GO_READY     = 1
local QUALITY_COLOR = { [2]="1eff00", [3]="0070dd", [4]="a335ee" }

local CLASS_IN
do
    local parts = {}
    for cls in pairs(CFG.ALLOWED_CLASSES) do parts[#parts+1] = tostring(cls) end
    CLASS_IN = table.concat(parts, ",")
end

local function dbg(msg)
    if CFG.DEBUG then print("[BossLootChest DEBUG] " .. tostring(msg)) end
end

local function rollQuality()
    local rawW = { [2]=CFG.CHANCE_UNCOMMON, [3]=CFG.CHANCE_RARE, [4]=CFG.CHANCE_EPIC }
    local pool, total = {}, 0
    for q = CFG.MIN_QUALITY, CFG.MAX_QUALITY do
        local w = rawW[q] or 0
        if w > 0 then pool[#pool+1] = {quality=q, weight=w}; total = total+w end
    end
    if total == 0 then return CFG.MIN_QUALITY end
    local roll, cum = math.random(1, total), 0
    for _, e in ipairs(pool) do
        cum = cum + e.weight
        if roll <= cum then return e.quality end
    end
    return pool[#pool].quality
end

-- Armor subclass 4 = Plate. Excluded for bosses below level 40.
local ARMOR_CLASS    = 4   -- item_template.class = 4 means Armor
local PLATE_SUBCLASS = 4   -- item_template.subclass = 4 means Plate

local function queryItemEntries(quality, levelMin, levelMax, bossLevel)
    -- Build an optional extra filter to block plate armour for low-level bosses.
    local plateFilter = ""
    if bossLevel < 40 then
        -- Exclude rows that are Armor (class=4) AND Plate subclass (subclass=4).
        plateFilter = string.format(" AND NOT (class=%d AND subclass=%d)", ARMOR_CLASS, PLATE_SUBCLASS)
    end

    local sql = string.format(
        "SELECT entry FROM item_template WHERE class IN (%s) AND Quality=%d AND RequiredLevel BETWEEN %d AND %d AND entry BETWEEN %d AND %d%s ORDER BY RAND() LIMIT 100",
        CLASS_IN, quality, levelMin, levelMax, CFG.MIN_ITEM_ID, CFG.MAX_ITEM_ID, plateFilter
    )
    dbg(string.format("Query (bossLevel=%d): %s", bossLevel, sql))
    local result = WorldDBQuery(sql)
    local entries = {}
    if result then
        repeat entries[#entries+1] = result:GetUInt32(0)
        until not result:NextRow()
    end
    return entries
end

local function pickItemEntry(quality, bossLevel)
    local lo = math.max(0, bossLevel - CFG.LEVEL_BELOW_TIGHT)
    local hi = bossLevel + CFG.LEVEL_ABOVE_TIGHT
    local pool = queryItemEntries(quality, lo, hi, bossLevel)
    dbg(string.format("Tight range [%d-%d] returned %d result(s) for quality %d", lo, hi, #pool, quality))

    if #pool == 0 then
        lo = math.max(0, bossLevel - CFG.LEVEL_BELOW_WIDE)
        hi = bossLevel + CFG.LEVEL_ABOVE_WIDE
        pool = queryItemEntries(quality, lo, hi, bossLevel)
        dbg(string.format("Wide range [%d-%d] returned %d result(s) for quality %d", lo, hi, #pool, quality))
    end

    if #pool == 0 then return nil end
    return pool[math.random(1, #pool)]
end

local function getItemName(entry)
    local res = WorldDBQuery(string.format("SELECT name FROM item_template WHERE entry=%d LIMIT 1", entry))
    return res and res:GetString(0) or ("Item#"..entry)
end

local function formatItem(entry, quality)
    return string.format("|cff%s[%s]|r", QUALITY_COLOR[quality] or "ffffff", getItemName(entry))
end

local function isBoss(creature)
    return creature:IsDungeonBoss() or creature:IsWorldBoss()
end

local function getPlayersInInstance(mapId, instanceId)
    local all = GetPlayersInWorld()
    if not all then return {} end
    local list = {}
    for _, p in ipairs(all) do
        if p:GetMapId() == mapId and p:GetInstanceId() == instanceId then
            list[#list+1] = p
        end
    end
    return list
end

------------------------------------------------------------------------
-- Core Spawn Function
------------------------------------------------------------------------
local function spawnBonusChest(bossName, bossLevel, x, y, z, o, mapId, instanceId)
    dbg("--- START SPAWN ATTEMPT ---")
    dbg(string.format("Boss: %s (Level %d)", bossName, bossLevel))
    dbg(string.format("Position: X:%.2f, Y:%.2f, Z:%.2f, O:%.2f", x, y, z, o))
    dbg(string.format("MapID: %d | InstanceID: %d", mapId, instanceId))

    -- Roll items
    local itemCount   = math.random(CFG.MIN_ITEMS, CFG.MAX_ITEMS)
    local chosenItems = {}
    local usedEntries = {}

    dbg(string.format("Rolling %d item(s)...", itemCount))
    for _ = 1, itemCount do
        local quality = rollQuality()
        local entry
        for attempt = 1, 5 do
            entry = pickItemEntry(quality, bossLevel)
            if not entry or not usedEntries[entry] then break end
        end
        if entry then
            usedEntries[entry] = true
            chosenItems[#chosenItems+1] = {entry=entry, quality=quality}
        else
            dbg(string.format("Could not find a unique item for quality %d after 5 attempts.", quality))
        end
    end

    if #chosenItems == 0 then
        dbg("ABORT: No items found. Check item_template for matching level/class/quality.")
        return
    end

    -- Spawn chest
    local despawnMs = CFG.CHEST_DESPAWN_SEC * 1000
    dbg("Calling PerformIngameSpawn...")
    local go = PerformIngameSpawn(2, CFG.CHEST_ENTRY, mapId, instanceId, x, y, z, o, false, despawnMs)

    if not go then
        dbg("CRITICAL: PerformIngameSpawn returned nil.")
        return
    end

    local goGuid = go:GetGUID()
    dbg(string.format("Spawned GO with GUID: %s", tostring(goGuid)))

    if goGuid == 0 then
        dbg("CRITICAL: GUID is 0. Engine failed to register the object.")
        return
    end

    -- Populate loot
    go:SetLootState(GO_NOT_READY)
    for _, item in ipairs(chosenItems) do
        local result = go:AddLoot(item.entry, 1)
        if result and result > 0 then
            dbg(string.format("Added loot: %s", formatItem(item.entry, item.quality)))
        else
            dbg(string.format("Failed to add loot entry: %d", item.entry))
        end
    end
    go:SetLootState(GO_READY)

    -- Announce to instance
    local players = getPlayersInInstance(mapId, instanceId)
    for _, p in ipairs(players) do
        p:SendBroadcastMessage("|cffFFD700[Bonus Loot]|r A chest has appeared!")
    end
    dbg(string.format("Done: Chest spawned and announced to %d player(s).", #players))
end

------------------------------------------------------------------------
-- Events
-- PLAYER_EVENT_ON_KILL_CREATURE = 7, signature: (event, killer, killed)
-- killer is a valid Player object at event time.
-- All data we need is read from `killed` immediately — no userdata stored.
-- A per-boss GUID cooldown table prevents double-spawns when multiple
-- players in a party receive simultaneous kill credit.
------------------------------------------------------------------------
local function OnPlayerKillCreature(event, killer, killed)
    if not isBoss(killed) then return end

    local bossGuid = killed:GetGUIDLow()

    -- Cooldown guard: ignore if this boss already triggered a spawn
    if recentlySpawned[bossGuid] then
        dbg(string.format("Skipping duplicate kill event for boss GUID %d.", bossGuid))
        return
    end
    recentlySpawned[bossGuid] = true

    -- Read everything from `killed` now while it's valid.
    -- All captured values are plain Lua strings/numbers — safe across the delay.
    local bossName    = killed:GetName()
    local bossLevel   = killed:GetLevel()
    local x, y, z, o = killed:GetX(), killed:GetY(), killed:GetZ(), killed:GetO()
    local mapId       = killed:GetMapId()
    local instanceId  = killed:GetInstanceId()

    dbg(string.format("Event Triggered: '%s' (Level %d) died. Scheduling spawn...", bossName, bossLevel))

    CreateLuaEvent(function()
        spawnBonusChest(bossName, bossLevel, x, y, z, o, mapId, instanceId)
        -- Clear cooldown after the spawn window has passed
        recentlySpawned[bossGuid] = nil
    end, CFG.SPAWN_COOLDOWN_MS, 1)
end

RegisterPlayerEvent(7, OnPlayerKillCreature)
print("[BossLootChest] v6.0 loaded with Verbose Debugging.")