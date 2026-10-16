#!/bin/bash
set -euo pipefail
SCENA_SOURCE="$SRCROOT/build/steam-service"
SCENA_DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/SteamService"
if [[ ! -f "$SCENA_SOURCE/ServiceBuild.json" ]]; then
    if [[ "$CONFIGURATION" == Release ]]; then
        echo 'error: Build the Steam helper first: scripts/build-steam-service.sh' >&2
        exit 1
    fi
    echo 'warning: Steam QR helper is absent; this Debug build uses web login. Run scripts/build-steam-service.sh to enable QR login.'
    exit 0
fi
SCENA_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -n "$SCENA_IDENTITY" ]] || SCENA_IDENTITY='-'
python3 - "$SCENA_SOURCE" "$SCENA_DEST" "$SCENA_IDENTITY" "$SRCROOT/helpers/ScenaSteamService/helper-entitlements.plist" "$SRCROOT" <<'PY'
import hashlib,json,pathlib,shutil,subprocess,sys
source,dest=map(pathlib.Path,sys.argv[1:3])
identity=sys.argv[3]
entitlements=pathlib.Path(sys.argv[4])
project=pathlib.Path(sys.argv[5])
source_inputs=sorted((project/'helpers/ScenaSteamService').glob('*.cs'))
source_inputs += [project/'helpers/ScenaSteamService'/name for name in ('ScenaSteamService.csproj','packages.lock.json','global.json')]
revision=hashlib.sha256(b''.join(p.read_bytes() for p in source_inputs)).hexdigest()
if json.loads((source/'ServiceBuild.json').read_text())['revision']!=revision:
    raise RuntimeError('Steam helper sources changed. Run scripts/build-steam-service.sh before building Scena.')
marker=source.joinpath('ServiceBuild.json').read_bytes()+identity.encode()+entitlements.read_bytes()
key=hashlib.sha256(marker).hexdigest()
if (dest/'.embedded-revision').is_file() and (dest/'.embedded-revision').read_text()==key:
    sys.exit(0)
for arch in ('arm64','x86_64'):
    if not (source/arch/'ScenaSteamService').is_file():
        raise RuntimeError('Missing Steam helper architecture: '+arch)
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(source,dest)
magic={bytes.fromhex(v) for v in ('cffaedfe','cefaedfe','feedface','feedfacf','cafebabe','bebafeca')}
for path in sorted(dest.rglob('*')):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        native=stream.read(4) in magic
    if native:
        command=['/usr/bin/codesign','--force','--sign',identity,'--options','runtime','--timestamp=none']
        if path.name=='ScenaSteamService':
            command+=['--entitlements',str(entitlements),'--identifier','com.roayc.wallhaven.SteamService.'+path.parent.name]
        subprocess.run(command+[str(path)],check=True)
(dest/'.embedded-revision').write_text(key)
PY
