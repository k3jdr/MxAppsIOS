#!/usr/bin/env python3
"""Start, stop and check the Layer 3 services that MxDataHUB and MxJobsWMS use.

    python3 Services/mxservices.py status            which services run, on which port, and what each is for
    python3 Services/mxservices.py start [ids…]       build if needed, then start (all when no ids)
    python3 Services/mxservices.py stop [ids…]
    python3 Services/mxservices.py restart [ids…]
    python3 Services/mxservices.py logs <id>          the last lines of a service's log
    python3 Services/mxservices.py catalog            the catalog as JSON
    python3 Services/mxservices.py install-agents     start them at login (writes ~/Library/LaunchAgents/com.k3jdr.mxservices.*.plist)
    python3 Services/mxservices.py uninstall-agents

Logs and pid files: ~/Library/Logs/MxServices/. Every service listens on 127.0.0.1 only.
"""

import json
import os
import signal
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.expanduser("~/Library/Logs/MxServices")
AGENTS = os.path.expanduser("~/Library/LaunchAgents")
PY = sys.executable

# id, folder, port, start command, build steps (when the artifact is missing), artifact, language, summary
SERVICES = [
    {"id": "srm-loader", "dir": "srm-loader", "port": 8770, "language": "Python",
     "summary": "Refresh the security master by data category (runs MxDataHUB/SRM/srm.py loaders)",
     "start": [PY, "srm_service.py"]},
    {"id": "analytics", "dir": "analytics", "port": 8772, "language": "Python",
     "summary": "Optimization inputs (covariance, alpha) and performance attribution from the security master",
     "start": [PY, "analytics_service.py"]},
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
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def port_pid(port):
    out = subprocess.run(["lsof", "-nP", "-iTCP:%d" % port, "-sTCP:LISTEN", "-t"], capture_output=True, text=True).stdout
    return int(out.split()[0]) if out.strip() else None


def build(s):
    folder = os.path.join(HERE, s["dir"])
    if "artifact" not in s or os.path.exists(os.path.join(folder, s["artifact"])):
        return True
    for step in s.get("build", []):
        print("  building %s: %s" % (s["id"], " ".join(step)))
        if subprocess.run(step, cwd=folder).returncode != 0:
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
    with open(log_file(s), "ab") as log:
        proc = subprocess.Popen(s["start"] + ["--port", str(s["port"])], cwd=os.path.join(HERE, s["dir"]),
                                stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
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


def status():
    print("%-15s %-6s %-5s %-8s %s" % ("SERVICE", "LANG", "PORT", "STATE", "WHAT IT IS FOR"))
    for s in SERVICES:
        up = get("http://127.0.0.1:%d/health" % s["port"])
        print("%-15s %-6s %-5d %-8s %s" % (s["id"], s["language"], s["port"], "running" if up else "stopped", s["summary"]))
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
        sys.exit(0 if ok else 1)
    elif cmd == "stop":
        for s in selected(args):
            stop(s)
    elif cmd == "restart":
        for s in selected(args):
            stop(s)
            start(s)
    elif cmd == "logs":
        s = service(args[0]) if args else sys.exit("logs <id>")
        subprocess.run(["tail", "-n", "60", log_file(s)])
    elif cmd == "catalog":
        catalog()
    elif cmd == "install-agents":
        install_agents()
    elif cmd == "uninstall-agents":
        uninstall_agents()
    else:
        sys.exit("unknown command %r (status, start, stop, restart, logs, catalog, install-agents, uninstall-agents)" % cmd)


if __name__ == "__main__":
    main()
