#!/usr/bin/env python3
"""Start, stop and check the Layer 3 services that MxDataHUB and MxJobsMGR use.

    python3 Services/mxservices.py status            which services run, on which port, and what each is for
    python3 Services/mxservices.py start [ids…]       build if needed, then start (all when no ids)
    python3 Services/mxservices.py stop [ids…]
    python3 Services/mxservices.py restart [ids…]
    python3 Services/mxservices.py logs <id>          the last lines of a service's log
    python3 Services/mxservices.py catalog            the catalog as JSON
    python3 Services/mxservices.py install-agents     start them at login (writes ~/Library/LaunchAgents/com.k3jdr.mxservices.*.plist)
    python3 Services/mxservices.py uninstall-agents

Logs and pid files: ~/Library/Logs/MxServices/ (on Windows %LOCALAPPDATA%\\MxServices\\Logs). Every service listens
on 127.0.0.1 only. On Windows the services run without a console window and outlive the console that started them;
install-agents is macOS only (MxAppsRCP's MxDataHUB\\schedule starts srm-loader for its scheduled refresh).

status, and start / restart of srm-loader, analytics or accounts, end with a database line: the security master as
those services sign in to it (MxDataHUB/SRM/config.local.json, SRM_PG*, the Keychain or Credential Manager), with its
migration version and where the password came from, or the error. A service's "started" only means it answers
/health, which never touches the database.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

WINDOWS = sys.platform == "win32"
HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = (os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "MxServices", "Logs") if WINDOWS
        else os.path.expanduser("~/Library/Logs/MxServices"))
AGENTS = os.path.expanduser("~/Library/LaunchAgents")
PY = sys.executable
SRM_DIR = os.path.normpath(os.environ.get("SRM_DIR") or os.path.join(HERE, "..", "MxDataHUB", "SRM"))
SRM_SERVICES = ("srm-loader", "analytics", "accounts")     # the services that sign in to the security master

# id, folder, port, start command, build steps (when the artifact is missing), artifact, language, summary
SERVICES = [
    {"id": "srm-loader", "dir": "srm-loader", "port": 8770, "language": "Python",
     "summary": "Refresh the security master by data category (runs MxDataHUB/SRM/srm.py loaders)",
     "start": [PY, "srm_service.py"]},
    {"id": "analytics", "dir": "analytics", "port": 8772, "language": "Python",
     "summary": "Optimization inputs (covariance, alpha) and performance attribution from the security master",
     "start": [PY, "analytics_service.py"]},
    {"id": "accounts", "dir": "accounts", "port": 8774, "language": "Python",
     "summary": "Personal accounts (MxAcctMGR My Portfolio) in the security master: security search, tax lots, holdings",
     "start": [PY, "accounts_service.py"]},
    {"id": "portfolio-java", "dir": "portfolio-java", "port": 8766, "language": "Java",
     "summary": "Active (benchmark-relative) portfolio construction; absolute max-Sharpe",
     "start": ["java", "-jar", "target/portfolio-java.jar"],
     "artifact": "target/portfolio-java.jar", "build": [["mvn", "-q", "package", "-DskipTests"]]},
    {"id": "portfolio-cpp", "dir": "portfolio-cpp", "port": 8767, "language": "C++",
     "summary": "Passive index tracking (minimum tracking error) and portfolio risk",
     "start": ["./build/portfolio-cpp"], "artifact": "build/portfolio-cpp", "build": [["make"]]},
    {"id": "market-sample", "dir": "market-sample", "port": 8765, "language": "Python",
     "summary": "Synthetic quotes and indicators for building and testing jobspaces",
     "start": [PY, "mxjobs_service.py"]},
]


def service(sid):
    for s in SERVICES:
        if s["id"] == sid:
            return s
    sys.exit("unknown service %r; one of %s" % (sid, ", ".join(s["id"] for s in SERVICES)))


def selected(args):
    return [service(a) for a in args] if args else SERVICES


def get(url, timeout=1.5):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


def pid_file(s):
    return os.path.join(LOGS, s["id"] + ".pid")


def log_file(s):
    return os.path.join(LOGS, s["id"] + ".log")


def running_pid(s):
    try:
        pid = int(open(pid_file(s)).read().strip())
    except (OSError, ValueError):
        return None
    return pid if alive(pid) else None


def alive(pid):
    if not WINDOWS:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    # Not os.kill(pid, 0) on Windows: signal 0 is CTRL_C_EVENT there.
    import ctypes
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(0x1000, False, pid)        # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        return bool(kernel32.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259    # STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def port_pid(port):
    """The process listening on 127.0.0.1:port (lsof; netstat on Windows)."""
    try:
        if WINDOWS:
            out = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True).stdout
            for line in out.splitlines():
                parts = line.split()
                if len(parts) == 5 and parts[3] == "LISTENING" and parts[1].endswith(":%d" % port):
                    return int(parts[4])
            return None
        out = subprocess.run(["lsof", "-nP", "-iTCP:%d" % port, "-sTCP:LISTEN", "-t"], capture_output=True, text=True).stdout
    except OSError:
        return None
    return int(out.split()[0]) if out.strip() else None


def build(s):
    folder = os.path.join(HERE, s["dir"])
    if "artifact" not in s or os.path.exists(os.path.join(folder, s["artifact"])):
        return True
    for step in s.get("build", []):
        print("  building %s: %s" % (s["id"], " ".join(step)))
        tool = shutil.which(step[0])     # finds mvn.cmd on Windows, which CreateProcess alone would not
        if tool is None:
            print("  build of %s needs %s, which is not on the PATH" % (s["id"], step[0]))
            return False
        if subprocess.run([tool] + step[1:], cwd=folder).returncode != 0:
            print("  build of %s failed" % s["id"])
            return False
    return True


def start(s):
    if get("http://127.0.0.1:%d/health" % s["port"]):
        print("%-15s already running on %d" % (s["id"], s["port"]))
        return True
    if not build(s):
        return False
    os.makedirs(LOGS, exist_ok=True)
    folder = os.path.join(HERE, s["dir"])
    command = s["start"] + ["--port", str(s["port"])]
    if os.path.dirname(command[0]):
        command[0] = os.path.join(folder, command[0])           # ./build/portfolio-cpp
    else:
        command[0] = shutil.which(command[0]) or command[0]     # java; on Windows also a .cmd or .exe
    # UTF-8 output whatever the system's code page (Windows writes logs in its ANSI code page otherwise).
    env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    with open(log_file(s), "ab") as log:
        options = dict(cwd=folder, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
        try:
            if WINDOWS:
                # Its own hidden console (the loaders it starts share it, so no window opens), its own process
                # group (Ctrl+C here doesn't stop it), and out of this console's job when that is allowed.
                flags = subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP
                try:
                    proc = subprocess.Popen(command, creationflags=flags | subprocess.CREATE_BREAKAWAY_FROM_JOB,
                                            **options)
                except PermissionError:
                    proc = subprocess.Popen(command, creationflags=flags, **options)
            else:
                proc = subprocess.Popen(command, start_new_session=True, **options)
        except OSError as e:
            print("%-15s did not start: %s" % (s["id"], e))
            return False
    open(pid_file(s), "w").write(str(proc.pid))
    for _ in range(40):
        if get("http://127.0.0.1:%d/health" % s["port"]):
            print("%-15s started on http://127.0.0.1:%d (pid %d)" % (s["id"], s["port"], proc.pid))
            return True
        if proc.poll() is not None:
            break
        time.sleep(0.25)
    print("%-15s did not start; see %s" % (s["id"], log_file(s)))
    return False


def stop(s):
    pid = running_pid(s) or port_pid(s["port"])
    if not pid:
        print("%-15s not running" % s["id"])
        return
    if WINDOWS:
        # The service and what it started (a loader running srm.py).
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
    else:
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except OSError:
            os.kill(pid, signal.SIGTERM)
    for _ in range(20):
        if not get("http://127.0.0.1:%d/health" % s["port"], timeout=0.3):
            break
        time.sleep(0.25)
    try:
        os.remove(pid_file(s))
    except OSError:
        pass
    print("%-15s stopped" % s["id"])


def database():
    """Prints one line on the security master as srm-loader, analytics and accounts reach it: they connect with SRM's
    own Config (config.local.json, SRM_PG*, the Keychain or Credential Manager), read again on every connection, and
    this environment is the one they inherit. Never prints the password, only where it came from."""
    if SRM_DIR not in sys.path:
        sys.path.insert(0, SRM_DIR)
    where, source = "(SRM at %s)" % SRM_DIR, None
    try:
        from srmlib.common import Config
        config = Config()
        where = "%s@%s:%d/%s" % (config.user, config.host, config.port, config.dbname)
        source = config.password_and_source()[1]
        conn = config.connect()
        try:
            cur = conn.cursor()
            cur.execute("SELECT max(version) FROM srm_meta.schema_version")
            applied = cur.fetchone()[0]
        finally:
            conn.close()
    except Exception as e:      # psycopg2 missing, no route to host, refused, wrong password, no such role or table
        lines = [l for l in str(e).strip().splitlines() if l.strip()] or [type(e).__name__]
        print("%-15s %s  FAILED: %s%s" % ("database", where, lines[0], "  (password from %s)" % source if source else ""))
        for line in lines[1:]:
            print("%-15s %s" % ("", line.strip()))
        return False
    files = os.listdir(os.path.join(SRM_DIR, "migrations"))
    latest = max([int(m.group(1)) for m in (re.match(r"V(\d+)__", f) for f in files) if m] or [0])
    print("%-15s %s  migrations %s of %s  (password from %s)" % ("database", where, applied, latest, source))
    return True


def status():
    print("%-15s %-6s %-5s %-8s %s" % ("SERVICE", "LANG", "PORT", "STATE", "WHAT IT IS FOR"))
    for s in SERVICES:
        up = get("http://127.0.0.1:%d/health" % s["port"])
        print("%-15s %-6s %-5d %-8s %s" % (s["id"], s["language"], s["port"], "running" if up else "stopped", s["summary"]))
    print()
    database()
    print("\nStart them all: python3 %s start" % __file__.replace(os.path.expanduser("~"), "~"))


def catalog():
    out = []
    for s in SERVICES:
        live = get("http://127.0.0.1:%d/describe" % s["port"])
        out.append(dict({k: v for k, v in s.items() if k not in ("start", "build")},
                        folder=os.path.join(HERE, s["dir"]), running=live is not None, describe=live))
    print(json.dumps(out, indent=2))


def install_agents():
    os.makedirs(AGENTS, exist_ok=True)
    os.makedirs(LOGS, exist_ok=True)
    for s in SERVICES:
        if not build(s):
            continue
        label = "com.k3jdr.mxservices." + s["id"]
        args = "".join("<string>%s</string>" % a for a in s["start"] + ["--port", str(s["port"])])
        plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key><array>%s</array>
  <key>WorkingDirectory</key><string>%s</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict></plist>
""" % (label, args, os.path.join(HERE, s["dir"]), log_file(s), log_file(s))
        path = os.path.join(AGENTS, label + ".plist")
        stop(s)
        open(path, "w").write(plist)
        subprocess.run(["launchctl", "bootstrap", "gui/%d" % os.getuid(), path])
        print("%-15s installed as %s" % (s["id"], label))


def uninstall_agents():
    for s in SERVICES:
        label = "com.k3jdr.mxservices." + s["id"]
        path = os.path.join(AGENTS, label + ".plist")
        if os.path.exists(path):
            subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), label)])
            os.remove(path)
            print("%-15s removed" % s["id"])


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "status":
        status()
    elif cmd == "start":
        ok = all([start(s) for s in selected(args)])
        if any(s["id"] in SRM_SERVICES for s in selected(args)):
            database()
        sys.exit(0 if ok else 1)
    elif cmd == "stop":
        for s in selected(args):
            stop(s)
    elif cmd == "restart":
        for s in selected(args):
            stop(s)
            start(s)
        if any(s["id"] in SRM_SERVICES for s in selected(args)):
            database()
    elif cmd == "logs":
        s = service(args[0]) if args else sys.exit("logs <id>")
        try:
            with open(log_file(s), encoding="utf-8", errors="replace") as f:
                sys.stdout.writelines(f.readlines()[-60:])
        except OSError:
            sys.exit("no log for %s yet (%s)" % (s["id"], log_file(s)))
    elif cmd == "catalog":
        catalog()
    elif cmd in ("install-agents", "uninstall-agents") and WINDOWS:
        sys.exit("%s uses launchd, which is macOS only" % cmd)
    elif cmd == "install-agents":
        install_agents()
    elif cmd == "uninstall-agents":
        uninstall_agents()
    else:
        sys.exit("unknown command %r (status, start, stop, restart, logs, catalog, install-agents, uninstall-agents)" % cmd)


if __name__ == "__main__":
    main()
