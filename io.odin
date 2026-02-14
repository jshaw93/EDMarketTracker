package markettracker

import "core:os"
import "core:strings"
import "core:encoding/json"
import edlib "../odin-EDLib"
import "core:fmt"

buildConfig :: proc(allocator := context.allocator) -> (config : map[string]string, err : ConfigBuildError) {
    baseConfig := make(map[string]string, allocator)
    user := os.get_env("USERPROFILE", allocator)
    logPath : string = strings.concatenate({user, "\\Saved Games\\Frontier Developments\\Elite Dangerous"}, allocator)
    baseConfig["JournalDirectory"] = logPath
    mOpt : json.Marshal_Options
    mOpt.pretty = true
    data, mErr := json.marshal(baseConfig, mOpt, allocator)
    if mErr != nil {
        return baseConfig, .MarshalError
    }
    writeErr := os.write_entire_file("config.json", data)
    if writeErr != nil {
        return baseConfig, .WriteError
    }
    return baseConfig, nil
}

writeMarketData :: proc(dockedEvents : map[string]edlib.DockedEvent) -> MarketDataError {
    defer free_all(context.temp_allocator)
    options : json.Marshal_Options
    options.pretty = true
    dData, mErr := json.marshal(dockedEvents, options, allocator=context.temp_allocator)
    if mErr != nil {
        fmt.printfln("Marshal Error: %s", mErr)
        return .MarshalError
    }
    writeErr := os.write_entire_file("marketdata.json", dData[:])
    if writeErr != nil {
        return .WriteError
    }
    return nil
}
