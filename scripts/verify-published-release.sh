#!/usr/bin/env bash
# Read-only validation of an existing release; never replace its assets.
set -euo pipefail
tag="${1:?Pass a release tag}"
[[ "$tag" =~ ^v[0-9]+(\.[0-9]+)*$ ]] || { echo "Expected a numeric release tag" >&2; exit 2; }
version="${tag#v}"
repo="${GITHUB_REPOSITORY:-erikrole/PowerBar}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
zip="PowerBar-${version}-arm64.zip"
gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease,tagName > "$scratch/release.json"
python3 - "$scratch/release.json" "$tag" <<'PY_CHECK'
import json,sys
with open(sys.argv[1]) as stream:release=json.load(stream)
assert release['tagName']==sys.argv[2]
assert release['isDraft'] is False and release['isPrerelease'] is False
PY_CHECK
gh release download "$tag" --repo "$repo" --dir "$scratch" \
    --pattern "$zip" --pattern "$zip.sha256" --pattern release-manifest.json
(
    cd "$scratch"
    shasum -a 256 -c "$zip.sha256"
)
ditto -x -k "$scratch/$zip" "$scratch/extracted"
app="$scratch/extracted/PowerBar.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$app/Contents/Info.plist")" == "27.0" ]]
codesign --verify --deep --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "T26T3G8C7Q"' "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
xcrun vtool -show-build "$app/Contents/MacOS/PowerBar" | awk '/minos/ { count++; if ($2 != "27.0") exit 1 } END { if (!count) exit 1 }'
python3 - "$scratch/release-manifest.json" "$repo" "$tag" "$scratch/$zip" "$app" <<'PY'
import sys,json,subprocess,hashlib,plistlib,os
manifest_path,repo,tag,zip_path,app=sys.argv[1:]
with open(manifest_path) as stream:manifest=json.load(stream)
obj=json.loads(subprocess.check_output(['gh','api','repos/'+repo+'/git/ref/tags/'+tag],text=True))['object']
for _ in range(10):
    if obj['type']=='commit':break
    assert obj['type']=='tag'
    obj=json.loads(subprocess.check_output(['gh','api','repos/'+repo+'/git/tags/'+obj['sha']],text=True))['object']
assert obj['type']=='commit'
with open(app+'/Contents/Info.plist','rb') as stream:info=plistlib.load(stream)
hash_value=hashlib.sha256()
with open(zip_path,'rb') as stream:
    for part in iter(lambda:stream.read(1024*1024),b''):hash_value.update(part)
assert manifest['sourceCommit']==obj['sha']
assert manifest['version']==info['CFBundleShortVersionString']==tag[1:]
assert manifest['build']==info['CFBundleVersion']
assert manifest['bundleIdentifier']==info['CFBundleIdentifier']=='com.erole.PowerBar'
assert manifest['minimumMacOS']==info['LSMinimumSystemVersion']=='27.0'
assert manifest['asset']==os.path.basename(zip_path)
assert manifest['sha256']==hash_value.hexdigest()
assert manifest['notarization']['status']=='Accepted'

PY
echo "Verified published PowerBar $version; existing assets preserved."
