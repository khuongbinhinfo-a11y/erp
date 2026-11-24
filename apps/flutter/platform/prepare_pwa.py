"""Generate ERP icons and an exact-version public app-shell cache. No API data."""
import argparse
import hashlib
import json
import pathlib
import struct
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]

def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)

def icon(n):
    # Simple original ERP mark: three white distribution shelves.
    rows = bytearray()
    for y in range(n):
        rows.append(0)
        for x in range(n):
            u, v = x / n, y / n
            white = .22 <= u <= .78 and any(a <= v <= b for a, b in ((.26,.35),(.455,.545),(.65,.74)))
            rows.extend((255,255,255) if white else (23,107,70))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB",n,n,8,2,0,0,0)) + chunk(b"IDAT",zlib.compress(rows)) + chunk(b"IEND",b"")

def prepare():
    target = ROOT / "web" / "icons"
    target.mkdir(exist_ok=True)
    for n in (192,512):
        (target / f"erp-{n}.png").write_bytes(icon(n))

def finalize():
    target = ROOT / "build" / "web"
    # Include static Flutter output only. Never enumerate remote API URLs.
    paths = [p for p in sorted(target.rglob("*")) if p.is_file()
             and p.name not in ("erp-sw.js","flutter_service_worker.js",".last_build_id")
             and not p.name.endswith(".map")]
    digest = hashlib.sha256()
    for p in paths:
        digest.update(p.relative_to(target).as_posix().encode())
        digest.update(hashlib.sha256(p.read_bytes()).digest())
    urls = ["/" + p.relative_to(target).as_posix() for p in paths]
    if "/index.html" not in urls or "/main.dart.js" not in urls:
        raise RuntimeError("Incomplete Flutter web build")
    template = (ROOT / "platform" / "erp-sw.template.js").read_text()
    (target / "erp-sw.js").write_text(template.replace("__VERSION__",digest.hexdigest()[:24])
        .replace("__ASSETS__",json.dumps(urls, ensure_ascii=True)))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("step", choices=("prepare","finalize"))
    args = parser.parse_args()
    (prepare if args.step == "prepare" else finalize)()
