import Foundation

/// Describe the actual outcome, rather than equating a model call with success.
func cleanupSummary(_ metadata: [String: Any]) -> String {
    let used = metadata["model_used"] as? Bool ?? false
    let rejected = (metadata["rejected_edits"] as? [[String: Any]])?.count ?? 0
    let warnings = metadata["warnings"] as? [String] ?? []
    var message: String
    let model = metadata["engine"] as? String == "cloud" ? "云端模型" : "小模型"
    if !used { message = "快速规则整理（未调用模型）" }
    else if metadata["status"] as? String == "fallback" { message = "整理未完成，已保留保守结果" }
    else if (metadata["applied_edits"] as? Int ?? 0) > 0 { message = "\(model)整理" }
    else { message = "\(model)已检查，未改动词句" }
    if let reason = metadata["cloud_fallback"] as? String { message += " · \(CloudEditorSettings.describe(fallback: reason))，已改用本地模型" }
    if metadata["partial_plan"] as? Bool == true { message += " · 达到时间预算，保留已核对的局部整理" }
    if rejected > 0 { message += " · 有不确定修改未采用" }
    if warnings.contains("unresolved_self_correction") { message += "\n仍有未解决的改口，请检查原稿或重说。" }
    return message
}
