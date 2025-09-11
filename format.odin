package markettracker

import "core:strings"
import "core:unicode/utf8"
import edlib "../odin-EDLib"

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
    rightLine = strings.concatenate(strArray, allocator)
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
    lineClean = strings.concatenate(strArrayClean, allocator)
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
        line = strings.concatenate(strArray, allocator)
    }
    return line, lineClean
}
