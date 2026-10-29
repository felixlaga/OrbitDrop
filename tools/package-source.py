from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).resolve().parent.parent
files = []
for name in ('Sources', 'Resources', 'Tests'):
    files.extend(p for p in (root / name).rglob('*') if p.is_file() and '.DS_Store' not in p.name)
for name in ('.gitignore', 'README.md', 'VALIDATION.md', 'build.sh', 'package.sh', 'test.sh'):
    p = root / name
    if p.exists():
        files.append(p)
for name in ('make-artwork.swift', 'package-source.py', 'verify-package.py'):
    files.append(root / 'tools' / name)
for codec in ('webp', 'avif'):
    folder = root / 'tools' / 'codecs' / codec
    if folder.exists():
        files.extend(p for p in folder.iterdir() if p.is_file() and p.suffix in ('.sh', '.py', '.json', '.md'))
with ZipFile(root / 'dist' / 'OrbitDrop-Source.zip', 'w', ZIP_DEFLATED) as archive:
    for file in sorted(set(files)):
        archive.write(file, Path('OrbitDrop-Source') / file.relative_to(root))
print('Source archive created.')
