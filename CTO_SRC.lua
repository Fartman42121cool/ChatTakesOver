local ffi = require("ffi")

ffi.cdef[[
    typedef unsigned short WORD;
    typedef unsigned long DWORD;
    typedef unsigned long long ULONG_PTR;
    typedef unsigned long long ULONGLONG;
    typedef signed long LONG;

    typedef struct {
        WORD wVk;
        WORD wScan;
        DWORD dwFlags;
        DWORD time;
        ULONG_PTR dwExtraInfo;
    } KEYBDINPUT;

    typedef struct {
        LONG dx;
        LONG dy;
        DWORD mouseData;
        DWORD dwFlags;
        DWORD time;
        ULONG_PTR dwExtraInfo;
    } MOUSEINPUT;

    typedef struct {
        DWORD type;
        union {
            MOUSEINPUT mi;
            KEYBDINPUT ki;
            unsigned char padding[32];
        };
    } INPUT;

    unsigned int SendInput(unsigned int cInputs, INPUT* pInputs, int cbSize);
    void Sleep(unsigned long dwMilliseconds);
    ULONGLONG GetTickCount64(void);
]]

local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")

--// Timing \\--
local function NowMs()
    return tonumber(kernel32.GetTickCount64())
end

local function Sleep(Duration)
    kernel32.Sleep(math.max(0, math.floor(Duration * 1000)))
end

--// Input Configuration \\--
local INPUT_MOUSE = 0
local INPUT_KEYBOARD = 1
local KEYEVENTF_KEYUP = 0x0002
local KEYEVENTF_SCANCODE = 0x0008
local MOUSEEVENTF_MOVE = 0x0001
local MAX_INPUT_DURATION = 3
local MOUSE_TURN_UNITS_PER_SECOND = 500

local VK_W = 0x11
local VK_A = 0x1E
local VK_S = 0x1F
local VK_D = 0x20
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
    local Input = ffi.new("INPUT[1]")
    Input[0].type = INPUT_KEYBOARD
    Input[0].ki.wScan = ScanCode
    Input[0].ki.dwFlags = KEYEVENTF_SCANCODE
    if IsKeyUp then
        Input[0].ki.dwFlags = Input[0].ki.dwFlags + KEYEVENTF_KEYUP
    end

    local Result = user32.SendInput(1, Input, ffi.sizeof("INPUT"))
    if Result ~= 1 then
        error("SendInput keyboard event failed")
    end
end

-- Relative X motion: negative turns left, positive turns right.
-- Mouse motion is a one-shot event and does not require key-up cleanup.
local function SendMouseMove(DeltaX)
    DeltaX = math.floor(DeltaX)
    if DeltaX == 0 then return end

    local Input = ffi.new("INPUT[1]")
    Input[0].type = INPUT_MOUSE
    Input[0].mi.dx = DeltaX
    Input[0].mi.dy = 0
    Input[0].mi.mouseData = 0
    Input[0].mi.dwFlags = MOUSEEVENTF_MOVE
    Input[0].mi.time = 0
    Input[0].mi.dwExtraInfo = 0

    local Result = user32.SendInput(1, Input, ffi.sizeof("INPUT"))
    if Result ~= 1 then
        error("SendInput mouse movement failed")
    end
end

--// Time-Based Mouse Turning \--
-- The command argument is duration in seconds; turn speed is calibrated separately.
local ActiveMouseTurn = nil

local function StartMouseTurn(Direction, Duration)
    Duration = math.max(0, math.min(Duration, MAX_INPUT_DURATION))
    local StartTime = NowMs()
    ActiveMouseTurn = {
        Direction = Direction,
        ExpirationTime = StartTime + (Duration * 1000),
        LastUpdateTime = StartTime,
        Remainder = 0
    }
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

local function UpdateMouseTurn(CurrentTime)
    local Turn = ActiveMouseTurn
    if not Turn then return end

    local TurnEndTime = math.min(CurrentTime, Turn.ExpirationTime)
    local ElapsedMs = math.max(0, TurnEndTime - Turn.LastUpdateTime)
    local ExactMovement = (ElapsedMs * MOUSE_TURN_UNITS_PER_SECOND / 1000) + Turn.Remainder
    local Movement = math.floor(ExactMovement)
    Turn.Remainder = ExactMovement - Movement
    Turn.LastUpdateTime = TurnEndTime

    if Movement > 0 then
        SendMouseMove(Movement * Turn.Direction)
    end

    if CurrentTime >= Turn.ExpirationTime then
        ActiveMouseTurn = nil
    end
end

local function UpdateInputs()
    local CurrentTime = NowMs()
    UpdateMouseTurn(CurrentTime)
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
        ActiveInputs["EMERGENCY_" .. tostring(ScanCode)] = {
            ScanCode = ScanCode,
            ExpirationTime = NowMs()
        }
        error(ErrorMessage)
    end
end

--// Command Parsing \\--
-- !l / !r take durations in seconds, just like movement commands.
-- Mouse turn speed is controlled by MOUSE_TURN_UNITS_PER_SECOND.
local function ParseCommand(Command)
    local Action, ArgumentText = Command:match("^!(%w+)%s*([%d%.]*)$")
    if not Action then return end

    Action = Action:lower()
    local Argument
    if ArgumentText ~= "" then
        Argument = tonumber(ArgumentText)
        if not Argument or Argument < 0 then return end
    end

    if Action == "l" and Argument then
        StartMouseTurn(-1, Argument)
    elseif Action == "r" and Argument then
        StartMouseTurn(1, Argument)
    elseif Action == "w" and Argument then
        StartInput("W", VK_W, Argument)
    elseif Action == "a" and Argument then
        StartInput("A", VK_A, Argument)
    elseif Action == "s" and Argument then
        StartInput("S", VK_S, Argument)
    elseif Action == "d" and Argument then
        StartInput("D", VK_D, Argument)
    elseif Action == "e" then
        PressInput(VK_E)
    elseif Action == "shoot" then
        if Argument then
            StartInput("SHOOT", VK_CTRL, Argument)
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
-- Mouse turn values are durations in seconds. Adjust MOUSE_TURN_UNITS_PER_SECOND to calibrate turn speed.
local Commands = {
    "!w 1.5",
    "!l 1.5",
    "!shoot 1",
    "!r 2",
    "!shoot 1",
    "!r 1",
    "!w 1.5",
    "!s 1",
    "!d 1",
    "!l 1",
}

local COMMAND_INTERVAL = 2
local TEST_DURATION = 30

local function RunTest()
    print("Starting in 5 seconds...")
    Sleep(5)
    print("Fake chat started.")
    print("Mouse turning is time-based; tune MOUSE_TURN_UNITS_PER_SECOND if needed.")

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
