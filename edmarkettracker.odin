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
import edlib "../odin-EDLib"

ORIGINAL_MODE : windows.DWORD
hStdOut : windows.HANDLE

main :: proc() {
    // Enable virtual terminal processing
    hStdOut = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    mode : windows.DWORD = 0
    if !windows.GetConsoleMode(hStdOut, &mode) do return
    ORIGINAL_MODE = mode
    mode |= windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
    if !windows.SetConsoleMode(hStdOut, mode) do return
    windows.SetConsoleCtrlHandler(handler, true) // handle CTRL+C

    defer {
        // Reset ANSI and terminal mode on clean app close
        fmt.print("\x1b[38;5;7m\x1b[17l\x1b[?25h\x1b[48;5;0m")
        windows.SetConsoleMode(hStdOut, ORIGINAL_MODE)
    }

    // Set ANSI mode
    fmt.print("\x1b[=14h\x1b[?25l")

    // Clear console, return cursor to 0, 0 & set color
    fmt.println("\x1b[3J\x1b[H\x1b[J\x1b[38;5;208m")

    printArt()

    arena : vmem.Arena
    allocErr := vmem.arena_init_growing(&arena)
    if allocErr != nil do panic("Allocation Error at line 45")
    defer vmem.arena_destroy(&arena)
    arenaAlloc := vmem.arena_allocator(&arena)

    dockedEvents := make(map[string]edlib.DockedEvent, arenaAlloc)
    defer delete(dockedEvents)

    // Check if marketdata.json exists, if it doesn't then make marketdata.json, otherwise read marketdata.json
    mDataExists : bool = os.exists("marketdata.json")
    if !mDataExists {
        mData, mErr := json.marshal(dockedEvents, allocator=arenaAlloc)
        if mErr != nil {
            fmt.println("Marshall Error on line 56:", mErr)
            return
        }
        writeErr := os.write_entire_file("marketdata.json", mData)
        if writeErr != nil {
            fmt.printfln("Failed to write marketdata.json on line 61: %s", writeErr)
            return
        }
    } else {
        jsonData, success := os.read_entire_file_from_path("marketdata.json", arenaAlloc)
        umErr := json.unmarshal(jsonData, &dockedEvents, allocator=arenaAlloc)
        if umErr != nil {
            fmt.println("Unmarshall Error at line 68:", umErr)
            return
        }
    }

    // Check if config.json exists, if it doesn't then make config.json, otherwise read config.json
    config : map[string]string
    defer delete(config)
    configExists : bool = os.exists("config.json")
    if !configExists {
        buildErr : ConfigBuildError
        config, buildErr = buildConfig(arenaAlloc)
        if buildErr != nil {
            if buildErr == .MarshalError {
                fmt.println("Marshal Error on line 81")
            }
            if buildErr == .WriteError {
                fmt.println("Failed to write config.json on line 81")
            }
            return
        }
    } else {
        configRaw, readErr := os.read_entire_file_from_path("config.json", arenaAlloc)
        umErr := json.unmarshal(configRaw, &config, allocator=arenaAlloc)
        if umErr != nil {
            fmt.println("Unmarshall Error at line 93:", umErr)
            return
        }
    }

    // Open journal directory and find latest journal
    logPath : string = config["JournalDirectory"]
    handle, err := os.open(logPath)
    if err != nil {
        fmt.println("Open error line 102:", err)
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
        fmt.println("Read error at line 129, missing file")
        fmt.printfln("Read error: %s", readErr)
        fmt.println("Len FileInfos:", len(fileInfos))
        return
    }
    defer os.close(logHandle)
    data, _ := os.read_entire_file_from_file(logHandle, arenaAlloc)
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
            fmt.printfln("Unmarshall Error at line 163: %s", uErr)
            return
        }
        if !checkAvoid(dEvent.StationName) {
            printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
            dockedEvents[dEvent.StationName] = dEvent
            writeErr := writeMarketData(dockedEvents)
            if writeErr != nil {
                if writeErr == .MarshalError {
                    fmt.println("Marshal Error at line 171")
                }
                if writeErr == .WriteError {
                    fmt.println("Write Error at line 171")
                }
                return
            }
        }
    }

    if len(lastCCDepot) > 0 {
        marketName : string = "No market name found"
        cEvent, uErr = edlib.deserializeCCDepotEvent(lastCCDepot, arenaAlloc)
        if uErr != nil {
            fmt.printfln("Unmarshall Error at line 186: %s", uErr)
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
                    fmt.printfln("Unmarshall Error at line 210: %s", uErr)
                    return
                }
                if !checkAvoid(dEvent.StationName) {
                    printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
                    dockedEvents[dEvent.StationName] = dEvent
                    writeMarketDataErr := writeMarketData(dockedEvents)
                    if writeMarketDataErr != nil do return
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
                    fmt.printfln("Unmarshall Error at line 229: %s", uErr)
                    return
                }
                fmt.print("\x1b[3J\x1b[H\x1b[J")
                printArt()
                printCCDEvent(cEvent, marketName)
                latestCCDEvent = cEvent
            }
        }
        fileStat = current
    }
}

isMarketModified :: proc(newMarket, historicMarket : []edlib.Economy) -> bool {
    return !slice.equal(newMarket, historicMarket)
}

checkAvoid :: proc(stationName : string)  -> bool {
    AVOIDWRITE :[]string: {"Construction Site", "ColonisationShip"}
    for partial in AVOIDWRITE {
        if strings.contains(stationName, partial) do return true
    }
    return false
}

handler :: proc "std" (signal : windows.DWORD) -> windows.BOOL {
    // Handle CTRL+C, reset ANSI values upon leaving the program
    ctx : runtime.Context = runtime.default_context()
    context = ctx
    if signal == windows.CTRL_C_EVENT {
        fmt.print("\x1b[38;5;7m\x1b[17l\x1b[?25h\x1b[48;5;0m")
        windows.SetConsoleMode(hStdOut, ORIGINAL_MODE)
        windows.ExitProcess(1)
    }
    return windows.FALSE
}

itoa :: proc(number : i32, allocator := context.allocator) -> string {
    buffer := make([]byte, 256, allocator)
    str : string = strconv.write_int(buffer[:], i64(number), 10)
    return str
}

sortMaterials :: proc(resources : []edlib.Resource, allocator := context.allocator) -> []edlib.Resource {
    chem, consumer, food, ind, mach, med, metal, tech, text, waste, weap : [dynamic]edlib.Resource
    defer {
        delete(chem)
        delete(consumer)
        delete(food)
        delete(ind)
        delete(mach)
        delete(med)
        delete(metal)
        delete(tech)
        delete(text)
        delete(waste)
        delete(weap)
    }
    for resource in resources {
        switch resource.Name_Localised {
            case "Liquid oxygen", "Pesticides", "Surface Stabilisers", "Water":
                append_elem(&chem, resource)
            case "Evacuation Shelter", "Survival Equipment":
                append_elem(&consumer, resource)
            case "Food Cartridges", "Fruit and Vegetables", "Grain":
                append_elem(&food, resource)
            case "Ceramic Composites", "CMM Composite", "Insulating Membrane", "Polymers", "Semiconductors", "Superconductors":
                append_elem(&ind, resource)
            case "Building Fabricators", "Crop Harvesters", "Emergency Power Cells", "Geological Equipment", "Microbial Furnaces", "Mineral Extractors", "Power Generators", "Thermal Cooling Units", "Water Purifiers":
                append_elem(&mach, resource)
            case "Agri-Medicines", "Basic Medicines", "Combat Stabilisers":
                append_elem(&med, resource)
            case "Aluminium", "Copper", "Steel", "Titanium":
                append_elem(&metal, resource)
            case "Advanced Catalysers", "Bioreducing Lichen", "Computer Components", "H.E. Suits", "Land Enrichment Systems", "Medical Diagnostic Equipment", "Micro Controllers", "Muon Imager", "Resonating Separators", "Robotics", "Structural Regulators":
                append_elem(&tech, resource)
            case "Military Grade Fabrics":
                append_elem(&text, resource)
            case "Biowaste":
                append_elem(&waste, resource)
            case "Battle Weapons", "Non-Lethal Weapons", "Reactive Armour":
                append_elem(&weap, resource)
            case:
                fmt.println("Not in cases:", resource.Name_Localised)
        }
    }
    resStage1 : [][]edlib.Resource = {
        chem[:], consumer[:], food[:], ind[:], mach[:], med[:], metal[:], tech[:], text[:], waste[:], weap[:]
    }
    resStage2, concatErr := slice.concatenate(resStage1, allocator)
    if concatErr != nil do panic("Concatenation Error on line 320")
    return resStage2
}
