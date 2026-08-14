#!/usr/bin/env python3
"""
Read/write which bypass modules are active.

The launcher used to load a hardcoded list of Frida scripts. This makes the set
selectable so a module that upsets a defensive app can be switched off without
editing shell scripts.

State lives in ~/mobile-pentest/bypass.json. Two levels:
  scripts  - which frida-scripts/*.js get loaded at all
  anti     - individual modules inside android-anti-detection.js

  bypass.py --list                 print current state as JSON
  bypass.py --args                 emit the `-l path` flags for the launcher
  bypass.py --apply                write ANTI_DETECT_SKIP into config.js
  bypass.py --set proxy-override=0 --set anti.Build=0
  bypass.py --reset                everything back on
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("MP_ROOT", Path.home() / "mobile-pentest"))
STATE = ROOT / "bypass.json"
FS = ROOT / "frida-scripts"

# Order matters: config.js first (defines CERT_PEM/PROXY_* the rest read).
SCRIPTS = [
    ("proxy-override", "android-proxy-override.js",
     "Force the app through the proxy even if it ignores system settings"),
    ("system-certificate-injection", "android-system-certificate-injection.js",
     "Inject the CA into the app's trust store at runtime"),
    ("certificate-unpinning", "android-certificate-unpinning.js",
     "Defeat SSL pinning (OkHttp, Conscrypt, TrustKit, CT…)"),
    ("certificate-unpinning-fallback", "android-certificate-unpinning-fallback.js",
     "Catch custom TrustManagers the main script misses"),
    ("disable-root-detection", "android-disable-root-detection.js",
     "Hide su binaries, root manager packages, Runtime.exec(\"su\")"),
    ("anti-detection", "android-anti-detection.js",
     "Emulator/VM, debugger, tracer and Frida detection"),
    ("facetec-init-bypass", "android-facetec-init-bypass.js",
     "Force FaceTec SDK init success (defeats its own native device-integrity check)"),
]

ANTI_MODULES = [
    ("Build", "Spoof 15 android.os.Build fields to a physical Samsung"),
    ("Build.VERSION", "Normalise VERSION.CODENAME"),
    ("SystemProperties", "Filter qemu/goldfish/nox/mumu strings out of getprop"),
    ("File.exists", "Hide emulator device nodes, frida and magisk paths"),
    ("Debug", "isDebuggerConnected / waitingForDebugger -> false"),
    ("BufferedReader", "Mask TracerPid, drop frida lines from /proc reads"),
    ("Runtime.exec", "Block su / busybox / getprop probe commands"),
    ("TelephonyManager", "Spoof IMEI, operator and SIM identifiers"),
    ("SensorManager", "Report on empty sensor lists (emulator tell)"),
]


def default() -> dict:
    return {
        "scripts": {k: True for k, _, _ in SCRIPTS},
        "anti": {k: True for k, _ in ANTI_MODULES},
    }


def load() -> dict:
    d = default()
    if STATE.exists():
        try:
            cur = json.loads(STATE.read_text())
            for k in d["scripts"]:
                if k in cur.get("scripts", {}):
                    d["scripts"][k] = bool(cur["scripts"][k])
            for k in d["anti"]:
                if k in cur.get("anti", {}):
                    d["anti"][k] = bool(cur["anti"][k])
        except Exception:
            pass
    return d


def save(d: dict) -> None:
    STATE.write_text(json.dumps(d, indent=2))


def catalog() -> dict:
    """Everything the UI needs to render the toggles."""
    d = load()
    return {
        "scripts": [{"key": k, "file": f, "desc": desc, "on": d["scripts"][k]}
                    for k, f, desc in SCRIPTS],
        "anti": [{"key": k, "desc": desc, "on": d["anti"][k]}
                 for k, desc in ANTI_MODULES],
        "anti_enabled": d["scripts"]["anti-detection"],
    }


def launcher_args() -> str:
    d = load()
    parts = [f"-l '{FS}/config.js'"]
    for k, f, _ in SCRIPTS:
        if d["scripts"].get(k):
            parts.append(f"-l '{FS}/{f}'")
    return " ".join(parts)


def apply_config() -> None:
    """Push the per-module anti-detection choices into config.js."""
    d = load()
    skip = [k for k, _ in ANTI_MODULES if not d["anti"].get(k, True)]
    cfg = FS / "config.js"
    s = cfg.read_text()
    line = "var ANTI_DETECT_SKIP = " + json.dumps(skip) + ";"
    if re.search(r"^var ANTI_DETECT_SKIP = .*$", s, re.M):
        s = re.sub(r"^var ANTI_DETECT_SKIP = .*$", line, s, flags=re.M)
    else:
        s = s.replace("const DEBUG_MODE = true;", "const DEBUG_MODE = true;\n" + line)
    # ONLY is a bisecting aid; the UI drives SKIP, so keep ONLY disabled.
    if re.search(r"^var ANTI_DETECT_ONLY = .*$", s, re.M):
        s = re.sub(r"^var ANTI_DETECT_ONLY = .*$", "var ANTI_DETECT_ONLY = null;", s, flags=re.M)
    cfg.write_text(s)


def main() -> int:
    args = sys.argv[1:]
    if "--reset" in args:
        save(default()); apply_config(); print("reset"); return 0
    if "--args" in args:
        apply_config(); print(launcher_args()); return 0
    if "--apply" in args:
        apply_config(); print("applied"); return 0

    changed = False
    d = load()
    i = 0
    while i < len(args):
        if args[i] == "--set" and i + 1 < len(args):
            k, _, v = args[i + 1].partition("=")
            on = v not in ("0", "false", "off", "")
            if k.startswith("anti."):
                name = k[5:]
                if name in d["anti"]:
                    d["anti"][name] = on; changed = True
            elif k in d["scripts"]:
                d["scripts"][k] = on; changed = True
            else:
                print(f"unknown module: {k}", file=sys.stderr); return 1
            i += 2
            continue
        i += 1

    if changed:
        save(d); apply_config()
    print(json.dumps(catalog(), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
