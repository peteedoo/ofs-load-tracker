import Foundation
import AppKit

enum LoadActions {
    static func draftCheckin(loadID: String, greeting: String) async throws {
        let escGreet = greeting.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Mail"
            set msgs to (every message of inbox whose subject contains "\(loadID)")
            if (count of msgs) is 0 then return "no messages"
            set latest to item 1 of msgs
            set origSender to sender of latest
            set origDate to date received of latest as string
            set origBody to ""
            try
                set origBody to content of latest
            end try
            set quoted to ""
            set lns to paragraphs of origBody
            repeat with ln in lns
                set quoted to quoted & "> " & (ln as string) & return
            end repeat
            set bodyText to "Hey \(escGreet) — checking in on this one. Did we get delivered? If so, can you send the POD over?" & return & return & "Thanks," & return & "Petee" & return & return & "On " & origDate & ", " & origSender & " wrote:" & return & quoted
            set replyMsg to reply latest opening window yes reply to all yes
            delay 0.4
            tell replyMsg to set content to bodyText
            activate
            return "ok"
        end tell
        """
        _ = try await runScript(script)
    }

    static func forwardPOD(loadID: String) async throws {
        let script = """
        tell application "Mail"
            set candidates to (every message of inbox whose subject contains "\(loadID)")
            set podMsg to missing value
            repeat with m in candidates
                try
                    set s to sender of m
                    if s does not contain "@onlinefreight.com" then
                        set atts to mail attachments of m
                        repeat with a in atts
                            set nm to name of a
                            if (nm contains ".pdf") or (nm contains "POD") or (nm contains "BOL") or (nm starts with "CamScanner") then
                                set podMsg to m
                                exit repeat
                            end if
                        end repeat
                        if podMsg is not missing value then exit repeat
                    end if
                end try
            end repeat
            if podMsg is missing value then return "no pod"
            set fwdMsg to forward podMsg opening window yes
            tell fwdMsg
                set subject to "POD Load # \(loadID)"
                set content to "See attached, thank you :)" & return & return
                make new to recipient at end of to recipients with properties {address:"accounting@onlinefreight.com"}
            end tell
            activate
            return "ok"
        end tell
        """
        _ = try await runScript(script)
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func runScript(_ script: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/usr/bin/osascript"
            proc.arguments = ["-e", script]
            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if proc.terminationStatus != 0 {
                let msg = String(data: errData, encoding: .utf8) ?? "unknown"
                throw NSError(domain: "osascript", code: Int(proc.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}
