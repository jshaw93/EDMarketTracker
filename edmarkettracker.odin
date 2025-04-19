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

main :: proc() {
    // Enable virtual terminal processing
    hStdOut := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    mode : windows.DWORD = 0
    if !windows.GetConsoleMode(hStdOut, &mode) do return
    originalMode : windows.DWORD = mode
    mode |= windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
    if !windows.SetConsoleMode(hStdOut, mode) do return
    defer windows.SetConsoleMode(hStdOut, originalMode)

    // Set ANSI mode
    fmt.print("\x1b[=14h")

    // Clear console & return cursor to 0, 0
    fmt.println("\x1b[2J\x1b[H")

    arena : vmem.Arena
    allocErr := vmem.arena_init_growing(&arena)
    if allocErr != nil do panic("Allocation Error at line 54")
    defer vmem.arena_destroy(&arena)
    arenaAlloc := vmem.arena_allocator(&arena)

    dockedEvents := make(map[string]DockedEvent, arenaAlloc)
    defer delete(dockedEvents)

    // Check if marketdata.json exists, if it doesn't then make marketdata.json, otherwise read marketdata.json
    mDataExists : bool = os.exists("marketdata.json")
    if !mDataExists {
        mData, mErr := json.marshal(dockedEvents, allocator=arenaAlloc)
        if mErr != nil {
            fmt.println("Marshall Error on line 65:", mErr)
            return
        }
        success := os.write_entire_file("marketdata.json", mData)
        if !success {
            fmt.println("Failed to write marketdata.json on line 70")
            return
        }
    } else {
        jsonData, success := os.read_entire_file_from_filename("marketdata.json", arenaAlloc)
        umErr := json.unmarshal(jsonData, &dockedEvents, allocator=arenaAlloc)
        if umErr != nil {
            fmt.println("Unmarshall Error at line 77:", umErr)
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
            fmt.println("Unmarshall Error at line 94:", umErr)
            return
        }
    }

    // Open journal directory and find latest journal
    logPath : string = config["JournalDirectory"]
    handle, err := os.open(logPath)
    if err != nil {
        fmt.println("Open error line 103:", err)
        return
    }
    defer os.close(handle)
    fileInfos, fErr := os.read_dir(handle, 256, arenaAlloc)
    latest : os.File_Info
    latestDelta : datetime.Delta = {0x7fffffffffffffff, 0, 0}
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
        fmt.println("Does", latest.fullpath, "exist?")
        fmt.println("Read error at line 130, missing file")
        return
    }
    defer os.close(logHandle)
    data, _ := os.read_entire_file_from_handle(logHandle, arenaAlloc)
    dataString : string = string(data)
    lines : []string = strings.split(dataString, "\r\n", arenaAlloc)
    if len(lines) < 5 {
        return
    }

    // Find last Docked Event line
    last : string
    for line in lines {
        if !strings.contains(line, "\"event\":\"Docked\"") do continue
        last = line
    }

    dEvent : DockedEvent
    modified : bool

    if len(last) > 0 {
        dEvent = deserializeDockedEvent(last, arenaAlloc)
        if !checkAvoid(dEvent.StationName) {
            printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
            dockedEvents[dEvent.StationName] = dEvent
            writeErr := writeData(dockedEvents, arenaAlloc)
            if writeErr != 0 do return
        }
    }
    fileStat, _ := os.stat(latest.fullpath, arenaAlloc)
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
            if !strings.contains(line, "\"event\":\"Docked\"") do continue
            dEvent = deserializeDockedEvent(line, arenaAlloc)
            if !checkAvoid(dEvent.StationName) {
                printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
                dockedEvents[dEvent.StationName] = dEvent
                writeErr := writeData(dockedEvents, arenaAlloc)
                if writeErr != 0 do return
            }
        }
        fileStat = current
    }
}

printEconomies :: proc(dEvent : DockedEvent, historic : []Economy) {
    // Clear console, return cursor to 0, 0, set color
    fmt.print("\x1b[3J\x1b[H\x1b[38;5;208m")
    printArt()
    fmt.println("=======================================")
    // Read out Market values from docked event struct
    if isMarketModified(dEvent.StationEconomies, historic) {
        fmt.println("\x1b[2K  Old Market values for", dEvent.StationName, "\b:")
        if len(historic) > 0 {
            for market in historic {
                fmt.printfln("\x1b[2K    %s: %.2f", market.Name_Localised, market.Proportion)
            }
        } else do fmt.println("    None")
        fmt.println("\x1b[2K  New Market Types for", dEvent.StationName, "\b:")
        for market in dEvent.StationEconomies {
            fmt.printfln("\x1b[2K    %s: %.2f", market.Name_Localised, market.Proportion)
        }
    } else {
        fmt.println("\x1b[2K  Market values for", dEvent.StationName, "\b:")
        for market in dEvent.StationEconomies {
            fmt.printfln("\x1b[2K    %s: %.2f", market.Name_Localised, market.Proportion)
        }
    }
    fmt.println("=======================================")
    fmt.print("\x1b[38;5;7m") // Reset color
}

deserializeDockedEvent :: proc(line: string, allocator := context.allocator) -> DockedEvent {
    // Deserialize Docked Event
    dEvent : DockedEvent
    uErr := json.unmarshal_string(line, &dEvent, allocator=allocator)
    if uErr != nil do panic("Unmarshall error at line 208")
    return dEvent
}

writeData :: proc(dockedEvents : map[string]DockedEvent, allocator := context.allocator) -> u8 {
    options : json.Marshal_Options
    options.pretty = true
    dData, mErr := json.marshal(dockedEvents, options, allocator=allocator)
    if mErr != nil {
        fmt.println("Marshall Err on line 216:", mErr)
        return 1
    }
    success := os.write_entire_file("marketdata.json", dData[:])
    if !success {
        fmt.println("Failed to write marketdata.json at line 221")
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
        fmt.println("Marshall Error on line 248:", mErr)
        return baseConfig, 1
    }
    success := os.write_entire_file("config.json", data)
    if !success {
        fmt.println("Failed to write config.json on line 253")
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
}
