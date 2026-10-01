// What the push service said, and what that means for a subscription. Pure, so it can be tested.
import Foundation

enum PushResult: Equatable {
    case delivered
    /// 404/410: the phone unsubscribed, so the subscription should go.
    case gone
    case failed(String)

    /// `WebPush.post` returns nil for success, "gone" for 404/410, and a message otherwise.
    static func from(_ raw: String?) -> PushResult {
        switch raw {
        case nil: .delivered
        case "gone"?: .gone
        case let message?: .failed(message)
        }
    }

    /// What to tell someone who pressed Test.
    var testMessage: String? {
        switch self {
        case .delivered: nil
        case .gone: "The phone unsubscribed. Turn reminders on again in Upkeep on the phone."
        case .failed(let message): message
        }
    }
}
