import Foundation

/// Keep transport diagnostics actionable without echoing credentials or HTML.
enum ReceiverFailure {
    static func message(status: Int, data: Data, token: String) -> String {
        let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        let raw = object?["error"] as? String
        let reason = raw.map {
            let redacted = token.isEmpty ? $0 : $0.replacingOccurrences(of:token,with:"[redacted]")
            return String(redacted
                .replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ").prefix(180))
        }
        let detail = reason.map {" · "+$0} ?? ""
        let hint: String
        switch status {
        case 401,403: hint = "Enter the token printed by the running receiver in iPhone Setup. --pair changes it on restart; --token-file keeps pairing across restarts. Check that the receiver URL points to the same PC."
        case 404,405: hint = "This receiver URL does not provide live volume. Stop the old receiver and run the updated receiver/server.py; check the saved URL."
        case 408: hint = "The one-second live request expired or arrived ahead of the receiver clock. Sync the receiver computer's time, then activate again."
        case 409: hint = "The volume session is closed, missing, or out of order. Activate again; do not replay the rejected request."
        case 429: hint = "The receiver rejected the update rate. Volume stopped; activate again."
        case 503: hint = "The receiver could not access the audio device. Check its output device and receiver console, then activate again."
        case 400: hint = "The receiver rejected the request format. Update both apps and the receiver."
        default: hint = "Check the receiver console and saved receiver URL."
        }
        return "Receiver HTTP \(status)\(detail). \(hint)"
    }
}
