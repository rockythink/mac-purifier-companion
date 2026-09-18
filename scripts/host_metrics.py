"""Read-only macOS host condition and process CPU sampling."""

from __future__ import annotations

import ctypes
import math
import os
import sys
import time
from functools import lru_cache


_PROC_PIDTASKALLINFO = 2
_NANOSECONDS_PER_SECOND = 1_000_000_000


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class _ProcTaskInfo(ctypes.Structure):
    _fields_ = [
        ("pti_virtual_size", ctypes.c_uint64),
        ("pti_resident_size", ctypes.c_uint64),
        ("pti_total_user", ctypes.c_uint64),
        ("pti_total_system", ctypes.c_uint64),
        ("pti_threads_user", ctypes.c_uint64),
        ("pti_threads_system", ctypes.c_uint64),
        ("pti_policy", ctypes.c_int32),
        ("pti_faults", ctypes.c_int32),
        ("pti_pageins", ctypes.c_int32),
        ("pti_cow_faults", ctypes.c_int32),
        ("pti_messages_sent", ctypes.c_int32),
        ("pti_messages_received", ctypes.c_int32),
        ("pti_syscalls_mach", ctypes.c_int32),
        ("pti_syscalls_unix", ctypes.c_int32),
        ("pti_csw", ctypes.c_int32),
        ("pti_threadnum", ctypes.c_int32),
        ("pti_numrunning", ctypes.c_int32),
        ("pti_priority", ctypes.c_int32),
    ]


class _ProcTaskAllInfo(ctypes.Structure):
    _fields_ = [("pbsd", _ProcBSDInfo), ("ptinfo", _ProcTaskInfo)]


# pid -> ((start seconds, start microseconds), display name, consumed Mach ticks)
_ProcessReadings = dict[int, tuple[tuple[int, int], str, int]]


@lru_cache(maxsize=1)
def _libproc() -> ctypes.CDLL:
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.proc_listallpids.restype = ctypes.c_int
    library.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_pidinfo.restype = ctypes.c_int
    library.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_name.restype = ctypes.c_int
    return library


@lru_cache(maxsize=1)
def _libc() -> ctypes.CDLL:
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    library.sysctlbyname.argtypes = [
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    library.sysctlbyname.restype = ctypes.c_int
    return library


class _MachTimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


@lru_cache(maxsize=1)
def _mach_timebase() -> tuple[int, int]:
    function = _libc().mach_timebase_info
    function.argtypes = [ctypes.POINTER(_MachTimebaseInfo)]
    function.restype = ctypes.c_int
    info = _MachTimebaseInfo()
    if function(ctypes.byref(info)) != 0 or info.numer == 0 or info.denom == 0:
        raise OSError("Mach timebase unavailable")
    return int(info.numer), int(info.denom)


def _read_int_sysctl(name: bytes) -> int | None:
    value = ctypes.c_int()
    size = ctypes.c_size_t(ctypes.sizeof(value))
    if _libc().sysctlbyname(name, ctypes.byref(value), ctypes.byref(size), None, 0) != 0:
        return None
    if size.value != ctypes.sizeof(value):
        return None
    return value.value


@lru_cache(maxsize=1)
def _thermal_reader():
    foundation = ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    objc.objc_autoreleasePoolPush.argtypes = []
    objc.objc_autoreleasePoolPush.restype = ctypes.c_void_p
    objc.objc_autoreleasePoolPop.argtypes = [ctypes.c_void_p]
    objc.objc_autoreleasePoolPop.restype = None
    process_info_class = objc.objc_getClass(b"NSProcessInfo")
    process_info_selector = objc.sel_registerName(b"processInfo")
    thermal_selector = objc.sel_registerName(b"thermalState")
    if not process_info_class or not process_info_selector or not thermal_selector:
        raise OSError("Foundation thermal state unavailable")
    send_object = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
    send_integer = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
    pool = objc.objc_autoreleasePoolPush()
    try:
        process_info = send_object(process_info_class, process_info_selector)
    finally:
        objc.objc_autoreleasePoolPop(pool)
    if not process_info:
        raise OSError("Process information unavailable")
    # Keep libraries and the shared NSProcessInfo reader alive, not the sampled state.
    return foundation, objc, send_integer, process_info, thermal_selector


def _thermal_state() -> str | None:
    _, objc, send_integer, process_info, thermal_selector = _thermal_reader()
    pool = objc.objc_autoreleasePoolPush()
    try:
        state = send_integer(process_info, thermal_selector)
    finally:
        objc.objc_autoreleasePoolPop(pool)
    return {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}.get(state)


def read_system_conditions() -> dict[str, str | None]:
    """Return Foundation thermal state and the kernel's current memory pressure."""
    result: dict[str, str | None] = {
        "thermalState": None,
        "memoryPressure": None,
    }
    if sys.platform != "darwin":
        return result

    try:
        result["thermalState"] = _thermal_state()
    except Exception:
        pass

    try:
        pressure = _read_int_sysctl(b"kern.memorystatus_vm_pressure_level")
        # This sysctl exports DISPATCH flags, not the kernel's internal 0–4 enum.
        result["memoryPressure"] = {1: "normal", 2: "warning", 4: "critical"}.get(pressure)
    except Exception:
        pass
    return result


def _all_pids(library: ctypes.CDLL) -> list[int]:
    estimated = library.proc_listallpids(None, 0)
    if estimated <= 0:
        return []
    capacity = estimated + 128
    for _ in range(2):
        pids = (ctypes.c_int * capacity)()
        count = library.proc_listallpids(pids, ctypes.sizeof(pids))
        if count <= 0:
            return []
        if count < capacity:
            return [pid for pid in pids[:count] if pid > 0]
        capacity *= 2
    return [pid for pid in pids[:count] if pid > 0]


def _task_info(library: ctypes.CDLL, pid: int) -> _ProcTaskAllInfo | None:
    info = _ProcTaskAllInfo()
    read_size = library.proc_pidinfo(
        pid,
        _PROC_PIDTASKALLINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    return info if read_size == ctypes.sizeof(info) else None


def _process_name(library: ctypes.CDLL, pid: int) -> str | None:
    buffer = ctypes.create_string_buffer(64)
    length = library.proc_name(pid, buffer, len(buffer))
    if length <= 0:
        return None
    name = os.path.basename(buffer.raw[:length].split(b"\0", 1)[0].decode("utf-8", "replace"))
    return name if name and name.isprintable() else None


def _read_processes() -> _ProcessReadings:
    library = _libproc()
    readings: _ProcessReadings = {}
    for pid in _all_pids(library):
        before = _task_info(library, pid)
        if before is None:
            continue
        name = _process_name(library, pid)
        after = _task_info(library, pid)
        if name is None or after is None:
            continue
        before_identity = (
            int(before.pbsd.pbi_start_tvsec),
            int(before.pbsd.pbi_start_tvusec),
        )
        identity = (
            int(after.pbsd.pbi_start_tvsec),
            int(after.pbsd.pbi_start_tvusec),
        )
        if identity != before_identity:
            continue
        consumed = int(after.ptinfo.pti_total_user) + int(after.ptinfo.pti_total_system)
        readings[pid] = (identity, name, consumed)
    return readings


def _calculate_processes(
    first: _ProcessReadings,
    second: _ProcessReadings,
    elapsed: float,
    timebase: tuple[int, int],
) -> list[dict[str, int | str | float]]:
    if not math.isfinite(elapsed) or elapsed <= 0:
        return []
    processes: list[dict[str, int | str | float]] = []
    for pid, (identity, name, consumed) in second.items():
        previous = first.get(pid)
        if previous is None or previous[0] != identity:
            continue
        delta = consumed - previous[2]
        if delta < 0:
            continue
        cpu_percent = delta * timebase[0] / (timebase[1] * _NANOSECONDS_PER_SECOND * elapsed) * 100.0
        if not math.isfinite(cpu_percent) or cpu_percent < 0:
            continue
        processes.append({"pid": pid, "name": name, "cpuPercent": cpu_percent})
    processes.sort(key=lambda item: (-float(item["cpuPercent"]), int(item["pid"])))
    return processes[:3]


def sample_top_processes() -> dict[str, object]:
    """Sample per-process CPU counters for about one second and return the top three."""
    if sys.platform != "darwin":
        return {"timestamp": None, "processes": [], "error": "unsupported platform"}
    try:
        first = _read_processes()
        if not first:
            return {"timestamp": None, "processes": [], "error": "process data unavailable"}
        started = time.monotonic()
        time.sleep(1.0)
        second = _read_processes()
        elapsed = time.monotonic() - started
        if not second or not math.isfinite(elapsed) or elapsed <= 0:
            return {"timestamp": None, "processes": [], "error": "process data unavailable"}
        processes = _calculate_processes(first, second, elapsed, _mach_timebase())
        if not processes:
            return {"timestamp": None, "processes": [], "error": "process data unavailable"}
        timestamp = time.time()
        if not math.isfinite(timestamp) or timestamp <= 0:
            timestamp = None
        return {"timestamp": timestamp, "processes": processes, "error": None}
    except Exception as exception:
        return {
            "timestamp": None,
            "processes": [],
            "error": f"process sampling failed ({type(exception).__name__})",
        }
