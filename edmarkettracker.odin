package markettracker

import "core:fmt"
import "core:os"
import "core:time"
import "core:time/datetime"
import "core:strings"
import "core:encoding/json"
import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"
import "core:sys/windows"
import "base:runtime"
import "core:strconv"
import "core:unicode/utf8"

DockedEvent :: struct {
    timestamp : string,
    event : string,
    StationName : string,
    StationType : string,
    Taxi : bool,
    Multicrew : bool,
    StarSystem : string,
    SystemAddress : i64,
    MarketID : i64,
    StationFaction : StationFactionStruct,
    StationGovernment : string,
    StationGovernment_Localised : string,
    StationServices : []string,
    StationEconomy : string,
    StationEconomy_Localised : string,
    StationEconomies : []Economy,
    DistFromStarLS : f32,
    LandingPads : Pads
}

StationFactionStruct :: struct {
    Name : string
}

Economy :: struct {
    Name : string,
    Name_Localised : string,
    Proportion : f32
}

Pads :: struct{
    Small : u8,
    Medium : u8,
    Large : u8
}

CCDepotEvent :: struct {
    timestamp : string,
    event : string,
    MarketID : i64,
    ConstructionProgress : f32,
    ConstructionComplete : bool,
    ConstructionFailed : bool,
    ResourcesRequired : []Resource
}

Resource :: struct {
    Name : string,
    Name_Localised : string,
    RequiredAmount : i32,
    ProvidedAmount : i32,
    Payment : i32
}

originalMode : windows.DWORD
hStdOut : windows.HANDLE

main :: proc() {
    // Enable virtual terminal processing
    hStdOut = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    mode : windows.DWORD = 0
    if !windows.GetConsoleMode(hStdOut, &mode) do return
    originalMode = mode
    mode |= windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
    if !windows.SetConsoleMode(hStdOut, mode) do return
    windows.SetConsoleCtrlHandler(handler, true) // handle CTRL+C

    defer {
        // Reset ANSI and terminal mode on clean app close
        fmt.print("\x1b[38;5;7m\x1b[17l\x1b[?25h\x1b[48;5;0m")
        windows.SetConsoleMode(hStdOut, originalMode)
    }

    // Set ANSI mode
    fmt.print("\x1b[=14h\x1b[?25l")

    // Clear console, return cursor to 0, 0 & set color
    fmt.println("\x1b[3J\x1b[H\x1b[J\x1b[38;5;208m")

    printArt()

    arena : vmem.Arena
    allocErr := vmem.arena_init_growing(&arena)
    if allocErr != nil do panic("Allocation Error at line 100")
    defer vmem.arena_destroy(&arena)
    arenaAlloc := vmem.arena_allocator(&arena)

    dockedEvents := make(map[string]DockedEvent, arenaAlloc)
    defer delete(dockedEvents)

    // Check if marketdata.json exists, if it doesn't then make marketdata.json, otherwise read marketdata.json
    mDataExists : bool = os.exists("marketdata.json")
    if !mDataExists {
        mData, mErr := json.marshal(dockedEvents, allocator=arenaAlloc)
        if mErr != nil {
            fmt.println("Marshall Error on line 111:", mErr)
            return
        }
        success := os.write_entire_file("marketdata.json", mData)
        if !success {
            fmt.println("Failed to write marketdata.json on line 116")
            return
        }
    } else {
        jsonData, success := os.read_entire_file_from_filename("marketdata.json", arenaAlloc)
        umErr := json.unmarshal(jsonData, &dockedEvents, allocator=arenaAlloc)
        if umErr != nil {
            fmt.println("Unmarshall Error at line 123:", umErr)
            return
        }
    }

    // Check if config.json exists, if it doesn't then make config.json, otherwise read config.json
    config : map[string]string
    defer delete(config)
    configExists : bool = os.exists("config.json")
    if !configExists {
        buildErr : u8 = 0
        config, buildErr = buildConfig(arenaAlloc)
        if buildErr != 0 do return
    } else {
        configRaw, success := os.read_entire_file_from_filename("config.json", arenaAlloc)
        umErr := json.unmarshal(configRaw, &config, allocator=arenaAlloc)
        if umErr != nil {
            fmt.println("Unmarshall Error at line 140:", umErr)
            return
        }
    }

    // Open journal directory and find latest journal
    logPath : string = config["JournalDirectory"]
    handle, err := os.open(logPath)
    if err != nil {
        fmt.println("Open error line 149:", err)
        return
    }
    defer os.close(handle)
    fileInfos, fErr := os.read_dir(handle, 256, arenaAlloc)
    latest : os.File_Info
    latestDelta : datetime.Delta = {0x7fffffffffffffff, 0x7fffffffffffffff, 0}
    for i in fileInfos {
        if !strings.contains(i.name, ".log") do continue
        modTime, _ := time.time_to_datetime(i.modification_time)
        now, _ := time.time_to_datetime(time.now())
        delta, _ := datetime.subtract_datetimes(now, modTime)
        if delta.days > 1 do continue
        if delta.days < latestDelta.days {
            latestDelta = delta
            latest = i
            continue
        }
        if delta.seconds < latestDelta.seconds {
            latestDelta = delta
            latest = i
        }
    }

    // Read file
    logHandle, readErr := os.open(latest.fullpath)
    if readErr != nil {
        fmt.println("Configured Journal Directory:", logPath)
        fmt.println("Does", latest.fullpath, "exist?")
        fmt.println("Read error at line 176, missing file")
        return
    }
    defer os.close(logHandle)
    data, _ := os.read_entire_file_from_handle(logHandle, arenaAlloc)
    dataString : string = string(data)
    lines : []string = strings.split(dataString, "\r\n", arenaAlloc)
    if len(lines) < 1 {
        return
    }

    // Find last Docked Event line
    lastDocked : string
    lastCCDepot : string
    for line in lines {
        // if strings.contains(line, "\"event\":\"Shutdown\"") do return
        if strings.contains(line, "\"event\":\"Docked\"") {
            lastDocked = line
        } else if strings.contains(line, "\"event\":\"ColonisationConstructionDepot\"") {
            lastCCDepot = line
        }
    }

    dEvent : DockedEvent
    cEvent : CCDepotEvent

    if len(lastDocked) > 0 {
        dEvent = deserializeDockedEvent(lastDocked, arenaAlloc)
        if !checkAvoid(dEvent.StationName) {
            printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
            dockedEvents[dEvent.StationName] = dEvent
            writeErr := writeMarketData(dockedEvents, arenaAlloc)
            if writeErr != 0 do return
        }
    }

    if len(lastCCDepot) > 0 {
        marketName : string = "No market name found"
        cEvent = deserializeCCDepotEvent(lastCCDepot, arenaAlloc)
        printCCDEvent(cEvent, marketName)
    }

    fileStat, _ := os.stat(latest.fullpath, arenaAlloc)
    latestDocked : DockedEvent
    latestCCDEvent : CCDepotEvent
    for {
        time.sleep(time.Second)
        current, _ := os.stat(latest.fullpath, arenaAlloc)
        if current.modification_time == fileStat.modification_time do continue
        diff : i64 = current.size - fileStat.size
        buff : [mem.Kilobyte*12]byte
        newBytesRead, rErr := os.read_at(logHandle, buff[:], current.size - diff)
        newData : string = string(buff[:])
        newDataLines : []string = strings.split(newData, "\r\n", arenaAlloc)
        for line in newDataLines {
            // Check for game shutdown, cleanly close program
            if strings.contains(line, "\"event\":\"Shutdown\"") do return
            if strings.contains(line, "\"event\":\"Docked\"") {
                dEvent = deserializeDockedEvent(line, arenaAlloc)
                if !checkAvoid(dEvent.StationName) {
                    printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
                    dockedEvents[dEvent.StationName] = dEvent
                    writeErr := writeMarketData(dockedEvents, arenaAlloc)
                    if writeErr != 0 do return
                    if latestCCDEvent.event != "" do printCCDEvent(latestCCDEvent, latestDocked.StationName)
                }
                if checkAvoid(dEvent.StationName) do latestDocked = dEvent
            }
            if strings.contains(line, "\"event\":\"ColonisationConstructionDepot\"") {
                marketName : string = "No market name found"
                if latestDocked.StationName != "" do marketName = latestDocked.StationName
                fmt.print("\x1b[3J\x1b[H\x1b[J")
                printArt()
                cEvent = deserializeCCDepotEvent(line, arenaAlloc)
                printCCDEvent(cEvent, marketName, arenaAlloc)
                latestCCDEvent = cEvent
            }
        }
        fileStat = current
    }
}

printEconomies :: proc(dEvent : DockedEvent, historic : []Economy) {
    // Return cursor to 0, 0, then clear the terminal
    fmt.print("\x1b[3J\x1b[H\x1b[J")
    printArt()
    // Read out Market values from docked event struct
    if isMarketModified(dEvent.StationEconomies, historic) {
        fmt.println("  Old Market values for", dEvent.StationName, "\b:")
        if len(historic) > 0 {
            for market in historic {
                fmt.printfln("    %s: %.2f", market.Name_Localised, market.Proportion)
            }
        } else do fmt.println("    None")
        fmt.println("  New Market Types for", dEvent.StationName, "\b:")
        for market in dEvent.StationEconomies {
            fmt.printfln("    %s: %.2f", market.Name_Localised, market.Proportion)
        }
    } else {
        fmt.println("  Market values for", dEvent.StationName, "\b:")
        for market in dEvent.StationEconomies {
            fmt.printfln("    %s: %.2f", market.Name_Localised, market.Proportion)
        }
    }
    fmt.println("=======================================")
}

deserializeDockedEvent :: proc(line: string, allocator := context.allocator) -> DockedEvent {
    // Deserialize Docked Event
    dEvent : DockedEvent
    uErr := json.unmarshal_string(line, &dEvent, allocator=allocator)
    if uErr != nil do panic("Unmarshall error at line 290")
    return dEvent
}

deserializeCCDepotEvent :: proc(line : string, allocator := context.allocator) -> CCDepotEvent {
    // Deserialize CCDepot Event
    cEvent : CCDepotEvent
    uErr := json.unmarshal_string(line, &cEvent, allocator=allocator)
    if uErr != nil {
        fmt.println(uErr)
        panic("Unmarshall error at line 298")
    }
    return cEvent
}

writeMarketData :: proc(dockedEvents : map[string]DockedEvent, allocator := context.allocator) -> u8 {
    options : json.Marshal_Options
    options.pretty = true
    dData, mErr := json.marshal(dockedEvents, options, allocator=allocator)
    if mErr != nil {
        fmt.println("Marshall Err on line 309:", mErr)
        return 1
    }
    success := os.write_entire_file("marketdata.json", dData[:])
    if !success {
        fmt.println("Failed to write marketdata.json at line 314")
        return 2
    }
    return 0
}

isMarketModified :: proc(newMarket, historicMarket : []Economy) -> bool {
    return !slice.equal(newMarket, historicMarket)
}

checkAvoid :: proc(stationName : string)  -> bool {
    AVOIDWRITE :[]string: {"Construction Site", "ColonisationShip"}
    for name in AVOIDWRITE {
        if strings.contains(stationName, name) do return true
    }
    return false
}

buildConfig :: proc(allocator := context.allocator) -> (config : map[string]string, err : u8) {
    baseConfig := make(map[string]string, allocator)
    user := os.get_env("USERPROFILE", allocator)
    logPath : string = strings.concatenate({user, "\\Saved Games\\Frontier Developments\\Elite Dangerous"}, allocator)
    baseConfig["JournalDirectory"] = logPath
    mOpt : json.Marshal_Options
    mOpt.pretty = true
    data, mErr := json.marshal(baseConfig, mOpt, allocator)
    if mErr != nil {
        fmt.println("Marshall Error on line 341:", mErr)
        return baseConfig, 1
    }
    success := os.write_entire_file("config.json", data)
    if !success {
        fmt.println("Failed to write config.json on line 346")
        return baseConfig, 2
    }
    return baseConfig, 0
}

printArt :: proc() {
    fmt.println(" ______ _____    __  __            _        _     _______             _             ")
    fmt.println("|  ____|  __ \\  |  \\/  |          | |      | |   |__   __|           | |            ")
    fmt.println("| |__  | |  | | | \\  / | __ _ _ __| | _____| |_     | |_ __ __ _  ___| | _____ _ __ ")
    fmt.println("|  __| | |  | | | |\\/| |/ _` | '__| |/ / _ \\ __|    | | '__/ _` |/ __| |/ / _ \\ '__|")
    fmt.println("| |____| |__| | | |  | | (_| | |  |   <  __/ |_     | | | | (_| | (__|   <  __/ |   ")
    fmt.println("|______|_____/  |_|  |_|\\__,_|_|  |_|\\_\\___|\\__|    |_|_|  \\__,_|\\___|_|\\_\\___|_|   ")
    fmt.println("=======================================")
}

handler :: proc "std" (signal : windows.DWORD) -> windows.BOOL {
    // Handle CTRL+C, reset ANSI values upon leaving the program
    ctx : runtime.Context = runtime.default_context()
    context = ctx
    if signal == windows.CTRL_C_EVENT {
        fmt.print("\x1b[38;5;7m\x1b[17l\x1b[?25h\x1b[48;5;0m")
        windows.SetConsoleMode(hStdOut, originalMode)
        windows.ExitProcess(1)
    }
    return windows.FALSE
}

printCCDEvent :: proc(cEvent : CCDepotEvent, marketName : string, allocator := context.allocator) {
    fmt.printfln("  %s %v %s : %.2f%% Complete", cEvent.event, cEvent.MarketID, marketName, cEvent.ConstructionProgress * 100)
    r1, r2 := slice.split_at(cEvent.ResourcesRequired, len(cEvent.ResourcesRequired)/2)
    r := soa_zip(left=r1, right=r2)
    for resource in r {
        fmt.println(formatCCDEventResource(resource, allocator))
    }
    fmt.println("=======================================")
}

// Dynamically format CCDEvent Resource #soa array into a single line string
// Highlight section green if the haul for a specific resource has been finished for
// the last construction site landed at.
formatCCDEventResource :: proc(resource : struct {left,right:Resource}, allocator := context.allocator) -> string {
    leftDiff := resource.left.RequiredAmount - resource.left.ProvidedAmount
    rightDiff := resource.right.RequiredAmount - resource.right.ProvidedAmount
    leftProvided : string = itoa(resource.left.ProvidedAmount, allocator)
    leftRequired : string = itoa(resource.left.RequiredAmount, allocator)
    leftDiffStr : string = itoa(leftDiff, allocator)
    rightProvided : string = itoa(resource.right.ProvidedAmount, allocator)
    rightRequired : string = itoa(resource.right.RequiredAmount, allocator)
    rightDiffStr : string = itoa(rightDiff, allocator)
    leftLine, rightLine : string
    leftLineClean : string
    leftFront : string = strings.concatenate({"    ", resource.left.Name_Localised}, allocator)
    beforeColonRunes : [dynamic]rune
    defer delete(beforeColonRunes)
    for _ in 0..< 30 - len(leftFront) {
        append(&beforeColonRunes, ' ')
    }
    beforeColonLeft : string = utf8.runes_to_string(beforeColonRunes[:], allocator)
    strArrayClean : []string = {
        leftFront,
        beforeColonLeft,
        ": ",
        leftProvided,
        "/",
        leftRequired,
        " (",
        leftDiffStr,
        ")"
    }
    leftLineClean = strings.concatenate(strArrayClean[:], allocator)    
    if leftDiff > 0 {
        leftLine = leftLineClean
    } else {
        strArray : []string = {
            "\x1b[48;5;22m",
            leftFront,
            beforeColonLeft,
            ": ",
            leftProvided,
            "/",
            leftRequired,
            " (",
            leftDiffStr,
            ")",
            "\x1b[48;5;0m"
        }
        leftLine = strings.concatenate(strArray[:], allocator)
    }
    clear(&beforeColonRunes)
    for _ in 0..< 55 - len(leftLineClean) do append(&beforeColonRunes, ' ')
    beforeRight : string = utf8.runes_to_string(beforeColonRunes[:], allocator)
    clear(&beforeColonRunes)
    for _ in 0..< 30 - len(resource.right.Name_Localised) do append(&beforeColonRunes, ' ')
    if rightDiff > 0 {
        strArray : []string = {
            beforeRight,
            resource.right.Name_Localised,
            utf8.runes_to_string(beforeColonRunes[:], allocator),
            ": ",
            rightProvided,
            "/",
            rightRequired,
            " (",
            rightDiffStr,
            ")"
        }
        rightLine = strings.concatenate(strArray[:], allocator)
    } else {
        strArray : []string = {
            beforeRight,
            "\x1b[48;5;22m",
            resource.right.Name_Localised,
            utf8.runes_to_string(beforeColonRunes[:], allocator),
            ": ",
            rightProvided,
            "/",
            rightRequired,
            " (",
            rightDiffStr,
            ")",
            "\x1b[48;5;0m"
        }
        rightLine = strings.concatenate(strArray[:], allocator)
    }
    finalLine : string = strings.concatenate({leftLine, rightLine}, allocator)
    return finalLine
}

itoa :: proc(number : i32, allocator := context.allocator) -> string {
    buffer := make([]byte, 256, allocator)
    str : string = strconv.itoa(buffer[:], int(number))
    return str
}
