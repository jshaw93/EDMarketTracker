package parser

import "core:fmt"
import "core:os"
import "core:time"
import "core:time/datetime"
import "core:strings"
import "core:encoding/json"
import "core:mem"
import vmem "core:mem/virtual"

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
    Small : i64,
    Medium : i64,
    Large : i64
}

main :: proc() {
    arena : vmem.Arena
    allocErr := vmem.arena_init_growing(&arena)
    if allocErr != nil do fmt.panicf("Allocation Error:", allocErr)
    defer vmem.arena_destroy(&arena)
    arenaAlloc := vmem.arena_allocator(&arena)

    // Open journal directory and find latest journal
    user := os.get_env("USERPROFILE", arenaAlloc)
    logPath : string = strings.concatenate({user, "\\Saved Games\\Frontier Developments\\Elite Dangerous"}, arenaAlloc)
    handle, err := os.open(logPath)
    if err != nil {
        fmt.panicf("Open err:", err)
    }
    fileInfos, fErr := os.read_dir(handle, 256, arenaAlloc)
    latest : os.File_Info
    latestDelta : datetime.Delta = {1500, 0, 0}
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
    data, readErr := os.read_entire_file_from_filename(latest.fullpath, allocator=arenaAlloc)
    if !readErr do fmt.panicf("Read err:", readErr)
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

    // Deserialize Docked Event
    dEvent : DockedEvent
    uErr := json.unmarshal_string(last, &dEvent, allocator=arenaAlloc)
    if uErr != nil do fmt.panicf("Unmarshall error:", uErr)
    
    // Read out Market values from docked event struct
    fmt.println("Market Types for", dEvent.StationName, "\b:")
    for market in dEvent.StationEconomies {
        fmt.printfln("%s: %.2f", market.Name_Localised, market.Proportion)
    }
}
