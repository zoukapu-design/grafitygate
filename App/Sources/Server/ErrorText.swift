import Foundation
import Supabase

/// サーバーの決まりで断られたときの理由を、分かりやすい言葉にする。
enum ErrorText {
    static func of(_ error: Error) -> String {
        // 画面を離れた・引っぱって読み直したときに止めたものは、間違いとして出さない
        if isCancellation(error) { return "" }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "インターネットにつながっていません。電波の良い所でもう一度お試しください。"
            case .timedOut:
                return "通信に時間がかかりすぎました。電波の良い所でもう一度お試しください。"
            default:
                break
            }
        }
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
            return "サーバーの準備がまだです（Supabase に Grafity Gate の SQL を入れてください）。"
        }
        if (error as? URLError) != nil {
            return "通信できませんでした。電波の良い所でもう一度お試しください。"
        }
        return message
    }

    /// 止めた処理（画面を閉じた・読み直した）
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? URLError, e.code == .cancelled { return true }
        return (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }

    /// サーバーに関数がまだ無い（新しい SQL を入れる前）
    static func isMissingFunction(_ error: Error) -> Bool {
        let message = (error as? PostgrestError)?.message ?? error.localizedDescription
        return message.contains("Could not find the function") || message.contains("PGRST202")
    }

    /// サーバーの表に列がまだ無い（新しい SQL を入れる前）
    static func isMissingColumn(_ error: Error) -> Bool {
        let message = (error as? PostgrestError)?.message ?? error.localizedDescription
        let code = (error as? PostgrestError)?.code ?? ""
        return code == "42703" || code == "PGRST204" || (message.contains("column") && message.contains("does not exist"))
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
        ("gf_artwork_limit", "1 つの GATE に置ける作品は、1 人 3 つまでです。前の作品を消すと置けます。"),
        ("gf_gate_full", "この GATE には、もう作品を置けません（30 個まで）。"),
        ("gf_bad_rules", "作品の動きの設定を読み取れませんでした。アプリを新しくしてからお試しください。"),
        ("gf_bad_artwork", "作品を置けませんでした。扉から 4m 以内・地面から 3.5m までの所に置いてください。"),
        ("gf_revision_conflict", "ほかの iPhone で先に動かされていました。いまの位置を読み込み直しました。"),
        ("gf_bad_post", "書けませんでした。題や本文の長さを確かめてください。"),
        ("gf_bad_recipient", "お互いにフォローしている友達にだけ送れます。"),
        ("gf_recipient_cannot_see", "その友達は、この GATE を見られません（GATE の公開範囲が合いません）。"),
        ("gf_bad_open_at", "開く日時は、これから先 10 年までの間で選んでください。"),
        ("gf_bad_letter", "手紙を書けませんでした。本文（2000 文字まで）と、開く条件（日時か現地）を確かめてください。"),
        ("gf_letter_not_yet", "まだ開く日になっていません。"),
        ("gf_letter_onsite", "この手紙は、現地で扉を開けると読めます。"),
        ("gf_memory_full", "この思い出には、もう写真・動画・声を足せません。"),
        ("gf_bad_media", "動画は 15 秒まで、声は 60 秒までです。もう一度お試しください。"),
        ("gf_bad_report", "通報を送れませんでした。理由を選び直してください。"),
        ("gf_bad_trail", "TRAIL は、ちがう GATE を 2〜20 か所つないで作れます。題も入れてください。"),
        ("gf_trail_not_visited", "TRAIL には、自分が扉を開けたことのある GATE だけを入れられます。"),
        ("gf_not_found", "見つかりませんでした。"),
        ("gf_not_signed_in", "サーバーにつながっていません。アプリを開き直してください。"),
        ("gf_terms_required", "利用規約への同意が必要です。アプリを開き直して、同意の画面から進んでください。"),
        ("gf_bad_terms", "規約が新しくなりました。アプリを開き直して、もう一度同意してください。"),
    ]
}
