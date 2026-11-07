#!/usr/bin/env python3
"""Run an isolated 30-minute real-network background measurement. No IP/config output."""
import ctypes
import json
from pathlib import Path
import subprocess
import sys
import time

class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_ns", "system_ns", "idle_wakeups", "interrupt_wakeups", "pageins", "wired", "rss", "footprint", "started", "exited", "child_user", "child_system", "child_idle", "child_interrupt", "child_pageins", "child_elapsed", "disk_read", "disk_written")]

def measure(binary, directory):
    directory.mkdir(parents=True, exist_ok=True)
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    library.proc_pid_rusage.restype = ctypes.c_int
    started = time.monotonic()
    samples = []
    with (directory / "process-stderr.log").open("wb") as error:
        process = subprocess.Popen([str(binary), "--record-validation", str(directory)], stdout=subprocess.DEVNULL, stderr=error)
        while process.poll() is None:
            usage = Usage()
            if library.proc_pid_rusage(process.pid, 2, ctypes.byref(usage)) == 0:
                sample = {"elapsed": round(time.monotonic() - started, 3)}
                sample.update({name: getattr(usage, name) for name in ("user_ns", "system_ns", "idle_wakeups", "interrupt_wakeups", "rss", "footprint", "disk_read", "disk_written")})
                sample["database_bytes"] = sum(p.stat().st_size for p in directory.glob("history.sqlite*"))
                try:
                    sample.update(json.loads((directory / "counters.json").read_text()))
                except (OSError, ValueError):
                    pass
                samples.append(sample)
                (directory / "samples.json").write_text(json.dumps(samples, indent=2))
            if time.monotonic() - started > 1830:
                raise RuntimeError("Application did not exit within the measurement deadline; inspect it before replacing it")
            time.sleep(10)
    # last sample is just before the app's clean exit; retain actual sample duration.
    if not samples:
        raise RuntimeError("No process samples collected")
    final = samples[-1]
    initial = samples[0]
    steady = [s for s in samples if s["elapsed"] >= 60]
    ten_minutes = [s for s in samples if s["elapsed"] >= max(60, final["elapsed"] - 600)]
    cpu = lambda a, b: 100 * ((b["user_ns"] + b["system_ns"]) - (a["user_ns"] + a["system_ns"])) / 1e9 / max(b["elapsed"] - a["elapsed"], 0.001)
    report = {"exit_code": process.returncode, "wall_seconds": round(time.monotonic() - started, 2), "sample_seconds": final["elapsed"], "samples": len(samples), "cpu_percent_one_core_whole_run": cpu(initial, final), "cpu_percent_last_ten_minutes": cpu(ten_minutes[0], ten_minutes[-1]), "peak_rss_mib": max(s["rss"] for s in samples) / 1048576, "steady_rss_min_mib": min(s["rss"] for s in steady) / 1048576, "steady_rss_max_mib": max(s["rss"] for s in steady) / 1048576, "final_footprint_mib": final["footprint"] / 1048576, "disk_read_bytes": final["disk_read"] - initial["disk_read"], "disk_written_bytes": final["disk_written"] - initial["disk_written"], "final_database_bytes": final["database_bytes"], "final_rounds": final.get("rounds"), "final_requests": final.get("requests"), "storage_blocked": final.get("storageBlocked")}
    (directory / "summary.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    measure(Path(sys.argv[1]).expanduser().resolve(), Path(sys.argv[2]).expanduser().resolve())
