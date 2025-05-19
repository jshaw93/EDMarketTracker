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
import edlib "../odin-EDLib"

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
    if allocErr != nil do panic("Allocation Error at line 46")
    defer vmem.arena_destroy(&arena)
    arenaAlloc := vmem.arena_allocator(&arena)

    dockedEvents := make(map[string]edlib.DockedEvent, arenaAlloc)
    defer delete(dockedEvents)

    // Check if marketdata.json exists, if it doesn't then make marketdata.json, otherwise read marketdata.json
    mDataExists : bool = os.exists("marketdata.json")
    if !mDataExists {
        mData, mErr := json.marshal(dockedEvents, allocator=arenaAlloc)
        if mErr != nil {
            fmt.println("Marshall Error on line 57:", mErr)
            return
        }
        success := os.write_entire_file("marketdata.json", mData)
        if !success {
            fmt.println("Failed to write marketdata.json on line 62")
            return
        }
    } else {
        jsonData, success := os.read_entire_file_from_filename("marketdata.json", arenaAlloc)
        umErr := json.unmarshal(jsonData, &dockedEvents, allocator=arenaAlloc)
        if umErr != nil {
            fmt.println("Unmarshall Error at line 69:", umErr)
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
            fmt.println("Unmarshall Error at line 86:", umErr)
            return
        }
    }

    // Open journal directory and find latest journal
    logPath : string = config["JournalDirectory"]
    handle, err := os.open(logPath)
    if err != nil {
        fmt.println("Open error line 95:", err)
        return
    }
    defer os.close(handle)
    fileInfos, fErr := os.read_dir(handle, 8192, arenaAlloc)
    latest : os.File_Info
    latestDelta : datetime.Delta = {0x7fffffffffffffff, 0x7fffffffffffffff, 0}
    for i in fileInfos {
        if !strings.contains(i.name, ".log") do continue
        modTime, _ := time.time_to_datetime(i.modification_time)
        now, _ := time.time_to_datetime(time.now())
        delta, _ := datetime.subtract_datetimes(now, modTime)
        if delta.days > 5 do continue
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
        fmt.println("Read error at line 122, missing file")
        fmt.printfln("Read error: %s", readErr)
        fmt.println("Len FileInfos:", len(fileInfos))
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

    dEvent : edlib.DockedEvent
    cEvent : edlib.CCDepotEvent
    uErr : json.Unmarshal_Error

    if len(lastDocked) > 0 {
        dEvent, uErr = edlib.deserializeDockedEvent(lastDocked, arenaAlloc)
        if uErr != nil {
            fmt.printfln("Unmarshall Error at line 156: %s", uErr)
            return
        }
        if !checkAvoid(dEvent.StationName) {
            printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
            dockedEvents[dEvent.StationName] = dEvent
            writeErr := writeMarketData(dockedEvents, arenaAlloc)
            if writeErr != 0 do return
        }
    }

    if len(lastCCDepot) > 0 {
        marketName : string = "No market name found"
        cEvent, uErr = edlib.deserializeCCDepotEvent(lastCCDepot, arenaAlloc)
        if uErr != nil {
            fmt.printfln("Unmarshall Error at line 171: %s", uErr)
            return
        }
        printCCDEvent(cEvent, marketName)
    }

    fileStat, _ := os.stat(latest.fullpath, arenaAlloc)
    latestDocked : edlib.DockedEvent
    latestCCDEvent : edlib.CCDepotEvent
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
                dEvent, uErr = edlib.deserializeDockedEvent(line, arenaAlloc)
                if uErr != nil {
                    fmt.printfln("Unmarshall Error at line 195: %s", uErr)
                    return
                }
                if !checkAvoid(dEvent.StationName) {
                    printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
                    dockedEvents[dEvent.StationName] = dEvent
                    writeErr := writeMarketData(dockedEvents, arenaAlloc)
                    if writeErr != 0 do return
                    if latestCCDEvent.event != "" && latestCCDEvent.ConstructionProgress != 1.0 {
                        printCCDEvent(latestCCDEvent, latestDocked.StationName)
                    }
                }
                if checkAvoid(dEvent.StationName) do latestDocked = dEvent
            }
            if strings.contains(line, "\"event\":\"ColonisationConstructionDepot\"") {
                marketName : string = "No market name found"
                if latestDocked.StationName != "" do marketName = latestDocked.StationName
                cEvent, uErr = edlib.deserializeCCDepotEvent(line, arenaAlloc)
                if uErr != nil {
                    fmt.printfln("Unmarshall Error at line 214: %s", uErr)
                    return
                }
                fmt.print("\x1b[3J\x1b[H\x1b[J")
                printArt()
                printCCDEvent(cEvent, marketName, arenaAlloc)
                latestCCDEvent = cEvent
            }
        }
        fileStat = current
    }
}

printEconomies :: proc(dEvent : edlib.DockedEvent, historic : []edlib.Economy) {
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
        fmt.println("  New Market values for", dEvent.StationName, "\b:")
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

writeMarketData :: proc(dockedEvents : map[string]edlib.DockedEvent, allocator := context.allocator) -> u8 {
    options : json.Marshal_Options
    options.pretty = true
    dData, mErr := json.marshal(dockedEvents, options, allocator=allocator)
    if mErr != nil {
        fmt.println("Marshall Err on line 257:", mErr)
        return 1
    }
    success := os.write_entire_file("marketdata.json", dData[:])
    if !success {
        fmt.println("Failed to write marketdata.json at line 262")
        return 2
    }
    return 0
}

isMarketModified :: proc(newMarket, historicMarket : []edlib.Economy) -> bool {
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
        fmt.println("Marshall Error on line 289:", mErr)
        return baseConfig, 1
    }
    success := os.write_entire_file("config.json", data)
    if !success {
        fmt.println("Failed to write config.json on line 294")
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

printCCDEvent :: proc(cEvent : edlib.CCDepotEvent, marketName : string, allocator := context.allocator) {
    fmt.printfln("  %s %v %s : %.2f%% Complete\n", cEvent.event, cEvent.MarketID, marketName, cEvent.ConstructionProgress * 100)
    r1, r2 := slice.split_at(cEvent.ResourcesRequired, len(cEvent.ResourcesRequired)/2)
    r := soa_zip(left=r1, right=r2)
    for resource in r {
        fmt.println(formatCCDEventResourceSOAZip(resource, allocator))
    }
    if len(r2) > len(r1) {
        line, _ := formatCCDEventResourceSingle(r2[len(r2)-1])
        line = strings.concatenate({"    ", line}, allocator)
        fmt.printfln(line)
    }
    fmt.println("=======================================")
}

// Dynamically format CCDEvent Resource #soa array into a single line string
// Highlight section green if the haul for a specific resource has been finished for
// the last construction site landed at.
formatCCDEventResourceSOAZip :: proc(resourceSOA : struct {left,right:edlib.Resource}, allocator := context.allocator) -> string {
    leftLine, leftLineClean := formatCCDEventResourceSingle(resourceSOA.left, allocator)
    leftLine = strings.concatenate({"    ", leftLine}, allocator)
    rightLine, _ := formatCCDEventResourceSingle(resourceSOA.right, allocator)
    beforeResourceRunes := make([dynamic]rune, allocator)
    defer delete(beforeResourceRunes)
    for _ in 0..< 55 - len(leftLineClean) do append(&beforeResourceRunes, ' ')
    beforeRight : string = utf8.runes_to_string(beforeResourceRunes[:], allocator)
    strArray : []string = {
        beforeRight,
        rightLine
    }
    rightLine = strings.concatenate(strArray[:], allocator)
    finalLine : string = strings.concatenate({leftLine, rightLine}, allocator)
    return finalLine
}

formatCCDEventResourceSingle :: proc(resource : edlib.Resource, allocator := context.allocator) -> (line, lineClean : string) {
    diff := resource.RequiredAmount - resource.ProvidedAmount
    provided : string = itoa(resource.ProvidedAmount, allocator)
    required : string = itoa(resource.RequiredAmount, allocator)
    diffStr : string = itoa(diff, allocator)
    front : string = resource.Name_Localised
    beforeColonRunes : [dynamic]rune
    defer delete(beforeColonRunes)
    for _ in 0..< 30 - len(front) do append(&beforeColonRunes, ' ')
    beforeColon : string = utf8.runes_to_string(beforeColonRunes[:], allocator)
    strArrayClean : []string = {
        front,
        beforeColon,
        ": ",
        provided,
        "/",
        required,
        " (",
        diffStr,
        ")"
    }
    lineClean = strings.concatenate(strArrayClean[:], allocator)
    if diff > 0 {
        line = lineClean
    } else {
        strArray : []string = {
            "\x1b[48;5;22m",
            front,
            beforeColon,
            ": ",
            provided,
            "/",
            required,
            " (",
            diffStr,
            ")",
            "\x1b[48;5;0m"
        }
        line = strings.concatenate(strArray[:], allocator)
    }
    return line, lineClean
}

itoa :: proc(number : i32, allocator := context.allocator) -> string {
    buffer := make([]byte, 256, allocator)
    str : string = strconv.itoa(buffer[:], int(number))
    return str
}
