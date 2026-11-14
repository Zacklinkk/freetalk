"""Single GPU owner. Newline JSON over private inherited stdio; no listening port."""
import base64
import json
import sys
import traceback
from engine import Engine
from context import normalize_context


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def tune_prompt(engine, command, emit):
    """Ask the cloud model for preferences, then replay old vs new rules locally.

    Nothing is saved here: the app shows the proposal and the replay result and
    the user decides. The editor's own rules are restored before returning.
    """
    from cloud_client import chat_client
    from engine import prompt
    from prompt_tuning import propose, evaluate
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
    finally:
        engine.editor.remote = remote
        if engine.editor.preferences != current:
            engine.editor.set_preferences(current)
    return {"rules": rules, "previous": current, "scores": scores, "examples": examples, **detail}


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
                result = {"ready": True}
            elif action == "cloud_test":
                from cloud_client import chat_client, probe
                settings = command.get("cloud") or {}
                client = chat_client(settings.get("protocol", "openai"), settings.get("base_url", ""),
                                     settings.get("model", ""), settings.get("api_key", ""), settings.get("headers"))
                result = {"seconds": round(probe(client, min(20, max(2, float(settings.get("timeout_seconds", 10))))), 2)}
            elif action == "chunk":
                result = engine.push(base64.b64decode(command["pcm"], validate=True))
            elif action == "finish":
                result = engine.finish()
            elif action == "prompt_tune":
                result = tune_prompt(engine, command, emit)
            elif action == "set_preferences":
                from prompt_tuning import clean_rules
                engine.editor.set_preferences(clean_rules(command.get("rules")))
                result = {"rules": engine.editor.preferences}
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
