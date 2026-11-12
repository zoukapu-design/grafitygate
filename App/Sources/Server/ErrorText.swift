import Foundation
import Supabase

/// サーバーの決まりで断られたときの理由を、分かりやすい言葉にする。
enum ErrorText {
    static func of(_ error: Error) -> String {
        let message: String
        if let e = error as? PostgrestError {
            message = e.message
        } else if let e = error as? LocalizedError, let d = e.errorDescription {
            message = d
        } else {
            message = error.localizedDescription
        }
        for (code, text) in known where message.contains(code) {
            return text
        }
        if message.contains("Could not find the function") || message.contains("does not exist") {
            return "サーバーの準備がまだです（Supabase に GRAFITYGATE の SQL を入れてください）。"
        }
        if (error as? URLError) != nil {
            return "通信できませんでした。電波の良い所でもう一度お試しください。"
        }
        return message
    }

    /// 入場がだめだった理由（gf_enter の reason）
    static func enterReason(_ reason: String?) -> String {
        switch reason {
        case "too_far": return "GATE から離れています。GATE の近く（120m 以内）で入れます。"
        case "inaccurate", "bad_position": return "位置の精度が足りません。空の開けた所で少し待ってから、もう一度お試しください。"
        case "no_match": return "写したものが、この GATE と合いませんでした。作った人が写した場所・物を、正面から写してみてください。"
        case "no_reference": return "この GATE の写真の特徴が、いまのアプリと形式が違うため比べられません。"
        case "not_found": return "この GATE は見つかりませんでした（公開範囲が変わったか、閉じられた可能性があります）。"
        case "challenge_used", "challenge_expired", "challenge_invalid": return "時間がたちすぎました。もう一度お試しください。"
        default: return "入れませんでした。もう一度お試しください。"
        }
    }

    private static let known: [(String, String)] = [
        ("gf_already_posted", "この入場では、もう 1 枚書きました。次は入り直してから書けます。"),
        ("gf_repost_cooldown", "同じ GATE には、前に書いてから 12 時間あけると書けます。"),
        ("gf_visit_invalid", "入場の時間（20 分）が切れました。現地でもう一度入ってください。"),
        ("gf_inaccurate", "位置の精度が足りません。空の開けた所で少し待ってから、もう一度お試しください。"),
        ("gf_bad_position", "現在地を確かめられませんでした。"),
        ("gf_rate_limited", "短い時間にたくさん操作されました。少し時間をおいてからお試しください。"),
        ("gf_challenge_used", "時間がたちすぎました。もう一度お試しください。"),
        ("gf_challenge_expired", "時間がたちすぎました。もう一度お試しください。"),
        ("gf_challenge_invalid", "時間がたちすぎました。もう一度お試しください。"),
        ("gf_bad_references", "写真の特徴を作れませんでした。撮り直してください。"),
        ("gf_bad_media_path", "写真を送れませんでした。"),
        ("gf_not_found", "見つかりませんでした。"),
        ("gf_not_signed_in", "サーバーにつながっていません。アプリを開き直してください。"),
    ]
}
