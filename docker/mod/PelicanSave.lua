-- FS25_PelicanSave: lets the Pelican wrapper save the game before it stops the dedicated server.
-- The wrapper writes modSettings/FS25_PelicanSave/request.xml (<pelican id="..."/>); the mod saves the
-- savegame and answers in status.xml (<pelican state="ready|saving|done|error" id="..." info="..."/>).
-- Server only: on clients the mod does nothing.

PelicanSave = {
    enabled = false,
    timer = 0,
    clock = 0,
    state = "idle",
    lastId = nil,
    requestId = nil,
    savingSince = 0
}

local function log(fmt, ...)
    print(string.format("[PelicanSave] " .. fmt, ...))
end

function PelicanSave:readRequestId()
    local path = self.dir .. "request.xml"
    if not fileExists(path) then
        return nil
    end
    local xml = loadXMLFile("pelicanSaveRequest", path)
    if xml == nil or xml == 0 then
        return nil
    end
    local id = getXMLString(xml, "pelican#id")
    delete(xml)
    return id
end

function PelicanSave:writeStatus(state, info)
    self.state = state
    local xml = createXMLFile("pelicanSaveStatus", self.dir .. "status.xml", "pelican")
    if xml == nil or xml == 0 then
        return
    end
    setXMLString(xml, "pelican#state", state)
    setXMLString(xml, "pelican#id", self.requestId or "")
    setXMLString(xml, "pelican#info", info or "")
    saveXMLFile(xml)
    delete(xml)
end

function PelicanSave:isSaving()
    local controller = g_currentMission.savegameController or g_savegameController
    if controller ~= nil and controller.getIsSaving ~= nil then
        return controller:getIsSaving()
    end
    return false
end

function PelicanSave:startSave()
    local mission = g_currentMission
    local ok, err, method
    if mission.saveSavegame ~= nil then
        -- same call the in-game "Save" uses on the server (checked on FS25 1.25)
        method = "saveSavegame"
        ok, err = pcall(mission.saveSavegame, mission)
    elseif mission.startSaveCurrentGame ~= nil then
        method = "startSaveCurrentGame"
        ok, err = pcall(mission.startSaveCurrentGame, mission, false, true)
    else
        method = "none"
        ok, err = false, "no save function found"
    end
    log("save request %s via %s: %s", tostring(self.requestId), method, ok and "started" or tostring(err))
    if ok then
        self.savingSince = self.clock
        self:writeStatus("saving", method)
    else
        self:writeStatus("error", method .. ": " .. tostring(err))
    end
end

function PelicanSave:loadMap(filename)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    self.dir = getUserProfileAppPath() .. "modSettings/FS25_PelicanSave/"
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(self.dir)
    -- a request left over from before this start is not for us
    self.lastId = self:readRequestId()
    self.enabled = true
    -- "ready" only once the mission updates (after "Entered Gameplay"); until then saving is not possible
    self:writeStatus("loading", "")
end

-- Mod event listeners get no update() while the empty server is paused (pause_game_if_empty),
-- so the check runs from FSBaseMission.update instead, which keeps being called.
function PelicanSave:tick(dt)
    if not self.enabled then
        return
    end
    self.clock = self.clock + dt
    self.timer = self.timer + dt
    if self.timer < 1000 then
        return
    end
    self.timer = 0

    if self.state == "loading" then
        self:writeStatus("ready", "")
        log("ready (saveSavegame=%s, getIsSaving=%s)", type(g_currentMission.saveSavegame),
            type(g_savegameController ~= nil and g_savegameController.getIsSaving or nil))
    end

    if self.state == "saving" then
        -- saving runs over several frames; give it at least 2 s to start
        if self.clock - self.savingSince > 2000 and not self:isSaving() then
            log("save request %s finished", tostring(self.requestId))
            self:writeStatus("done", "")
        end
        return
    end

    local ok, id = pcall(self.readRequestId, self)
    if not ok then
        log("reading request failed: %s", tostring(id))
    elseif id ~= nil and id ~= self.lastId then
        self.lastId = id
        self.requestId = id
        self:startSave()
    end
end

FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
    PelicanSave:tick(dt)
end)

addModEventListener(PelicanSave)
