--------------------------------------------------------------------------------
-- wow-stubs
--
-- Just enough of the WoW widget API to load real addon code outside the game,
-- with every call counted. This is what lets the Ultra Performance budget be a
-- measurement rather than an assertion: the addon's own OnUpdate is driven for
-- a simulated second and we count what it actually asked the client to do.
--
-- Deliberately NOT a WoW emulator. It models the handful of behaviours a
-- performance measurement depends on - what a call costs, whether a frame is
-- shown, what a status bar's value is - and makes everything else an inert
-- no-op. A case that needs more should stub it itself.
--------------------------------------------------------------------------------

local Stubs = {}

Stubs.counts = {}
Stubs.time = 1000

local function Count(name)
    Stubs.counts[name] = (Stubs.counts[name] or 0) + 1
end
Stubs.Count = Count

function Stubs.ResetCounts()
    Stubs.counts = {}
end

function Stubs.TotalCalls()
    local total = 0
    for name, n in pairs(Stubs.counts) do
        -- Bookkeeping counters, not real client calls.
        if name ~= "SetText:changed" then total = total + n end
    end
    return total
end

--------------------------------------------------------------------------------
-- Textures and font strings
--------------------------------------------------------------------------------

local Texture = {}
Texture.__index = function(_, key)
    -- Internal state fields must not be swallowed by the catch-all, or an unset
    -- "_text" reads back as a stub closure instead of nil and every assertion
    -- about it silently passes. This bit us once already; keep it first.
    if type(key) == "string" and key:sub(1, 1) == "_" then return nil end

    return function(self, ...)
        Count(key)
        if key == "SetText" then
            local value = ...
            -- Only count the calls that change what is on screen. A FontString
            -- re-measures its string width on every SetText, changed or not, so
            -- the gap between these two numbers is pure waste.
            if self._text ~= value then
                self._text = value
                Count("SetText:changed")
            end
        elseif key == "GetText" then
            return self._text
        elseif key == "Show" then
            self._shown = true
        elseif key == "Hide" then
            self._shown = false
        elseif key == "SetShown" then
            self._shown = (...) and true or false
        elseif key == "IsShown" then
            return self._shown
        end
    end
end

function Stubs.NewTexture()
    return setmetatable({ _shown = false }, Texture)
end

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

local Frame = {}

local FrameMT = {
    __index = function(_, key)
        if type(key) == "string" and key:sub(1, 1) == "_" then return nil end
        local real = Frame[key]
        if real then return real end
        return function() Count(key) end
    end,
}

function Frame:SetAlpha(a) Count("SetAlpha") self._alpha = a end
function Frame:GetAlpha() return self._alpha end
function Frame:Show() Count("Show") self._shown = true end
function Frame:Hide() Count("Hide") self._shown = false end
function Frame:IsShown() return self._shown end
function Frame:SetShown(v) Count("SetShown") self._shown = v and true or false end
function Frame:CreateTexture() return Stubs.NewTexture() end
function Frame:CreateFontString() return Stubs.NewTexture() end
function Frame:SetScript(script, fn) self._scripts[script] = fn end
function Frame:GetScript(script) return self._scripts[script] end
function Frame:HookScript(script, fn) self._scripts[script] = fn end
function Frame:SetValue(v) Count("SetValue") self._value = v end
function Frame:GetValue() return self._value end
function Frame:SetMinMaxValues(lo, hi) self._min, self._max = lo, hi end
function Frame:GetMinMaxValues() return self._min or 0, self._max or 1 end
function Frame:SetWidth(w) Count("SetWidth") self._width = w end
function Frame:SetHeight(h) Count("SetHeight") self._height = h end
function Frame:SetSize(w, h) Count("SetSize") self._width, self._height = w, h end
function Frame:GetWidth() Count("GetWidth") return self._width or 200 end
function Frame:GetHeight() Count("GetHeight") return self._height or 24 end
function Frame:SetPoint() Count("SetPoint") end
function Frame:ClearAllPoints() Count("ClearAllPoints") end
function Frame:GetFrameLevel() return 1 end
function Frame:SetStatusBarColor(r, g, b) Count("SetStatusBarColor") self._color = { r, g, b } end
function Frame:GetStatusBarColor()
    local c = self._color or { 1, 1, 1 }
    return c[1], c[2], c[3]
end
function Frame:GetStatusBarTexture() return self._fill end
function Frame:SetStatusBarTexture()
    Count("SetStatusBarTexture")
    self._fill = self._fill or Stubs.NewTexture()
    return self._fill
end

function Stubs.NewFrame()
    return setmetatable({
        _shown = false, _alpha = 1, _scripts = {}, _value = 0,
    }, FrameMT)
end

--------------------------------------------------------------------------------
-- Global install
--------------------------------------------------------------------------------

-- Installs the globals an addon file expects at load time. Cases may overwrite
-- any of these afterwards; nothing here is read back by the harness itself.
function Stubs.Install()
    _G.CreateFrame = function() return Stubs.NewFrame() end
    _G.UIParent = Stubs.NewFrame()

    _G.GetTime = function() return Stubs.time end
    _G.GetNetStats = function() return 0, 0, 0, 60 end
    _G.GetLocale = function() return "enUS" end

    _G.issecretvalue = function() return false end
    _G.issecrettable = function() return false end

    _G.C_Timer = { After = function(_, fn) if fn then fn() end end }
    _G.C_AddOns = { GetAddOnMetadata = function() return "0.0.0" end }

    _G.UnitExists = function() return true end
    _G.UnitCastingInfo = function() return nil end
    _G.UnitChannelInfo = function() return nil end
    _G.UnitHasVehicleUI = function() return false end

    return Stubs
end

-- Advance simulated time and tick a handler, counting everything it does.
-- Returns the per-frame call average over the run, which is the number the
-- Ultra Performance budget is written against.
function Stubs.Drive(handler, frames, step)
    Stubs.ResetCounts()
    for _ = 1, frames do
        Stubs.time = Stubs.time + step
        handler(step)
    end
    return Stubs.TotalCalls() / frames
end

return Stubs
