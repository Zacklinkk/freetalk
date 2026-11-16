"""Single GPU owner. Newline JSON over private inherited stdio; no listening port."""
import base64
import json
import sys
import traceback
from engine import Engine
from context import normalize_context


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def run_eval_set(engine, emit, stage='eval'):
    """The eval set through the local editor with its current rules and prompts."""
    from cleanup_eval import load, run
    cases = load()
    timeout = engine.config.get('cleanupTimeoutSeconds', 6)
    return run(lambda raw, context: engine.editor.edit(raw, context, timeout, 'auto'), cases,
               lambda done, total, row: emit({"event": "tune-progress", "stage": stage, "completed": done, "total": total}))


def tune_prompt(engine, command, emit):
    """Ask the cloud model for preferences, then replay old vs new rules locally.

    Nothing is saved here. The reply says whether the new rules may be adopted
    without asking (prompt_tuning.decide); the app saves them, or shows them.
    The editor's own rules are restored before returning.
    """
    from cloud_client import chat_client
    from engine import prompt
    from prompt_tuning import propose, evaluate, decide
    from cleanup_eval import summary, regressions
    settings = command.get("cloud") or {}
    client = chat_client(settings.get("protocol", "openai"), settings.get("base_url", ""), settings.get("model", ""),
                         settings.get("api_key", ""), settings.get("headers"))
    cases = [c for c in command.get("cases", []) if isinstance(c, dict) and all(isinstance(c.get(k), str) for k in ("raw", "inserted", "final"))]
    accepted = [t for t in command.get("accepted", []) if isinstance(t, str) and t.strip()]
    if not cases:
        raise ValueError("No correction cases to learn from")
    current = engine.editor.preferences
    emit({"event": "tune-progress", "stage": "propose", "completed": 0, "total": 1})
    rules, detail = propose(client, cases, prompt("edit-plan.txt"), current)
    if not rules or rules == current:
        return {"rules": [], "previous": current, "adopt": False, "reason": "没有找到可靠的共性问题", **detail}
    # Replay the way dictation runs: the user's cleanup mode and personal terms.
    # The original input-field context is not stored, so it is not replayed.
    policy = command.get("policy") if command.get("policy") in {"auto", "always", "fast"} else "auto"
    context = normalize_context({"personal_terms": command.get("terms", [])})
    def edit(raw, rule_set):
        if engine.editor.preferences != rule_set:
            engine.editor.set_preferences(rule_set)
        text, _ = engine.editor.edit(raw, context, 8, policy)
        return text
    remote, engine.editor.remote = engine.editor.remote, None
    try:
        scores, examples = evaluate(edit, cases, accepted, current, rules,
                                    lambda done, total: emit({"event": "tune-progress", "stage": "replay", "completed": done, "total": total}))
        # The eval set: fixed cases the user approved. Old rules first, then new.
        engine.editor.set_preferences(current)
        before = run_eval_set(engine, emit, "eval-before")
        engine.editor.set_preferences(rules)
        after = run_eval_set(engine, emit, "eval-after")
    finally:
        engine.editor.remote = remote
        if engine.editor.preferences != current:
            engine.editor.set_preferences(current)
    adopt, reason = decide(scores, before, after)
    return {"rules": rules, "previous": current, "scores": scores, "examples": examples, "adopt": adopt, "reason": reason,
            "eval": {"before": summary(before)["exact"], "after": summary(after)["exact"], "total": len(after),
                     "regressions": regressions(before, after)}, **detail}


def check_prompt(engine, command, emit):
    """Run the eval set with the saved prompts, then with one edited prompt.

    Nothing is saved here: the app saves the edit when it is not worse, or
    when the user still wants it after seeing which cases stopped matching.
    """
    import prompt_files
    from cleanup_eval import summary, regressions, worse
    name, text = command.get("name"), command.get("text")
    if name not in prompt_files.EDITABLE or not isinstance(text, str) or not text.strip():
        raise ValueError("Unknown or empty prompt")
    if name.endswith(".json") and not prompt_files.valid_turns(text):
        raise ValueError("示例须为 user/assistant 交替的 JSON 列表")
    preferences = engine.editor.preferences
    remote, engine.editor.remote = engine.editor.remote, None
    try:
        before = run_eval_set(engine, emit, "eval-before")
        prompt_files.pending = {name: text}
        engine.editor.set_preferences(preferences)
        after = run_eval_set(engine, emit, "eval-after")
    finally:
        prompt_files.pending = {}
        engine.editor.set_preferences(preferences)
        engine.editor.remote = remote
    fixed = sorted({r["id"] for r in after if r["exact"]} - {r["id"] for r in before if r["exact"]})
    return {"before": summary(before)["exact"], "after": summary(after)["exact"], "total": len(after),
            "regressions": regressions(before, after), "fixed": fixed, "worse": worse(before, after)}


def main():
    config = json.loads(sys.stdin.readline())
    engine = Engine(config, emit)
    emit({"event": "ready"})
    for line in sys.stdin:
        command = json.loads(line)
        try:
            action = command["action"]
            if action == "begin":
                engine.reset(normalize_context(command.get("context", {})))
                policy = command.get("cleanup_policy", "auto")
                engine.cleanup_policy = policy if policy in {"auto", "always", "fast"} else "auto"
                engine.configure_cloud(command.get("cloud"))
                if not command.get("cloud") and isinstance(command.get("cloud_unavailable"), str):
                    engine.cloud_error = command["cloud_unavailable"][:40]
                if command.get("mode") == "translate":
                    cloud = command.get("translation_cloud")
                    engine.mode = "translate"
                    engine.translation = {"target": str(command.get("target_language", "auto"))[:8],
                                          "cloud": cloud if isinstance(cloud, dict) else None}
                result = {"ready": True}
            elif action == "cloud_test":
                from cloud_client import chat_client, probe
                settings = command.get("cloud") or {}
                client = chat_client(settings.get("protocol", "openai"), settings.get("base_url", ""),
                                     settings.get("model", ""), settings.get("api_key", ""), settings.get("headers"))
                result = {"seconds": round(probe(client, min(20, max(2, float(settings.get("timeout_seconds", 10))))), 2)}
            elif action == "context":
                # Visible text recognized after recording started (window OCR).
                # Local only: the cloud request leaves "nearby" out.
                from context import add_visible_text
                engine.context = add_visible_text(engine.context, command.get("nearby", ""))
                result = {"ready": True}
            elif action == "chunk":
                result = engine.push(base64.b64decode(command["pcm"], validate=True))
            elif action == "finish":
                result = engine.finish()
            elif action == "prompt_tune":
                result = tune_prompt(engine, command, emit)
            elif action == "prompt_check":
                result = check_prompt(engine, command, emit)
            elif action == "set_preferences":
                from prompt_tuning import clean_rules
                engine.editor.set_preferences(clean_rules(command.get("rules")))
                result = {"rules": engine.editor.preferences}
            elif action == "reload_prompts":
                # Rereads the prompt files after the user edited one in Settings.
                from prompt_files import EDITABLE, edited
                engine.editor.set_preferences(engine.editor.preferences)
                result = {"edited": [name for name in EDITABLE if edited(name) is not None]}
            elif action == 'meeting':
                from meeting_pipeline import run_meeting
                result = run_meeting(config, command, engine=engine, emit=emit)
            else:
                raise ValueError("Unknown action")
            emit({"id": command["id"], "result": result})
        except Exception as exc:
            if command.get('action') != 'meeting':
                traceback.print_exc(file=sys.stderr)
            emit({"id": command["id"], "error": str(exc)})


if __name__ == "__main__":
    main()
