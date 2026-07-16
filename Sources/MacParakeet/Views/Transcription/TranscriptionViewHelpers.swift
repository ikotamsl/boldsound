func truncateErrorMessage(_ msg: String) -> String {
    if msg.contains("dyld") || msg.contains("Library not loaded") {
        return "Library loading failed"
    }
    let firstLine = msg.prefix(while: { $0 != "\n" })
    if firstLine.count > 120 {
        return String(firstLine.prefix(117)) + "..."
    }
    return String(firstLine)
}
