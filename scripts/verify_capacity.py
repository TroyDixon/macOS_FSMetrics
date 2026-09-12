#!/usr/bin/env python3
"""Exercise a running local collector with a temporary APFS disk image.

Run `make run` separately, then `python3 scripts/verify_capacity.py`.
Creates only its own temporary image and payload; detaches before removing them.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


BASE = "http://127.0.0.1:8080/api/v1"


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as response:
        assert response.headers["Access-Control-Allow-Origin"] == "*"
        return json.load(response)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, timeout=45).stdout


def find_mount(path):
    return next((m for m in get("/mounts")["data"] if m["mount_point"] == str(path)), None)


def wait_for(predicate, description, timeout=6):
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        result = predicate()
        if result:
            elapsed = time.monotonic() - started
            print(f"{description}: {elapsed:.2f}s", flush=True)
            return result
        time.sleep(0.1)
    raise AssertionError(f"Timed out: {description}")


def compare_local_mounts():
    health = get("/health")["data"]
    assert health["status"] == "ok", health
    mounts = get("/mounts")["data"]
    print(f"Health: ok; {len(mounts)} mounts", flush=True)
    assert all(m["fs_type"] not in ("devfs", "autofs") for m in mounts)
    for path in ("/", "/System/Volumes/Data"):
        m = next(m for m in mounts if m["mount_point"] == path)
        fields = run("df", "-k", path).decode().splitlines()[-1].split()
        df_used = int(fields[2]) * 1024
        used = m["capacity"]["used_bytes"]
        # Live system volumes can change between a sample and df.
        assert abs(used - df_used) < 64 * 1024 * 1024, (path, used, df_used)
        assert m["container_id"] is not None, m
        print(f"{path}: API used={used}; df used={df_used}; delta={used - df_used}", flush=True)
    data_mount = next(m for m in mounts if m["mount_point"] == "/System/Volumes/Data")
    info = plistlib.loads(run("diskutil", "info", "-plist", "/System/Volumes/Data"))
    assert data_mount["volume_uuid"] == info["VolumeUUID"]
    containers = plistlib.loads(run("diskutil", "apfs", "list", "-plist"))["Containers"]
    volume = next(v for c in containers for v in c["Volumes"] if v["APFSVolumeUUID"] == data_mount["volume_uuid"])
    assert abs(data_mount["capacity"]["used_bytes"] - volume["CapacityInUse"]) < 64 * 1024 * 1024
    print(f"Data UUID matches diskutil; CapacityInUse={volume['CapacityInUse']}", flush=True)


def verify_image():
    directory = Path(tempfile.mkdtemp(prefix="fsmon-capacity-")).resolve()
    image = directory / "capacity.sparseimage"
    mountpoint = directory / "mount"
    mountpoint.mkdir()
    attached = False
    device = None
    try:
        run("hdiutil", "create", "-size", "256m", "-fs", "APFS", "-volname", "FSMonCapacityTest",
            "-type", "SPARSE", "-o", str(image))
        attachment_bytes = run("hdiutil", "attach", "-nobrowse", "-plist", "-mountpoint", str(mountpoint), str(image))
        attached = True
        attachment = plistlib.loads(attachment_bytes)
        # The first entity is the whole disk belonging to this newly created image.
        device = attachment["system-entities"][0]["dev-entry"]
        before = wait_for(lambda: find_mount(mountpoint), "Image appears")
        assert before["capacity"] is not None
        assert before["container_id"] is not None
        mount_id = before["id"]
        payload = mountpoint / "payload.bin"
        with payload.open("wb") as output:
            chunk = os.urandom(1_000_000)
            for _ in range(100):
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        finished_write = time.monotonic()

        def increased():
            m = find_mount(mountpoint)
            if m and m["capacity"] and m["capacity"]["used_bytes"] >= before["capacity"]["used_bytes"] + 100_000_000:
                return m
            return None

        after = wait_for(increased, "100 MB write appears", timeout=5)
        assert time.monotonic() - finished_write < 5
        detail = get(f"/mounts/{mount_id}")["data"]
        assert detail["id"] == mount_id
        fields = run("df", "-k", str(mountpoint)).decode().splitlines()[-1].split()
        df_used = int(fields[2]) * 1024
        assert abs(after["capacity"]["used_bytes"] - df_used) < 1024 * 1024
        info = plistlib.loads(run("diskutil", "info", "-plist", str(mountpoint)))
        assert after["volume_uuid"] == info["VolumeUUID"]
        print(f"Image used bytes: {before['capacity']['used_bytes']} -> {after['capacity']['used_bytes']}; df={df_used}", flush=True)
        end = after["capacity"]["ts"] + 5
        series = get(f"/mounts/{mount_id}/capacity?from={end - 60}&to={end}&step=5")["data"]
        assert len(series["timestamps"]) == len(series["used_bytes"]) == 12
        assert any(v is None for v in series["used_bytes"])
        assert any(v is not None and v >= 100_000_000 for v in series["used_bytes"])
        run("hdiutil", "detach", device)
        attached = False
        wait_for(lambda: find_mount(mountpoint) is None, "Detached image disappears")
        try:
            get(f"/mounts/{mount_id}")
            raise AssertionError("Detached mount detail must be 404")
        except urllib.error.HTTPError as error:
            assert error.code == 404
        assert get(f"/mounts/{mount_id}/capacity")["data"]["series_id"] == mount_id
        print("All four endpoints, null gaps, detach, and retained history verified", flush=True)
    finally:
        if attached or os.path.ismount(mountpoint):
            # A failed detach must leave files in place: never recurse through a mount.
            run("hdiutil", "detach", device or str(mountpoint))
        if os.path.ismount(mountpoint):
            raise RuntimeError(f"Mount remains attached; preserving {directory}")
        shutil.rmtree(directory)
        print("Temporary disk image and payload removed after detach", flush=True)


if __name__ == "__main__":
    compare_local_mounts()
    verify_image()
