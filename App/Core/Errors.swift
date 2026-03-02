import Foundation

enum OverseerError: Error, CustomStringConvertible {
    case handled
    case invalidArguments(String)
    case invalidConfig(String)
    case io(String)
    case commandTimedOut(String)
    case commandFailed(String)
    case system(String)

    var description: String {
        switch self {
        case .handled:
            return "handled"
        case let .invalidArguments(message),
             let .invalidConfig(message),
             let .io(message),
             let .commandTimedOut(message),
             let .commandFailed(message),
             let .system(message):
            return message
        }
    }
}
