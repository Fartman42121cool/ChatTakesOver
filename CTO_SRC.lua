local ffi = require("ffi")

ffi.cdef[[
    typedef unsigned short WORD;
    typedef unsigned long DWORD;
    typedef unsigned long long ULONG_PTR;
    typedef unsigned long long ULONGLONG;

    typedef struct {
        WORD wVk;
        WORD wScan;
        DWORD dwFlags;
        DWORD time;
        ULONG_PTR dwExtraInfo;
    } KEYBDINPUT;

    typedef struct {
        DWORD type;

        union {
            KEYBDINPUT ki;
            unsigned char padding[32];
        };
    } INPUT;

    unsigned int SendInput(
        unsigned int cInputs,
        INPUT* pInputs,
        int cbSize
    );

    void Sleep(unsigned long dwMilliseconds);
    ULONGLONG GetTickCount64(void);
]]

local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")

--// Timing \\--
-- GetTickCount64 measures real elapsed time, including time spent sleeping.
local function NowMs()
    return tonumber(kernel32.GetTickCount64())
end

local function Sleep(Duration)
    local Milliseconds = math.max(0, math.floor(Duration * 1000))
    kernel32.Sleep(Milliseconds)
end

--// Input Configuration \\--
local INPUT_KEYBOARD = 1
local KEYEVENTF_KEYUP = 0x0002
local KEYEVENTF_SCANCODE = 0x0008

local MAX_INPUT_DURATION = 3

local VK_W = 0x11
local VK_A = 0x1E
local VK_S = 0x1F
local VK_D = 0x20

local VK_LEFT = 0xCB
local VK_RIGHT = 0xCD

local VK_E = 0x12
local VK_CTRL = 0x1D

local VK_1 = 0x02
local VK_2 = 0x03
local VK_3 = 0x04
local VK_4 = 0x05
local VK_5 = 0x06
local VK_6 = 0x07
local VK_7 = 0x08

local function SendKey(ScanCode, IsKeyUp)
    local Input = ffi.new("INPUT")

    Input.type = INPUT_KEYBOARD
    Input.ki.wScan = ScanCode
    Input.ki.dwFlags = KEYEVENTF_SCANCODE

    if IsKeyUp then
        Input.ki.dwFlags = Input.ki.dwFlags + KEYEVENTF_KEYUP
    end

    local Result = user32.SendInput(
        1,
        Input,
        ffi.sizeof("INPUT")
    )

    if Result ~= 1 then
        error("SendInput failed")
    end
end

local ActiveInputs = {}

--// Input Cleanup \\--
local function ReleaseAllInputs()
    local Errors = {}

    for Name, Input in pairs(ActiveInputs) do
        local Ok, ErrorMessage = pcall(SendKey, Input.ScanCode, true)

        if not Ok then
            Errors[#Errors + 1] = Name .. ": " .. tostring(ErrorMessage)
        end

        -- Clear our state even if Windows rejected the release.
        ActiveInputs[Name] = nil
    end

    return Errors
end

--// Input Scheduling \\--
local function StartInput(Name, ScanCode, Duration)
    Duration = math.max(0, math.min(Duration, MAX_INPUT_DURATION))

    local ExpirationTime = NowMs() + (Duration * 1000)
    local Input = ActiveInputs[Name]

    if Input then
        if ExpirationTime > Input.ExpirationTime then
            Input.ExpirationTime = ExpirationTime
        end

        return
    end

    SendKey(ScanCode, false)

    ActiveInputs[Name] = {
        ScanCode = ScanCode,
        ExpirationTime = ExpirationTime
    }
end

local function UpdateInputs()
    local CurrentTime = NowMs()

    for Name, Input in pairs(ActiveInputs) do
        if CurrentTime >= Input.ExpirationTime then
            SendKey(Input.ScanCode, true)
            ActiveInputs[Name] = nil
        end
    end
end

local function PressInput(ScanCode)
    SendKey(ScanCode, false)

    local Ok, ErrorMessage = pcall(SendKey, ScanCode, true)

    if not Ok then
        -- Keep track of a key whose release failed so final cleanup can retry.
        ActiveInputs["EMERGENCY_" .. tostring(ScanCode)] = {
            ScanCode = ScanCode,
            ExpirationTime = NowMs()
        }
        error(ErrorMessage)
    end
end

--// Command Parsing \\--
local function ParseCommand(Command)
    local Action, DurationText = Command:match("^!(%w+)%s*([%d%.]*)$")

    if not Action then
        return
    end

    Action = Action:lower()

    local Duration

    if DurationText ~= "" then
        Duration = tonumber(DurationText)

        if not Duration or Duration < 0 then
            return
        end

        Duration = math.min(Duration, MAX_INPUT_DURATION)
    end

    if Action == "w" and Duration then
        StartInput("W", VK_W, Duration)

    elseif Action == "a" and Duration then
        StartInput("A", VK_A, Duration)

    elseif Action == "s" and Duration then
        StartInput("S", VK_S, Duration)

    elseif Action == "d" and Duration then
        StartInput("D", VK_D, Duration)

    elseif Action == "l" and Duration then
        StartInput("LEFT", VK_LEFT, Duration)

    elseif Action == "r" and Duration then
        StartInput("RIGHT", VK_RIGHT, Duration)

    elseif Action == "e" then
        PressInput(VK_E)

    elseif Action == "shoot" then
        if Duration then
            StartInput("SHOOT", VK_CTRL, Duration)
        else
            PressInput(VK_CTRL)
        end

    elseif Action == "1" then
        PressInput(VK_1)

    elseif Action == "2" then
        PressInput(VK_2)

    elseif Action == "3" then
        PressInput(VK_3)

    elseif Action == "4" then
        PressInput(VK_4)

    elseif Action == "5" then
        PressInput(VK_5)

    elseif Action == "6" then
        PressInput(VK_6)

    elseif Action == "7" then
        PressInput(VK_7)
    end
end

--// Fake Chat Test \\--
local Commands = {
    "!w 3",
    "!l 1",
    "!shoot 2",
    "!r 2.5",
    "!shoot 1.5",
    "!r 0.5",
    "!w 2",
    "!s 1.5",
    "!d 1",
    "!l 0.5",
}

local COMMAND_INTERVAL = 2
local TEST_DURATION = 30

local function RunTest()
    print("Starting in 5 seconds...")
    Sleep(5)

    print("Fake chat started.")

    local StartTime = NowMs()
    local EndTime = StartTime + (TEST_DURATION * 1000)
    local NextCommandTime = StartTime
    local CommandIndex = 1

    while NowMs() < EndTime do
        UpdateInputs()

        local CurrentTime = NowMs()

        if CurrentTime >= NextCommandTime and CommandIndex <= #Commands then
            local Command = Commands[CommandIndex]

            print("Chat:", Command)
            ParseCommand(Command)

            CommandIndex = CommandIndex + 1
            NextCommandTime = CurrentTime + (COMMAND_INTERVAL * 1000)
        end

        Sleep(0.01)
    end
end

-- Always attempt to release held keys, even if the test loop errors.
local Ok, ErrorMessage = xpcall(RunTest, debug.traceback)
local CleanupErrors = ReleaseAllInputs()

if not Ok then
    print("ERROR: Fake chat stopped unexpectedly.")
    print(ErrorMessage)
end

for _, CleanupError in ipairs(CleanupErrors) do
    print("WARNING: Could not release input:", CleanupError)
end

if Ok then
    print("Fake chat finished.")
else
    print("Fake chat stopped after an error.")
end
