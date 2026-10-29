"""Exercise the packaged executable without starting the GUI."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parent.parent
output_root = root / 'build' / 'package-checks'
output_root.mkdir(parents=True, exist_ok=True)
workspace = Path(tempfile.mkdtemp(prefix='portable-', dir=output_root))
app = workspace / 'Relocated OrbitDrop 日本.app'
shutil.copytree(root / 'build' / 'OrbitDrop.app', app)
binary = app / 'Contents' / 'MacOS' / 'OrbitDrop'
env = {k: v for k, v in os.environ.items() if not k.startswith('DYLD_')}
env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
source = workspace / 'Source Image 日本.png'
pdf = workspace / 'Single Page.pdf'
shutil.copy(root / 'Tests' / 'Fixtures' / 'Sample.png', source)
shutil.copy(root / 'Tests' / 'Fixtures' / 'Sample.pdf', pdf)
original = source.read_bytes()
reports = []

def convert(path, fmt):
    run = subprocess.run([str(binary), '--convert', str(path), '--to', fmt], cwd=workspace, env=env, text=True, capture_output=True, timeout=180)
    if run.returncode:
        raise RuntimeError(f'{fmt}: {run.stderr}')
    outputs = [Path(line) for line in run.stdout.splitlines() if line.strip()]
    assert outputs and all(p.is_file() for p in outputs), run.stdout
    return outputs

for fmt in ('jpg', 'png', 'webp', 'heic', 'tiff', 'avif', 'bmp', 'pdf', 'docx', 'txt'):
    out = convert(source, fmt)[0]
    data = out.read_bytes()
    assert data
    if fmt == 'webp': assert data[:4] == b'RIFF' and data[8:12] == b'WEBP'
    if fmt == 'avif': assert data[4:8] == b'ftyp' and b'avif' in data[:48]
    if fmt == 'jpg': assert data[:2] == b'\xff\xd8'
    if fmt == 'png': assert data.startswith(b'\x89PNG') and out != source
    if fmt == 'pdf': assert data.startswith(b'%PDF')
    if fmt == 'docx':
        with zipfile.ZipFile(out) as package:
            assert 'word/document.xml' in package.namelist()
            assert any(n.startswith('word/media/') for n in package.namelist())
    if fmt == 'txt': assert 'a big idea' in data.decode('utf-8').lower()
    reports.append({'format':fmt,'bytes':len(data),'file':out.name,'passed':True})
jpg = convert(pdf, 'jpg')[0]
assert jpg.name == 'Single Page.jpg', jpg.name
again = convert(pdf, 'jpg')[0]
assert again != jpg and jpg.exists()
assert source.read_bytes() == original
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
report = {'passed':True,'windowOpened':False,'environmentPATH':env['PATH'],'relocatedBundle':str(app),'formats':reports,'singlePageName':jpg.name,'nonOverwriteName':again.name,'originalUnchanged':True}
(output_root / 'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
