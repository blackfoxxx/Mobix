#!/usr/bin/env python3
"""
Register a custom AI API for `mp engage --tool opencode` to use, instead of
whatever OpenCode would otherwise default to.

Three schemas, matching how OpenCode itself categorises provider APIs (see
https://opencode.ai/docs/providers): "openai-compatible" covers anything
that speaks OpenAI's chat-completions request/response shape - a self-
hosted vLLM/Ollama/llama.cpp server, a corporate LLM gateway, most third-
party model APIs; "openrouter" is OpenRouter specifically (or a compatible
gateway in front of it); "anthropic-compatible" is for an endpoint that
speaks Anthropic's Messages API shape instead.

  models.py add <name> --schema openai-compatible|openrouter|anthropic-compatible \
            --url <base-url> --key <api-key> [--env <ENV_VAR>] --model <id> [--model <id> ...]
  models.py list
  models.py remove <name>
  models.py use <name>             # make this the default for `mp engage --tool opencode`
  models.py sync [--as <name>]     # (re)write opencode.jsonc's "providers" block from this
                                     # registry; --as temporarily acts as if <name> were
                                     # active without changing the persisted default
  models.py env [<name>]           # print `export VAR='value'` for the named (or active)
                                     # provider's API key - eval this before running opencode
  models.py resolve [<name>]       # print `<provider>/<model>` for `opencode run --model`

Storage: ~/mobile-pentest/models.json, mode 600 - same as creds.py's device
credentials, this is NOT encrypted. It holds real API keys, not test
throwaway ones; back it up/rotate it the way you would any other API key
store. sync() only ever adds/overwrites the exact provider name you gave it
in opencode.jsonc's "providers" block - it never deletes an entry you added
by hand there, and refuses outright (rather than guessing) if that file
doesn't parse as JSON. The top-level "model" key is the one exception: this
tool owns it outright once you've registered anything here, recomputing it
from scratch on every sync (set to the active provider's first model, or
removed entirely if nothing is active) rather than leaving a stale or
hand-set value behind - so don't rely on a manually-set "model" default in
opencode.jsonc surviving once you start using `mp model`.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("MP_ROOT", Path.home() / "mobile-pentest"))
STORE = ROOT / "models.json"
OPENCODE_CONFIG = ROOT / "opencode.jsonc"

SCHEMAS = ("openai-compatible", "openrouter", "anthropic-compatible")
PACKAGE_BY_SCHEMA = {
    "openai-compatible": "@opencode/ai/providers/openai-compatible",
    "anthropic-compatible": "@opencode/ai/providers/anthropic-compatible",
    # openrouter is a provider OpenCode already knows about; no package
    # override needed, only settings/env for a custom key or gateway URL.
    "openrouter": None,
}


def load() -> dict:
    if not STORE.exists():
        return {"providers": {}, "active": None}
    try:
        d = json.loads(STORE.read_text())
    except Exception:
        d = {}
    d.setdefault("providers", {})
    d.setdefault("active", None)
    return d


def save(d: dict) -> None:
    STORE.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
    os.chmod(STORE, 0o600)


def _env_var_for(name: str) -> str:
    safe = "".join(c if c.isalnum() else "_" for c in name.upper()) or "MODEL"
    return f"{safe}_API_KEY"


def _provider_block(name: str, p: dict) -> dict:
    """The OpenCode `providers.<name>` object for one registered provider."""
    block: dict = {"env": [p["env_var"]], "models": {m: {} for m in p["models"]}}
    pkg = PACKAGE_BY_SCHEMA[p["schema"]]
    if pkg:
        block["package"] = pkg
    if p.get("base_url"):
        block["settings"] = {"baseURL": p["base_url"]}
    return block


def sync(as_name: str | None = None) -> None:
    d = load()
    try:
        cfg = json.loads(OPENCODE_CONFIG.read_text()) if OPENCODE_CONFIG.exists() else {}
    except Exception as e:
        print(f"refusing to touch {OPENCODE_CONFIG} - it doesn't parse as JSON ({e}). "
              "If you've hand-added comments or broken syntax, fix that first; models.py "
              "will never guess at merging into unparseable JSON.", file=sys.stderr)
        raise SystemExit(1)
    cfg.setdefault("$schema", "https://opencode.ai/config.json")
    providers_cfg = cfg.setdefault("providers", {})
    for name, p in d["providers"].items():
        providers_cfg[name] = _provider_block(name, p)
    # This tool owns the top-level "model" key outright (unlike the
    # providers.<name> entries, which only touch their own name): always
    # recompute it from scratch rather than leaving a stale value behind.
    # Without this, removing the active (or only) provider left a "model"
    # pointing at a provider no longer in the config at all - confirmed
    # live, not hypothetical.
    cfg.pop("model", None)
    active = as_name or d.get("active")
    if active and active in d["providers"]:
        first_model = next(iter(d["providers"][active]["models"]), None)
        if first_model:
            cfg["model"] = f"{active}/{first_model}"
    OPENCODE_CONFIG.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")


def cmd_add(args: list[str]) -> int:
    if not args:
        print("usage: models.py add <name> --schema ... --url ... --key ... --model ... [--model ...] [--env VAR]")
        return 1
    name = args[0]
    if not name.replace("-", "").replace("_", "").isalnum():
        print(f"invalid name: {name!r} (letters/digits/-/_ only)")
        return 1
    schema = url = key = env_var = None
    models: list[str] = []
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--schema" and i + 1 < len(args):
            schema = args[i + 1]; i += 2
        elif a == "--url" and i + 1 < len(args):
            url = args[i + 1]; i += 2
        elif a == "--key" and i + 1 < len(args):
            key = args[i + 1]; i += 2
        elif a == "--env" and i + 1 < len(args):
            env_var = args[i + 1]; i += 2
        elif a == "--model" and i + 1 < len(args):
            models.append(args[i + 1]); i += 2
        else:
            print(f"unrecognised argument: {a}")
            return 1
    if schema not in SCHEMAS:
        print(f"--schema must be one of: {', '.join(SCHEMAS)}")
        return 1
    if schema != "openrouter" and not url:
        print(f"--url is required for --schema {schema}")
        return 1
    if not key:
        print("--key is required (the API key value - stored locally, see models.py --help)")
        return 1
    if not models:
        print("at least one --model <id> is required")
        return 1
    d = load()
    d["providers"][name] = {
        "schema": schema,
        "base_url": url,
        "env_var": env_var or _env_var_for(name),
        "api_key": key,
        "models": models,
        "updated": int(time.time()),
    }
    if not d.get("active"):
        d["active"] = name
    save(d)
    sync()
    print(f"added '{name}' ({schema}), {len(models)} model(s)."
          + ("" if d["active"] != name else " Set as the active provider for `mp engage --tool opencode`."))
    return 0


def cmd_list(_: list[str]) -> int:
    d = load()
    if not d["providers"]:
        print("no custom model providers registered - see: models.py add")
        return 0
    for name, p in d["providers"].items():
        mark = " (active)" if d.get("active") == name else ""
        key = p.get("api_key", "")
        masked = "*" * min(len(key), 12) if key else "(none)"
        print(f"{name}{mark}")
        print(f"  schema   {p['schema']}")
        if p.get("base_url"):
            print(f"  url      {p['base_url']}")
        print(f"  key      {masked}  (env {p['env_var']})")
        print(f"  models   {', '.join(p['models'])}")
    return 0


def cmd_remove(args: list[str]) -> int:
    if not args:
        print("usage: models.py remove <name>")
        return 1
    name = args[0]
    d = load()
    if name not in d["providers"]:
        print(f"no such provider: {name}")
        return 1
    del d["providers"][name]
    if d.get("active") == name:
        d["active"] = next(iter(d["providers"]), None)
    save(d)
    try:
        cfg = json.loads(OPENCODE_CONFIG.read_text()) if OPENCODE_CONFIG.exists() else {}
        if name in cfg.get("providers", {}):
            del cfg["providers"][name]
            OPENCODE_CONFIG.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
    except Exception as e:
        print(f"removed from registry, but couldn't clean up {OPENCODE_CONFIG}: {e}", file=sys.stderr)
    sync()
    print(f"removed '{name}'")
    return 0


def cmd_use(args: list[str]) -> int:
    if not args:
        print("usage: models.py use <name>")
        return 1
    name = args[0]
    d = load()
    if name not in d["providers"]:
        print(f"no such provider: {name} (see: models.py list)")
        return 1
    d["active"] = name
    save(d)
    sync()
    print(f"'{name}' is now the default for `mp engage --tool opencode`")
    return 0


def cmd_sync(args: list[str]) -> int:
    as_name = None
    if args and args[0] == "--as" and len(args) > 1:
        as_name = args[1]
    sync(as_name)
    print(f"synced {len(load()['providers'])} provider(s) into {OPENCODE_CONFIG}")
    return 0


def _shquote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def cmd_env(args: list[str]) -> int:
    d = load()
    name = args[0] if args else d.get("active")
    if not name:
        return 0  # nothing active, nothing to export - not an error
    p = d["providers"].get(name)
    if not p:
        print(f"# no such provider: {name}", file=sys.stderr)
        return 1
    print(f"export {p['env_var']}={_shquote(p['api_key'])}")
    return 0


def cmd_resolve(args: list[str]) -> int:
    """Print `<provider>/<model>` for the named (or active) provider's first
    model - the exact string `opencode run --model` expects. Exit 1, no
    output, if there's no such provider or nothing is active."""
    d = load()
    name = args[0] if args else d.get("active")
    p = d["providers"].get(name) if name else None
    if not p:
        return 1
    first_model = next(iter(p["models"]), None)
    if not first_model:
        return 1
    print(f"{name}/{first_model}")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    cmd, rest = args[0], args[1:]
    handlers = {
        "add": cmd_add, "list": cmd_list, "remove": cmd_remove, "rm": cmd_remove,
        "use": cmd_use, "sync": cmd_sync, "env": cmd_env, "resolve": cmd_resolve,
    }
    fn = handlers.get(cmd)
    if not fn:
        print(__doc__)
        return 1
    return fn(rest)


if __name__ == "__main__":
    raise SystemExit(main())
