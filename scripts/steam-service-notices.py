"""Bundle the exact NuGet dependency notices alongside the replaceable DLLs."""
import json
import pathlib
import shutil
import sys
import xml.etree.ElementTree as ET

output = pathlib.Path(sys.argv[1])
assets = json.loads(pathlib.Path('helpers/ScenaSteamService/obj/project.assets.json').read_text())
package_roots = [pathlib.Path(p) for p in assets['packageFolders']]
notices = output / 'Licenses'
notices.mkdir(exist_ok=True)
lines = ['Scena Steam authentication helper - third-party notices',
         'SteamKit2 3.4.0: https://github.com/SteamRE/SteamKit/tree/3.4.0',
         'SteamKit2 is unmodified and dynamically linked; its DLL can be replaced.',
         '.NET runtime: see LICENSE.txt and THIRD-PARTY-NOTICES.txt within each architecture folder.', '']
for name, info in assets['libraries'].items():
    if info['type'] != 'package':
        continue
    folder = next((root / info['path'] for root in package_roots if (root / info['path']).is_dir()), None)
    if folder is None:
        raise RuntimeError('Missing package: ' + name)
    spec = next(folder.glob('*.nuspec'))
    metadata = ET.parse(spec).getroot().find('{*}metadata')
    license_node = metadata.find('{*}license')
    project = metadata.find('{*}projectUrl')
    lines += [name, '  Source/project: ' + (project.text if project is not None else 'NuGet package metadata'),
              '  License: ' + (license_node.text if license_node is not None else 'See package notices')]
    target = notices / name.replace('/', '-')
    target.mkdir(exist_ok=True)
    shutil.copy2(spec, target / spec.name)
    copies = []
    if license_node is not None and license_node.attrib.get('type') == 'file':
        copies.append(folder / license_node.text)
    copies += [p for p in folder.iterdir() if p.is_file() and
               any(key in p.name.lower() for key in ('license', 'notice', '3rd party'))]
    for path in set(copies):
        if not path.is_file():
            raise RuntimeError('Missing license: ' + str(path))
        shutil.copy2(path, target / path.name)
    if license_node is not None and license_node.attrib.get('type') == 'expression' and not any('license' in p.name.lower() for p in copies):
        license_file = pathlib.Path('helpers/ScenaSteamService/ThirdParty') / (license_node.text + '.txt')
        if not license_file.is_file():
            raise RuntimeError('Missing bundled license expression text: ' + license_node.text)
        shutil.copy2(license_file, target / license_file.name)
for arch in ('arm64', 'x86_64'):
    deps = json.loads((output / arch / 'ScenaSteamService.deps.json').read_text())
    runtime = next(name.removeprefix('runtimepack.').lower() for name in deps['libraries'] if name.startswith('runtimepack.Microsoft.NETCore.App.Runtime.'))
    runtime_dir = next(root / runtime for root in package_roots if (root / runtime).is_dir())
    for filename in ('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT'):
        shutil.copy2(runtime_dir / filename, output / arch / filename)
(output / 'THIRD-PARTY-NOTICES.txt').write_text('\n'.join(lines) + '\n')
