import Foundation

/// Describe the actual outcome, rather than equating a model call with success.
func cleanupSummary(_ metadata: [String: Any]) -> String {
    let used = metadata["model_used"] as? Bool ?? false
    let rejected = (metadata["rejected_edits"] as? [[String: Any]])?.count ?? 0
    let warnings = metadata["warnings"] as? [String] ?? []
    var message: String
    if !used { message = "快速规则整理（未调用模型）" }
    else if metadata["status"] as? String == "fallback" { message = "整理未完成，已保留保守结果" }
    else if (metadata["applied_edits"] as? Int ?? 0) > 0 { message = "小模型整理" }
    else { message = "小模型已检查，未改动词句" }
    if metadata["partial_plan"] as? Bool == true { message += " · 达到时间预算，保留已核对的局部整理" }
    if rejected > 0 { message += " · 有不确定修改未采用" }
    if warnings.contains("unresolved_self_correction") { message += "\n仍有未解决的改口，请检查原稿或重说。" }
    return message
}
