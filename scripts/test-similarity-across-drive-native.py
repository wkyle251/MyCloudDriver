#!/usr/bin/env python3
"""Smoke-test packaged Across Drives with generated native inventories only."""
import argparse
import base64
import json
import os
from pathlib import Path
import queue
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib


class SmokeFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise SmokeFailure(message)


def png(path):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    pixels = b"".join(
        b"\0" + bytes(value for x in range(128) for value in
                      (x * 2, y * 2, ((x // 16 + y // 16) % 2) * 200))
        for y in range(128)
    )
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 128, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(pixels))
        + chunk(b"IEND", b"")
    )


def source(path):
    stat = path.stat()
    identity = base64.b64encode(path.as_uri().encode()).decode()
    return dict(
        id="cross-native:local:" + identity,
        provider="local",
        name=path.name,
        path=f"Local/{path.parent.name}/{path.name}",
        size=stat.st_size,
        local_path=str(path),
        revision=f"generated:{stat.st_ino}:{stat.st_size}:{stat.st_mtime_ns}",
    )


def write_inventory(path, sources):
    with path.open("w") as output:
        for item in sources:
            output.write(json.dumps(dict(event="file", file=item)) + "\n")
        output.write('{"event":"complete"}\n')


def owned_path(value, parent):
    require(isinstance(value, str), "Provider event has no owned response path")
    path = Path(value)
    require(path.is_absolute(), "Provider event has a relative response path")
    resolved = path.resolve()
    require(resolved != parent and parent in resolved.parents,
            "Provider event escaped the generated request directory")
    return resolved


def run_scan(executable, request, request_path, sources, environment):
    request_path.write_text(json.dumps(request))
    inventory = Path(request["external_source_stream"])
    write_inventory(inventory, sources)
    originals = {item["id"]: Path(item["local_path"]) for item in sources}
    resolved = {identifier: 0 for identifier in originals}
    events = []
    lines = queue.Queue()
    errors = []
    process = subprocess.Popen(
        [str(executable), "similarity-scan", "--request-file", str(request_path)],
        cwd=request_path.parent, env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, bufsize=1,
    )

    def read_output():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    def read_errors():
        # Keep diagnostics private, and keep the child from filling its pipe.
        # Neither signed URLs nor original names enter the smoke-test output.
        for line in process.stderr:
            if len(errors) < 200:
                errors.append(line)

    output_reader = threading.Thread(target=read_output, daemon=True)
    error_reader = threading.Thread(target=read_errors, daemon=True)
    output_reader.start()
    error_reader.start()
    deadline = time.monotonic() + 180
    copies = Path(request["temp_dir"]).resolve()
    private = request_path.parent.resolve()
    try:
        complete = False
        while not complete:
            require(time.monotonic() < deadline, "Generated scan exceeded its 180-second timeout")
            try:
                line = lines.get(timeout=min(0.2, max(0.01, deadline - time.monotonic())))
            except queue.Empty:
                continue
            if line is None:
                complete = True
                continue
            if not line.startswith("{"):
                continue
            event = json.loads(line)
            events.append(event)
            if event.get("event") == "resolve_source":
                identifier = event.get("id")
                require(identifier in originals, "Scanner requested an unknown generated source")
                directory = owned_path(event.get("directory"), copies)
                response = owned_path(event.get("response_file"), copies)
                require(directory.is_dir() and response.parent == directory.parent,
                        "Scanner requested an invalid generated source response")
                pending = response.with_suffix(".pending")
                pending.write_text(json.dumps(dict(id=identifier, path=str(originals[identifier]))))
                pending.chmod(0o600)
                pending.replace(response)
                resolved[identifier] += 1
            elif event.get("event") == "refresh_inventory":
                refreshed = owned_path(event.get("inventory_file"), private)
                require(refreshed.is_file(), "Scanner omitted its generated inventory response file")
                write_inventory(refreshed, sources)
        require(process.wait(timeout=max(0.1, deadline - time.monotonic())) == 0,
                "Packaged scanner exited unsuccessfully")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        output_reader.join(timeout=5)
        error_reader.join(timeout=5)
        process.stdout.close()
        process.stderr.close()

    require(events and events[-1].get("event") == "finished", "Scanner omitted its completion event")
    terminal = next((event for event in reversed(events) if event.get("stage") == "finishing"), None)
    require(terminal is not None, "Scanner omitted final comparison progress")
    report = json.loads(Path(request["report_path"]).read_text())
    require(report["source"] == "local" and report["status"] == "completed",
            "Unified native scan did not complete")
    require(report["scanned_files"] == report["analysed_files"] == len(sources),
            "Unified native scan omitted generated originals")
    require(report["skipped_files"] == report.get("failed_files", 0) == 0,
            "Unified native scan skipped generated originals")
    require({item["id"] for item in sources} == {item["id"] for item in report["files"]},
            "Unified native scan changed provider identities")
    require(all(file.get("local_path") == str(originals[file["id"]]) and file.get("cloud_id") is None
                for file in report["files"]), "Unified native scan lost original locators")
    counts = terminal["counts"]
    require(counts["files_processed"] == counts["files_total"] == len(sources),
            "Unified native progress has incorrect file totals")
    require(report["scores_retained"] == counts["pairs_processed"] == counts["pairs_total"] == 4,
            "Unified native comparison omitted cross-scope pairs")
    require(not any(Path(request["temp_dir"]).iterdir()), "Generated original staging survived completion")
    return report, counts, resolved


def query(executable, command, value, path, environment):
    path.write_text(json.dumps(value))
    result = subprocess.run(
        [str(executable), command, "--request-file", str(path)], env=environment,
        capture_output=True, text=True, timeout=30,
    )
    require(result.returncode == 0, "Saved cross-drive measurements could not be read")
    return json.loads(result.stdout)


def verify_cross_pairs(executable, request, report, originals, peer, query_path, environment):
    by_id = {file["id"]: file for file in report["files"]}
    original = originals[0]["id"]
    image = originals[1]["id"]
    exact_text, edited_text, exact_image = [item["id"] for item in peer]
    exact_sets = [{file["id"] for file in group["members"]}
                  for group in report["groups"] if group["match_kind"] == "byte_identical"]
    require({original, exact_text} in exact_sets and {image, exact_image} in exact_sets,
            "Exact content groups did not span the generated drive scopes")
    row = query(executable, "similarity-scores", dict(
        data_dir=request["data_dir"], run_id=report["run_id"], result_revision=report["result_revision"],
        file_id=original, row_offset=by_id[original]["engine_index"],
    ), query_path, environment)
    scores = {entry["file_id"]: entry["score"] for entry in row["entries"]}
    require(scores.get(exact_text) == 1.0, "Cross-scope exact text has an incorrect saved score")
    require(0.85 < scores.get(edited_text, -1) < 1.0,
            "Cross-scope edited text has an incorrect saved similarity")
    return 2, 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    args = parser.parse_args()
    resources = args.resources.resolve()
    executable = resources / "pikpak"
    models = resources / "FileTwinModels"
    require(executable.is_file() and (resources / "filetwin-worker").is_file() and models.is_dir(),
            "Packaged similarity resources are incomplete")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("PIKPAK_")}
    with tempfile.TemporaryDirectory(prefix="mycloud-generated-across-drive-") as temporary:
        root = Path(temporary).resolve()
        folders = [root / name for name in ("scope-a", "scope-b", "scope-c")]
        for folder in folders:
            folder.mkdir()
        text = ("The generated garden proposal describes fruit trees, bright flowers, a small pond, "
                "seasonal planting dates, irrigation pipes and a careful maintenance schedule. ") * 40
        (folders[0] / "original.txt").write_text(text)
        png(folders[0] / "picture.png")
        for folder, revision in zip(folders[1:], ("Add a wooden bench beside the pond.",
                                                "Add a summer watering schedule for the fruit trees.")):
            (folder / "exact.txt").write_text(text)
            (folder / "edited.txt").write_text(text + revision)
            shutil.copy2(folders[0] / "picture.png", folder / "picture-copy.png")
        originals = [source(folders[0] / name) for name in ("original.txt", "picture.png")]
        peers = [[source(folder / name) for name in ("exact.txt", "edited.txt", "picture-copy.png")]
                 for folder in folders[1:]]
        request = dict(
            source="local", local_paths=[], cloud_items=[], external_sources=[],
            external_source_stream=str(root / "inventory.jsonl"), refresh_inventory=True,
            families=["text", "image"], threshold=0.85, exact_duplicates=True,
            data_dir=str(root / "persistent-cache"), model_dir=str(models), temp_dir=str(root / "copies"),
            report_path=str(root / "results/report.json"),
            resources=dict(workers=2, memory_bytes=2 * 1024**3, download_memory_bytes=512 * 1024**2,
                           acceleration="cpu", automatic_memory=True, memory_scheduling=True),
            runtime=dict(worker_path=str(resources / "filetwin-worker"),
                         ffmpeg_path=shutil.which("ffmpeg"), ffprobe_path=shutil.which("ffprobe"),
                         onnxruntime_path=str(models / "runtime/libonnxruntime.dylib"),
                         pdfium_path=str(models / "runtime/libpdfium.dylib")),
        )
        summaries = []
        for iteration, peer in enumerate((peers[0], peers[1], peers[0])):
            report, counts, resolved = run_scan(executable, request, root / "request.json", originals + peer, environment)
            exact, similar = verify_cross_pairs(executable, request, report, originals, peer, root / "query.json", environment)
            if iteration == 0:
                require(all(resolved[item["id"]] == 1 for item in originals + peer),
                        "Initial native originals were not acquired once")
                with sqlite3.connect(Path(request["data_dir"]) / "runs" / (report["run_id"] + ".sqlite3")) as database:
                    extractions = [json.loads(row[0] or "{}") for row in database.execute("SELECT extraction FROM files")]
                require(any("worker_seconds" in extraction and extraction.get("input_storage") == "memory"
                            for extraction in extractions), "Packaged native worker did not analyze the generated image")
            else:
                require(all(resolved[item["id"]] == 0 for item in originals),
                        "Unchanged scope A reacquired its originals after the peer scope changed")
                require(counts["cache_hits"] >= len(originals), "Unchanged scope A did not reuse cached features")
                require(counts["bytes_hashed"] <= sum(item["size"] for item in peer),
                        "Unchanged scope A was hashed after the peer scope changed")
            if iteration == 2:
                require(counts["cache_hits"] == 5 and counts["vectors_encoded"] == counts["bytes_hashed"] == 0,
                        "Returning to a previous peer scope did not reuse all hashes and features")
                require(sum(resolved.values()) == 0, "Returning to a previous peer scope reacquired originals")
            summaries.append(dict(files=report["analysed_files"], compatible_pairs=report["scores_retained"],
                                  cross_exact_groups=exact, cross_similar_pairs=similar,
                                  cache_hits=counts["cache_hits"], vectors_encoded=counts["vectors_encoded"],
                                  bytes_hashed=counts["bytes_hashed"], acquired_originals=sum(resolved.values())))
        for label, summary in zip(("initial", "changed_peer", "returning_peer"), summaries):
            print("PASS generated across-native " + label + " " + json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except SmokeFailure as error:
        print("FAIL generated across-native: " + str(error), file=sys.stderr)
        raise SystemExit(1)
    except Exception as error:
        # An unexpected failure reports its type, never child output or paths.
        print("FAIL generated across-native: unexpected " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
