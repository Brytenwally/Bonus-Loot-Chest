-- =============================================================================
-- BonusLootChest.lua  –  AzerothCore | Eluna LUA Engine (ALE)
-- Version: 6.4.1 (Verbose Debug Mode - Visibility Fix)
-- =============================================================================

------------------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------------------
local CFG = {
    CHEST_ENTRY       = 2843,     -- GO entry
    CHEST_DESPAWN_SEC = 30,      -- seconds

    BOSS_CHEST_CHANCE  = 100,     -- Chance to spawn on boss kill (1-100)
    QUEST_CHEST_CHANCE = 100,     -- Chance to spawn on quest completion by leader (1-100)

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
    if CFG.DEBUG then print("[BonusLootChest DEBUG] " .. tostring(msg)) end
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

local function queryItemEntries(quality, levelMin, levelMax, targetLevel)
    -- Build an optional extra filter to block plate armour for low-level bosses.
    local plateFilter = ""
    if targetLevel < 40 then
        -- Exclude rows that are Armor (class=4) AND Plate subclass (subclass=4).
        plateFilter = string.format(" AND NOT (class=%d AND subclass=%d)", ARMOR_CLASS, PLATE_SUBCLASS)
    end

    local sql = string.format(
        "SELECT entry FROM item_template WHERE class IN (%s) AND Quality=%d AND RequiredLevel BETWEEN %d AND %d AND entry BETWEEN %d AND %d%s ORDER BY RAND() LIMIT 100",
        CLASS_IN, quality, levelMin, levelMax, CFG.MIN_ITEM_ID, CFG.MAX_ITEM_ID, plateFilter
    )
    dbg(string.format("Query (targetLevel=%d): %s", targetLevel, sql))
    local result = WorldDBQuery(sql)
    local entries = {}
    if result then
        repeat entries[#entries+1] = result:GetUInt32(0)
        until not result:NextRow()
    end
    return entries
end

local function pickItemEntry(quality, targetLevel)
    local lo = math.max(0, targetLevel - CFG.LEVEL_BELOW_TIGHT)
    local hi = targetLevel + CFG.LEVEL_ABOVE_TIGHT
    local pool = queryItemEntries(quality, lo, hi, targetLevel)
    dbg(string.format("Tight range [%d-%d] returned %d result(s) for quality %d", lo, hi, #pool, quality))

    if #pool == 0 then
        lo = math.max(0, targetLevel - CFG.LEVEL_BELOW_WIDE)
        hi = targetLevel + CFG.LEVEL_ABOVE_WIDE
        pool = queryItemEntries(quality, lo, hi, targetLevel)
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
local function spawnBonusChest(summoner, sourceName, targetLevel, x, y, z, o)
    local mapId = summoner:GetMapId()
    local instanceId = summoner:GetInstanceId()

    dbg("--- START SPAWN ATTEMPT ---")
    dbg(string.format("Source: %s (Level %d)", sourceName, targetLevel))
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
            entry = pickItemEntry(quality, targetLevel)
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

    -- Spawn chest using the summoner to inherit perfect visibility, map, and phasing natively
    dbg("Calling SummonGameObject...")
    local go = summoner:SummonGameObject(CFG.CHEST_ENTRY, x, y, z, o, CFG.CHEST_DESPAWN_SEC)

    if not go then
        dbg("CRITICAL: SummonGameObject returned nil.")
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
------------------------------------------------------------------------

-- 1. Boss Kill Event
local function OnPlayerKillCreature(event, killer, killed)
    if not isBoss(killed) then return end

    local bossGuid = killed:GetGUIDLow()

    -- Cooldown guard: ignore if this boss already triggered a spawn
    if recentlySpawned[bossGuid] then
        dbg(string.format("Skipping duplicate kill event for boss GUID %d.", bossGuid))
        return
    end

    -- Chance check
    if math.random(1, 100) > CFG.BOSS_CHEST_CHANCE then
        dbg("Boss kill rolled below spawn chance threshold. No chest.")
        return
    end

    recentlySpawned[bossGuid] = true

    local bossName    = killed:GetName()
    local bossLevel   = killed:GetLevel()
    local x, y, z, o  = killed:GetX(), killed:GetY(), killed:GetZ(), killed:GetO()
    local playerGuid  = killer:GetGUID()

    dbg(string.format("Event Triggered: '%s' (Level %d) died. Scheduling spawn...", bossName, bossLevel))

    CreateLuaEvent(function()
        local summoner = GetPlayerByGUID(playerGuid)
        if summoner then
            spawnBonusChest(summoner, bossName, bossLevel, x, y, z, o)
        end
        recentlySpawned[bossGuid] = nil
    end, CFG.SPAWN_COOLDOWN_MS, 1)
end

-- 2. Quest Complete Event (Field Completion)
local function OnPlayerCompleteQuest(event, player, quest)
    -- Chance check
    if math.random(1, 100) > CFG.QUEST_CHEST_CHANCE then
        dbg("Quest completion rolled below spawn chance threshold. No chest.")
        return
    end

    -- Group Leader check
    local group = player:GetGroup()
    if not group or group:GetLeaderGUID() ~= player:GetGUID() then
        dbg("Quest completed but player is not the group leader (or not in a group).")
        return
    end

    -- Get quest info from DB
    local questId = quest:GetId()
    local questLevel = quest:GetLevel()
    if questLevel <= 0 then questLevel = player:GetLevel() end -- Fallback if quest level is 0
    
    local questTitle = "Quest#" .. questId
    local query = WorldDBQuery(string.format("SELECT LogTitle FROM quest_template WHERE ID = %d", questId))
    if query then
        questTitle = query:GetString(0)
    end
    
    local x, y, z, o = player:GetX(), player:GetY(), player:GetZ(), player:GetO()
    local playerGuid = player:GetGUID()

    -- Apply continuous random offset between -5 and +5 for X and Y axes
    x = x + ((math.random() * 10) - 5)
    y = y + ((math.random() * 10) - 5)

    dbg(string.format("Event Triggered: Quest '%s' (Level %d) completed by leader. Scheduling spawn...", questTitle, questLevel))

    CreateLuaEvent(function()
        local summoner = GetPlayerByGUID(playerGuid)
        if summoner then
            spawnBonusChest(summoner, "Quest: " .. questTitle, questLevel, x, y, z, o)
        end
    end, CFG.SPAWN_COOLDOWN_MS, 1)
end

RegisterPlayerEvent(7, OnPlayerKillCreature)   -- PLAYER_EVENT_ON_KILL_CREATURE
RegisterPlayerEvent(54, OnPlayerCompleteQuest) -- PLAYER_EVENT_ON_COMPLETE_QUEST

print("[BossLootChest] v6.4.1 loaded with SummonGameObject visibility fix.")
