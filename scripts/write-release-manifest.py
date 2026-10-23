#!/usr/bin/env python3
"""Write public provenance only; never copy local paths or credentials into a release."""
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

app, archive, notary, source_sha, resolution = sys.argv[1:]
assert re.fullmatch(r"[0-9a-f]{40}", source_sha)
with open(os.path.join(app, "Contents/Info.plist"), "rb") as stream:
    info = plistlib.load(stream)
with open(notary) as stream:
    record = json.load(stream)
record = record.get("data", record)
attributes = record.get("attributes", record)
assert attributes["status"] == "Accepted"
assert info["CFBundleIdentifier"] == "com.erole.PowerBar"
assert info["LSMinimumSystemVersion"] == "27.0"
executable = os.path.join(app, "Contents/MacOS", info["CFBundleExecutable"])
build_info = subprocess.check_output(["xcrun", "vtool", "-show-build", executable], text=True)
assert re.findall(r"minos\s+(\S+)", build_info) == ["27.0"]
assert subprocess.check_output(["lipo", "-archs", executable], text=True).strip() == "arm64"
with open(resolution) as stream:
    pins = json.load(stream)["pins"]
revision = next(p["state"]["revision"] for p in pins if p["identity"] == "appupdater")
digest = hashlib.sha256()
with open(archive, "rb") as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
manifest = {
    "app": "PowerBar", "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"], "sourceCommit": source_sha,
    "appUpdaterRevision": revision, "bundleIdentifier": info["CFBundleIdentifier"],
    "teamIdentifier": "T26T3G8C7Q", "minimumMacOS": "27.0", "architecture": "arm64",
    "asset": os.path.basename(archive), "sha256": digest.hexdigest(),
    "gatekeeper": "accepted: Notarized Developer ID",
    "notarization": {"id": record.get("id"), "status": attributes["status"]},
}
print(json.dumps(manifest, indent=2))
