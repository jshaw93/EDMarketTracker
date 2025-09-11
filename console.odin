package markettracker

import "core:fmt"
import edlib "../odin-EDLib"
import "core:slice"
import "core:strings"

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

printArt :: proc() {
    fmt.println(" ______ _____    __  __            _        _     _______             _             ")
    fmt.println("|  ____|  __ \\  |  \\/  |          | |      | |   |__   __|           | |            ")
    fmt.println("| |__  | |  | | | \\  / | __ _ _ __| | _____| |_     | |_ __ __ _  ___| | _____ _ __ ")
    fmt.println("|  __| | |  | | | |\\/| |/ _` | '__| |/ / _ \\ __|    | | '__/ _` |/ __| |/ / _ \\ '__|")
    fmt.println("| |____| |__| | | |  | | (_| | |  |   <  __/ |_     | | | | (_| | (__|   <  __/ |   ")
    fmt.println("|______|_____/  |_|  |_|\\__,_|_|  |_|\\_\\___|\\__|    |_|_|  \\__,_|\\___|_|\\_\\___|_|   ")
    fmt.println("=======================================")
}

printCCDEvent :: proc(cEvent : edlib.CCDepotEvent, marketName : string) {
    fmt.printfln("  %s %v %s : %.2f%% Complete\n", cEvent.event, cEvent.MarketID, marketName, cEvent.ConstructionProgress * 100)
    resourcesSorted := sortMaterials(cEvent.ResourcesRequired, context.temp_allocator)
    r1, r2 := slice.split_at(resourcesSorted, len(resourcesSorted)/2)
    r := soa_zip(left=r1, right=r2)
    for resource in r {
        fmt.println(formatCCDEventResourceSOAZip(resource, context.temp_allocator))
    }
    if len(r2) > len(r1) {
        line, _ := formatCCDEventResourceSingle(r2[len(r2)-1], context.temp_allocator)
        line = strings.concatenate({"    ", line}, context.temp_allocator)
        fmt.printfln(line)
    }
    fmt.println("=======================================")
    free_all(context.temp_allocator)
}
