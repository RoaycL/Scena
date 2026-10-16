#!/bin/bash
# Build self-contained helpers. Users of the .app do not need a .NET installation.
set -euo pipefail
cd "$(dirname "$0")/.."
SCENA_ROOT="$PWD"
SCENA_DOTNET="${SCENA_DOTNET:-$(command -v dotnet || true)}"
[[ -x "$SCENA_DOTNET" ]] || { echo "Set SCENA_DOTNET to a .NET 10 SDK executable." >&2; exit 1; }
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-$SCENA_ROOT/build/steam-service-sdk-home}"
export NUGET_PACKAGES="${NUGET_PACKAGES:-$SCENA_ROOT/build/steam-service-packages}"
SCENA_OUT="$SCENA_ROOT/build/steam-service"
mkdir -p "$SCENA_OUT"
for SCENA_PAIR in 'osx-arm64:arm64' 'osx-x64:x86_64'; do
    SCENA_RID="${SCENA_PAIR%%:*}"
    SCENA_ARCH="${SCENA_PAIR##*:}"
    # SDK resolution starts at the working directory, so honor the helper's global.json.
    (cd helpers/ScenaSteamService
    "$SCENA_DOTNET" publish ScenaSteamService.csproj \
        -c Release -r "$SCENA_RID" --self-contained true -p:RestoreLockedMode=true \
        -o "$SCENA_OUT/$SCENA_ARCH" -p:PublishSingleFile=false)
done
python3 scripts/steam-service-notices.py "$SCENA_OUT"
python3 - "$SCENA_OUT" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
source_inputs=sorted(pathlib.Path('helpers/ScenaSteamService').glob('*.cs'))
source_inputs += [pathlib.Path('helpers/ScenaSteamService')/name for name in ('ScenaSteamService.csproj','packages.lock.json','global.json')]
revision=hashlib.sha256(b''.join(p.read_bytes() for p in source_inputs)).hexdigest()
license_inputs=[root/'THIRD-PARTY-NOTICES.txt']+sorted(p for p in (root/'Licenses').rglob('*') if p.is_file())
notices=hashlib.sha256(b''.join(p.read_bytes() for p in license_inputs)).hexdigest()
(root/'ServiceBuild.json').write_text(json.dumps({'protocol':1,'steamKit':'3.4.0','revision':revision,'notices':notices},sort_keys=True)+'\n')
paths=[root]+sorted(root.rglob('*'))
inputs=['$(SRCROOT)/'+str(path.relative_to(pathlib.Path.cwd())) for path in paths]
inputs+=['$(SRCROOT)/'+str(path) for path in source_inputs]
outputs=['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/SteamService'+('/'+str(path.relative_to(root)) if path!=root else '') for path in paths]
outputs+=['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/SteamService/.embedded-revision']
magic={bytes.fromhex(v) for v in ('cffaedfe','cefaedfe','feedface','feedfacf','cafebabe','bebafeca')}
for path in paths:
    if path.is_file():
        with path.open('rb') as stream:
            if stream.read(4) in magic:
                outputs.append('$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/SteamService/'+str(path.relative_to(root))+'.cstemp')
pathlib.Path('build/steam-service-inputs.xcfilelist').write_text('\n'.join(inputs)+'\n')
pathlib.Path('build/steam-service-outputs.xcfilelist').write_text('\n'.join(outputs)+'\n')
PY
echo "Steam helpers ready: $SCENA_OUT"
