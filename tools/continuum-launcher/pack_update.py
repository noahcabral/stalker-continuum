from argparse import ArgumentParser
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
from zipfile import ZIP_DEFLATED, ZipFile


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+', value):
        raise ValueError(f'Expected a three-part version, got {value!r}')
    return tuple(map(int, value.split('.')))


def main():
    parser = ArgumentParser(description='Package selected AWP runtime files for the standalone updater.')
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--minimum-version', default='0.0.0')
    parser.add_argument('--file', action='append', required=True)
    args = parser.parse_args()
    if version(args.minimum_version) >= version(args.version):
        parser.error('Minimum version must precede the release version.')
    root = args.root.resolve(strict=True)
    files = {}
    for name in args.file:
        relative = PurePosixPath(name.replace('\\', '/'))
        normalized = relative.as_posix()
        if '..' in relative.parts or not normalized.startswith(('bin/', 'gamedata/', 'database/patch/')):
            parser.error(f'Unsupported runtime file {name!r}')
        if normalized.casefold() in files:
            parser.error(f'Duplicate update entry {name!r}')
        source = root.joinpath(*relative.parts).resolve(strict=True)
        if not source.is_file() or not source.is_relative_to(root):
            parser.error(f'Invalid runtime file {name!r}')
        files[normalized.casefold()] = normalized, source

    manifest = {'format': 'awp-standalone-update-1', 'version': args.version,
                'minimumVersion': args.minimum_version, 'files': []}
    with ZipFile(args.output, 'x', compression=ZIP_DEFLATED) as package:
        for name, path in files.values():
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            package.write(path, arcname=name)
            manifest['files'].append({'path': name, 'sha256': digest})
        package.writestr('manifest.json', json.dumps(manifest, indent=2))
    print(f'{args.output} contains {len(files)} update files.')


if __name__ == '__main__':
    main()
