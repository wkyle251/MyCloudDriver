#!/usr/bin/env python3
"""Exercise the shipped scanner/worker on synthetic content, without login."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import wave
import zipfile
import zlib


def png(path, phase=0):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = b"".join(b"\0" + bytes(v for x in range(128) for v in
        ((x * 2 + phase) % 256, (y * 2 + phase) % 256, ((x // 16 + y // 16) % 2) * 200)) for y in range(128))
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
    parser.add_argument("--acceleration", choices=["cpu", "automatic"], default="cpu")
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
        png(files / "picture-variant-one.png", 24); png(files / "picture-variant-two.png", 48)
        with wave.open(str(files / "sound.wav"), "wb") as sound:
            sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(16000)
            sound.writeframes(b"".join(struct.pack("<h", int(16000 * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(32000)))
        shutil.copy2(files / "sound.wav", files / "sound-copy.wav")
        subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=4", "-t", "2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", str(files / "clip.mp4")], check=True, timeout=30)
        shutil.copy2(files / "clip.mp4", files / "clip-copy.mp4")
        models = resources / "FileTwinModels"
        def model_inventory():
            return sorted((str(p.relative_to(models)), p.stat().st_size, p.stat().st_mtime_ns)
                          for p in models.rglob('*') if p.is_file())
        models_before = model_inventory()
        request = dict(source="local", local_paths=[str(files)], cloud_items=[], families=["text", "image", "audio", "video"],
            threshold=0.9, exact_duplicates=True, include_hidden=False,
            data_dir=str(root / "index"), model_dir=str(models), temp_dir=str(root / "temporary"),
            report_path=str(root / "result/report.json"),
            resources=dict(workers=2, memory_bytes=2 * 1024**3, download_memory_bytes=512 * 1024**2, acceleration=args.acceleration),
            runtime=dict(worker_path=str(resources / "filetwin-worker"),
                ffmpeg_path=ffmpeg, ffprobe_path=ffprobe, onnxruntime_path=str(models / "runtime/libonnxruntime.dylib"),
                pdfium_path=str(models / "runtime/libpdfium.dylib")))
        request_path = root / "request.json"; request_path.write_text(json.dumps(request))
        environment = {k: v for k, v in os.environ.items() if not k.startswith("PIKPAK_")}
        run = subprocess.run([str(resources / "pikpak"), "similarity-scan", "--request-file", str(request_path)],
            cwd=root, env=environment, capture_output=True, text=True, timeout=180)
        assert run.returncode == 0, run.stderr
        updates = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
        progress = [event for event in updates if event.get("event") == "progress"]
        assert progress and updates[-1]["event"] == "finished"
        analysis = [p for p in progress if p["stage"] == "analysing"]
        assert analysis, "No analysis progress was received"
        assert all(p.get("total") is None or p["completed"] <= p["total"] for p in progress)
        for event in analysis:
            assert event["completed"] == event["counts"]["files_processed"]
            assert event["total"] == event["counts"]["files_total"]
            if work := event.get("work"):
                assert work["original_memory_bytes"] <= work["original_memory_limit"] == 512 * 1024**2
                assert work["analysis_memory_limit"] == 1536 * 1024**2
        terminal = next(p for p in reversed(progress) if p["stage"] == "finishing")
        assert terminal["counts"]["files_processed"] == terminal["counts"]["files_total"] == 13
        assert terminal['counts']['bytes_hashed'] > 0
        assert terminal["counts"]["pairs_processed"] == terminal["counts"]["pairs_total"] == 18
        report = json.loads(Path(request["report_path"]).read_text())
        assert report["analysed_files"] == 13, json.dumps(report, indent=2)
        assert report["skipped_files"] == 0, report["issues"]
        families = {file["family"] for file in report["files"] if file["state"] == "ready"}
        assert families == {"text", "image", "audio", "video"}, families
        assert report["scores_retained"] == 18
        with sqlite3.connect((root / 'index/runs' / (report['run_id'] + '.sqlite3')).as_uri() + '?mode=ro', uri=True) as db:
            saved = json.loads(db.execute('SELECT summary FROM run').fetchone()[0])
            assert saved['workers'] == 2
            native_files = [dict(extraction=json.loads(row[0] or '{}')) for row in db.execute('SELECT extraction FROM files')]
        assert terminal['counts']['vectors_encoded'] > 0
        assert terminal['counts']['cache_hits'] > 0
        original_readers = [f['extraction'] for f in native_files if 'worker_seconds' in f['extraction']]
        assert original_readers and all(e.get('input_storage') == 'memory' for e in original_readers), 'A native decoder used a disk original'
        inference = [f.get('extraction', {}).get('inference', {}) for f in native_files]
        selected_backend = next(e['backend'] for e in updates if e.get('event') == 'acceleration' and e.get('backend') in {'cpu', 'coreml'})
        assert all(i.get('backend') == selected_backend for i in inference if i), inference
        assert any(i.get('model_reused') is True for i in inference), 'Expected model reuse across native batch files'
        assert any(f.get('extraction', {}).get('decoder_strategy') == 'continuous_midpoint_selection' for f in native_files), 'Expected batched video decoding'
        assert not list(Path(request["temp_dir"]).iterdir()), "temporary copies remain"
        # A new scan reuses unchanged source revisions and their vectors
        # without reading and hashing the originals again.
        again = subprocess.run([str(resources / 'pikpak'), 'similarity-scan', '--request-file', str(request_path)],
            cwd=root, env=environment, capture_output=True, text=True, timeout=180)
        assert again.returncode == 0, again.stderr
        repeated = [json.loads(line) for line in again.stdout.splitlines() if line.startswith('{')]
        completed = next(p for p in reversed(repeated) if p.get('stage') == 'finishing')
        assert completed['counts']['cache_hits'] == 13 and completed['counts']['vectors_encoded'] == 0
        assert completed['counts']['bytes_hashed'] == 0
        assert not list(Path(request['temp_dir']).iterdir()), 'Temporary processing data survived the repeat scan'
        assert model_inventory() == models_before, 'Scanning modified or grew the model directory'
        # Scores, including per-family decoder output, survive removal of all inputs.
        shutil.rmtree(files)
        for cutoff in [0.9, 0.05, 1.0]:
            group_query = dict(data_dir=request['data_dir'], run_id=report['run_id'], result_revision=report['result_revision'], minimum_score=cutoff, include_identical=True)
            group_path = root / 'group.json'; group_path.write_text(json.dumps(group_query))
            response = subprocess.run([str(resources / 'pikpak'), 'similarity-groups', '--request-file', str(group_path)],
                env=environment, capture_output=True, text=True, check=True, timeout=30)
            groups = json.loads(response.stdout)
            assert groups['minimum_score'] == cutoff and groups['groups']
            assert all(g['identical'] or g['minimum_score'] >= cutoff for g in groups['groups'])
        for family in sorted(families):
            reference = next(file for file in report["files"] if file["family"] == family)
            query = dict(data_dir=request["data_dir"], run_id=report["run_id"], result_revision=report["result_revision"],
                         file_id=reference["id"], row_offset=reference["engine_index"])
            query_path = root / "query.json"; query_path.write_text(json.dumps(query))
            response = subprocess.run([str(resources / "pikpak"), "similarity-scores", "--request-file", str(query_path)],
                                      env=environment, capture_output=True, text=True, check=True, timeout=30)
            row = json.loads(response.stdout)
            assert row["file_id"] == reference["id"] and row["entries"]
            assert all(-1 <= entry["score"] <= 1 for entry in row["entries"])
            assert row["unavailable"].get("incompatible_profile", 0) > 0
        print("PASS shipped FileTwin decoders: UTF-8, DOCX, PDF, PNG, WAV and MP4; individual scores in all four families")
        print("PASS local CLI without login, exact copies, source-independent saved rows and temporary cleanup")
        print("PASS FileTwin 0.2 progress, compatible-pair totals, full inventory and incompatible-score reasons")
        print("PASS two-worker batches, model reuse, batched video decoding, vector cache and source-free regrouping")



if __name__ == "__main__":
    main()
