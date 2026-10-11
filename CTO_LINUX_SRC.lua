-- ChatTakesOver - Linux/X11 input prototype
-- Separate from CTO_SRC.lua so the existing Windows implementation remains untouched.
-- Default is DRY RUN. Set CTO_ENABLE_INPUT=1 only when the intended guest game window is focused.

local ffi = require("ffi")

ffi.cdef[[
    typedef long time_t;
    struct timespec { time_t tv_sec; long tv_nsec; };
    int clock_gettime(int clock_id, struct timespec *tp);
    int nanosleep(const struct timespec *req, struct timespec *rem);
]]

local CLOCK_MONOTONIC = 1
local EINTR = 4
local INPUT_ENABLED = os.getenv("CTO_ENABLE_INPUT") == "1"
local MAX_INPUT_DURATION = 3
local COMMAND_INTERVAL = 2
local TEST_DURATION = 30

-- xdotool key names. Only these fixed strings are ever passed to the shell.
local KEY_MAP = {
    w = "w", a = "a", s = "s", d = "d",
    left = "Left", right = "Right", e = "e", shoot = "ctrl",
    ["1"] = "1", ["2"] = "2", ["3"] = "3", ["4"] = "4",
    ["5"] = "5", ["6"] = "6", ["7"] = "7",
}

local function GetTime()
    local TimeSpec = ffi.new("struct timespec[1]")
    if ffi.C.clock_gettime(CLOCK_MONOTONIC, TimeSpec) ~= 0 then
        error("clock_gettime(CLOCK_MONOTONIC) failed")
    end
    return tonumber(TimeSpec[0].tv_sec) + tonumber(TimeSpec[0].tv_nsec) / 1000000000
end

local function Sleep(Duration)
    if Duration <= 0 then return end
    local Seconds = math.floor(Duration)
    local Nanoseconds = math.floor((Duration - Seconds) * 1000000000)
    local Request = ffi.new("struct timespec[1]")
    local Remaining = ffi.new("struct timespec[1]")
    Request[0].tv_sec = Seconds
    Request[0].tv_nsec = Nanoseconds

    while ffi.C.nanosleep(Request, Remaining) ~= 0 do
        if ffi.errno() ~= EINTR then error("nanosleep failed") end
        Request[0].tv_sec = Remaining[0].tv_sec
        Request[0].tv_nsec = Remaining[0].tv_nsec
    end
end

local function SendKey(KeyName, IsKeyUp)
    local Key = KEY_MAP[KeyName]
    if not Key then error("Unknown input key: " .. tostring(KeyName)) end

    local Direction = IsKeyUp and "keyup" or "keydown"
    if not INPUT_ENABLED then
        print("[DRY RUN]", Direction, Key)
        return
    end

    -- Keys are selected only from KEY_MAP, never from chat/user-provided text.
    local Result = os.execute("xdotool " .. Direction .. " --clearmodifiers " .. Key)
    if Result ~= 0 and Result ~= true then
        error("xdotool failed while attempting " .. Direction .. " " .. Key)
    end
end

local ActiveInputs = {}

local function StartInput(Name, KeyName, Duration)
    Duration = math.min(Duration, MAX_INPUT_DURATION)
    local ExpirationTime = GetTime() + Duration
    local Input = ActiveInputs[Name]

    if Input then
        if ExpirationTime > Input.ExpirationTime then
            Input.ExpirationTime = ExpirationTime
        end
        return
    end

    SendKey(KeyName, false)
    ActiveInputs[Name] = { KeyName = KeyName, ExpirationTime = ExpirationTime }
end

local function UpdateInputs()
    local CurrentTime = GetTime()
    for Name, Input in pairs(ActiveInputs) do
        if CurrentTime >= Input.ExpirationTime then
            SendKey(Input.KeyName, true)
            ActiveInputs[Name] = nil
        end
    end
end

local function ReleaseAllInputs()
    for Name, Input in pairs(ActiveInputs) do
        local Ok, Err = pcall(SendKey, Input.KeyName, true)
        if not Ok then print("Warning: failed to release", Name, Err) end
        ActiveInputs[Name] = nil
    end
end

local function PressInput(KeyName)
    SendKey(KeyName, false)
    SendKey(KeyName, true)
end

local function ParseCommand(Command)
    if type(Command) ~= "string" then return end
    local Action, DurationText = Command:match("^!(%w+)%s*([%d%.]*)$")
    if not Action then return end
    Action = Action:lower()

    local Duration
    if DurationText ~= "" then
        Duration = tonumber(DurationText)
        if not Duration or Duration ~= Duration or Duration == math.huge or Duration < 0 then
            print("Ignoring invalid duration in command:", Command)
            return
        end
        Duration = math.min(Duration, MAX_INPUT_DURATION)
    end

    local KeyName
    if Action == "w" or Action == "a" or Action == "s" or Action == "d" then
        KeyName = Action
    elseif Action == "l" then
        KeyName = "left"
    elseif Action == "r" then
        KeyName = "right"
    elseif Action == "e" then
        PressInput("e")
        return
    elseif Action == "shoot" then
        if Duration then StartInput("SHOOT", "shoot", Duration)
        else PressInput("shoot") end
        return
    elseif KEY_MAP[Action] and #Action == 1 then
        PressInput(Action)
        return
    else
        return
    end

    if Duration and Duration > 0 then
        StartInput(Action:upper(), KeyName, Duration)
    end
end

local Commands = {
    "!w 3", "!l 1", "!shoot 2", "!r 2.5", "!shoot 1.5",
    "!r 0.5", "!w 2", "!s 1.5", "!d 1", "!l 0.5",
}

print("ChatTakesOver Linux/X11 input prototype")
print("Mode:", INPUT_ENABLED and "LIVE INPUT" or "DRY RUN (safe; no keys sent)")
if INPUT_ENABLED then
    print("WARNING: xdotool sends input to the currently focused guest window.")
    print("Focus the intended game window before the test begins.")
else
    print("To enable actual guest input later: CTO_ENABLE_INPUT=1 luajit CTO_LINUX_SRC.lua")
end
print("Starting test in 5 seconds...")
Sleep(5)

local StartTime = GetTime()
local NextCommandTime = StartTime
local CommandIndex = 1

local Ok, Err = xpcall(function()
    while GetTime() - StartTime < TEST_DURATION do
        UpdateInputs()
        local CurrentTime = GetTime()
        if CurrentTime >= NextCommandTime and CommandIndex <= #Commands then
            local Command = Commands[CommandIndex]
            print("Fake chat:", Command)
            ParseCommand(Command)
            CommandIndex = CommandIndex + 1
            NextCommandTime = CurrentTime + COMMAND_INTERVAL
        end
        Sleep(0.01)
    end
end, debug.traceback)

ReleaseAllInputs()
if not Ok then error(Err) end
print("Fake-chat test finished.")
