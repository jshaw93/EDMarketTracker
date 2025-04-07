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
    fmt.println("ED Market Tracker is now running!\n")

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
            panic("Marshall Error on line 65")
        }
        success := os.write_entire_file("marketdata.json", mData)
        if !success do panic("Failed to write file")
    } else {
        jsonData, success := os.read_entire_file_from_filename("marketdata.json", arenaAlloc)
        umErr := json.unmarshal(jsonData, &dockedEvents, allocator=arenaAlloc)
        if umErr != nil do panic("Unmarshall Error at line 73")
    }

    // Open journal directory and find latest journal
    user := os.get_env("USERPROFILE", arenaAlloc)
    logPath : string = strings.concatenate({user, "\\Saved Games\\Frontier Developments\\Elite Dangerous"}, arenaAlloc)
    handle, err := os.open(logPath)
    if err != nil do panic("Open error line 80")
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
        panic("Read error at line 105, missing file")
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
    if len(last) == 0 do return

    dEvent : DockedEvent = deserializeDockedEvent(last, arenaAlloc)
    
    modified : bool = isMarketModified(dEvent.StationEconomies, dockedEvents[dEvent.StationName].StationEconomies)
    if modified && !checkAvoid(dEvent.StationName) {
        printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
        dockedEvents[dEvent.StationName] = dEvent
        writeData(dockedEvents, arenaAlloc)
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
            modified = isMarketModified(dEvent.StationEconomies, dockedEvents[dEvent.StationName].StationEconomies)
            if modified && !checkAvoid(dEvent.StationName) {
                printEconomies(dEvent, dockedEvents[dEvent.StationName].StationEconomies)
                dockedEvents[dEvent.StationName] = dEvent
                writeData(dockedEvents, arenaAlloc)
            }
        }
        fileStat = current
    }
}

printEconomies :: proc(dEvent : DockedEvent, historic : []Economy) {
    // Read out Market values from docked event struct
    fmt.println("Old Market values for", dEvent.StationName, "\b:")
    if len(historic) > 0 {
        for market in historic {
            fmt.printfln("    %s: %.2f", market.Name_Localised, market.Proportion)
        }
    } else do fmt.println("    None")
    fmt.println("New Market Types for", dEvent.StationName, "\b:")
    for market in dEvent.StationEconomies {
        fmt.printfln("    %s: %.2f", market.Name_Localised, market.Proportion)
    }
    fmt.println("=======================================")
}

deserializeDockedEvent :: proc(line: string, allocator := context.allocator) -> DockedEvent {
    // Deserialize Docked Event
    dEvent : DockedEvent
    uErr := json.unmarshal_string(line, &dEvent, allocator=allocator)
    if uErr != nil do panic("Unmarshall error at line 176")
    return dEvent
}

writeData :: proc(dockedEvents : map[string]DockedEvent, allocator := context.allocator) {
    options : json.Marshal_Options
    options.pretty = true
    dData, mErr := json.marshal(dockedEvents, options, allocator=allocator)
    if mErr != nil do panic("Marshall Err on line 184:")
    success := os.write_entire_file("marketdata.json", dData[:])
    if !success do panic("Failed to write file")
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
