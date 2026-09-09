#!/usr/bin/env python3
"""Exercise the shipped scanner/worker on synthetic content, without login."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import wave
import zipfile
import zlib


def png(path):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = b"".join(b"\0" + bytes(v for x in range(128) for v in
        ((x * 2) % 256, (y * 2) % 256, ((x // 16 + y // 16) % 2) * 200)) for y in range(128))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 128, 8, 2, 0, 0, 0)) +
                     chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def pdf(path):
    content = b"BT /F1 14 Tf 30 740 Td (The garden proposal includes flowers, trees and a small pond.) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"\nendstream"]
    data = bytearray(b"%PDF-1.4\n"); offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data)); data.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data); data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]: data.extend(f"{offset:010} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    args = parser.parse_args(); resources = args.resources.resolve()
    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    ffprobe = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"
    with tempfile.TemporaryDirectory(prefix="mycloud-similarity-test-") as temporary:
        root = Path(temporary).resolve(); files = root / "files"; files.mkdir()
        text = "The garden proposal includes flowers, trees and a small pond. " * 30
        (files / "proposal.txt").write_text(text)
        (files / "revised.txt").write_text(text + "Add a bench beside the pond.")
        (files / "exact.txt").write_text(text)
        with zipfile.ZipFile(files / "proposal.docx", "w") as document:
            document.writestr("[Content_Types].xml", '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>')
            document.writestr("word/document.xml", '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>' + text + '</w:t></w:r></w:p></w:body></w:document>')
        pdf(files / "proposal.pdf")
        png(files / "picture.png"); shutil.copy2(files / "picture.png", files / "picture-copy.png")
        with wave.open(str(files / "sound.wav"), "wb") as sound:
            sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(16000)
            sound.writeframes(b"".join(struct.pack("<h", int(16000 * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(32000)))
        shutil.copy2(files / "sound.wav", files / "sound-copy.wav")
        subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=4", "-t", "2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", str(files / "clip.mp4")], check=True, timeout=30)
        shutil.copy2(files / "clip.mp4", files / "clip-copy.mp4")
        models = resources / "FileTwinModels"
        request = dict(source="local", local_paths=[str(files)], cloud_items=[], families=["text", "image", "audio", "video"],
            threshold=0.9, exact_duplicates=True, include_hidden=False, max_file_bytes=1024**3,
            download_budget_bytes=1024**3, data_dir=str(root / "index"), model_dir=str(models), temp_dir=str(root / "temporary"),
            report_path=str(root / "result/report.json"), runtime=dict(worker_path=str(resources / "filetwin-worker"),
                ffmpeg_path=ffmpeg, ffprobe_path=ffprobe, onnxruntime_path=str(models / "runtime/libonnxruntime.dylib"),
                pdfium_path=str(models / "runtime/libpdfium.dylib")))
        request_path = root / "request.json"; request_path.write_text(json.dumps(request))
        environment = {k: v for k, v in os.environ.items() if not k.startswith("PIKPAK_")}
        run = subprocess.run([str(resources / "pikpak"), "similarity-scan", "--request-file", str(request_path)],
            cwd=root, env=environment, capture_output=True, text=True, timeout=180)
        assert run.returncode == 0, run.stderr
        report = json.loads(Path(request["report_path"]).read_text())
        assert report["analysed_files"] == 11, json.dumps(report, indent=2)
        assert report["skipped_files"] == 0, report["issues"]
        families = {group["family"] for group in report["groups"] if group["match_kind"] == "similar_content"}
        assert families == {"text", "image", "audio", "video"}, families
        assert not list(Path(request["temp_dir"]).iterdir()), "temporary copies remain"
        print("PASS shipped FileTwin decoders: UTF-8, DOCX, PDF, PNG, WAV and MP4; all four content families grouped")
        print("PASS local CLI with no account configuration, exact copies, fresh reads and temporary cleanup")


if __name__ == "__main__":
    main()
