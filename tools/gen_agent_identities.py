#!/usr/bin/env python3
"""Regenerate terraform/schema/agent_identities.json from scout-proto's AgentIdentity enum.

The lakehouse never hardcodes which agents to ingest (any agent= folder is read); this map only
labels agent_events.agent_type with the proto integer code for the identity name. An identity
newer than the pinned proto tag lands with agent_type NULL until this is regenerated:

    tools/gen_agent_identities.py [proto-git-ref]     # default: the PINNED tag below

Reads proto/scout.proto from the local traceforce-scout-proto checkout
(../traceforce-scout-proto, or $SCOUT_PROTO_DIR).
"""
import json, os, pathlib, re, subprocess, sys

PINNED = "v1.1.31"
ref = sys.argv[1] if len(sys.argv) > 1 else PINNED
root = pathlib.Path(__file__).resolve().parents[1]
proto_dir = pathlib.Path(os.environ.get("SCOUT_PROTO_DIR", root.parent / "traceforce-scout-proto"))
src = subprocess.check_output(["git", "-C", str(proto_dir), "show", f"{ref}:proto/scout.proto"], text=True)
body = re.search(r"enum AgentIdentity\s*\{(.*?)\n\}", src, re.S).group(1)
entries = re.findall(r"^\s*(AGENT_IDENTITY_[A-Z0-9_]+)\s*=\s*(\d+)", body, re.M)
out = {
    "_generated": f"tools/gen_agent_identities.py from traceforce-scout-proto {ref} proto/scout.proto (enum AgentIdentity). Do not edit by hand.",
    "identities": {name: int(code) for name, code in entries},
}
(root / "terraform/schema/agent_identities.json").write_text(json.dumps(out, indent=2) + "\n")
print(f"{len(entries)} identities from {ref}")
