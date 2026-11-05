"""Single GPU owner. Newline JSON over private inherited stdio; no listening port."""
import base64
import json
import sys
import traceback
from engine import Engine
from context import normalize_context


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


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
                result = {"ready": True}
            elif action == "chunk":
                result = engine.push(base64.b64decode(command["pcm"], validate=True))
            elif action == "finish":
                result = engine.finish()
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
