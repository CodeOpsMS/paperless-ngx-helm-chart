#!/usr/bin/env python3
"""Exercise real child processes and TCP sockets without a Kubernetes cluster."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).with_name("e2e-port-forward.sh").resolve()
BASH = os.environ.get("BASH_BIN", "/bin/bash")


class PortForwardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.kubectl = self.root / "kubectl"
        self.kubectl.write_text(f"#!{sys.executable}\n" + '''
import json, os, signal, socket, sys
from pathlib import Path
port = int(sys.argv[-1].split(":")[0])
record = Path(os.environ["FORWARD_RECORD_DIR"]) / f"{port}.json"
record.write_text(json.dumps({"pid": os.getpid(), "args": sys.argv[1:]}))
with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen()
    print(f"Forwarding from 127.0.0.1:{port} -> 8000", flush=True)
    while True:
        signal.pause()
''')
        self.kubectl.chmod(0o700)

    def ports(self, count=2):
        listeners = [socket.socket() for _ in range(count)]
        try:
            for listener in listeners:
                listener.bind(("127.0.0.1", 0))
            return [listener.getsockname()[1] for listener in listeners]
        finally:
            for listener in listeners:
                listener.close()

    def run_bash(self, body, *args, context="", insecure="false"):
        process = subprocess.Popen(
            [BASH, "-c", '''
set -euo pipefail
source "$1"
KUBECTL_BIN=$2
work=$3
shift 3
PORT_FORWARD_PID=
PROMETHEUS_FORWARD_PID=
trap 'stop_kube_port_forward "$PORT_FORWARD_PID"; stop_kube_port_forward "$PROMETHEUS_FORWARD_PID"' EXIT
''' + body, "port-forward-test", str(HELPER), str(self.kubectl), str(self.root),
             *map(str, args)],
            env={**os.environ, "FORWARD_RECORD_DIR": str(self.root),
                 "KUBE_CONTEXT": context, "KUBE_INSECURE_SKIP_TLS_VERIFY": insecure},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=30)
            return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        finally:
            # Kill only this test's process group, including leaked children if
            # a regression makes the shell track a wrapper PID again.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)

    def assert_released(self, *ports):
        for port in ports:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", port))

    def test_three_baselines_reuse_both_ports_and_track_executable_pids(self):
        app, prometheus = self.ports()
        result = self.run_bash('''
for baseline in v2 v3 v313; do
  start_kube_port_forward PORT_FORWARD_PID "$work/app.log" -n "$baseline" service/paperless "$1:80"
  start_kube_port_forward PROMETHEUS_FORWARD_PID "$work/prometheus.log" -n "$baseline" service/prometheus "$2:9090"
  printf '%s %s\n' "$PORT_FORWARD_PID" "$PROMETHEUS_FORWARD_PID"
  stop_kube_port_forward "$PORT_FORWARD_PID"
  stop_kube_port_forward "$PROMETHEUS_FORWARD_PID"
done
''', app, prometheus)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 3)
        tracked = list(map(int, result.stdout.splitlines()[-1].split()))
        for port, pid in zip((app, prometheus), tracked):
            record = json.loads((self.root / f"{port}.json").read_text())
            self.assertEqual(record["pid"], pid)
            self.assertIn("v313", record["args"])
        self.assert_released(app, prometheus)

    def test_exit_trap_releases_both_listeners_on_failure(self):
        app, prometheus = self.ports()
        result = self.run_bash('''
start_kube_port_forward PORT_FORWARD_PID "$work/app.log" service/paperless "$1:80"
start_kube_port_forward PROMETHEUS_FORWARD_PID "$work/prometheus.log" service/prometheus "$2:9090"
exit 17
''', app, prometheus)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assert_released(app, prometheus)

    def test_occupied_port_fails_without_accepting_or_killing_other_listener(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            result = self.run_bash('''
start_kube_port_forward PORT_FORWARD_PID "$work/app.log" service/paperless "$1:80"
echo unexpected-success
''', port)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("unexpected-success", result.stdout)
            self.assertIn("Address already in use", result.stderr)
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                pass

    def test_context_and_tls_arguments_are_preserved(self):
        for context, insecure, prefix in (
            ("", "false", []),
            ("isolated-test", "false", ["--context", "isolated-test"]),
            ("", "true", ["--insecure-skip-tls-verify=true"]),
            ("isolated-test", "true", ["--context", "isolated-test", "--insecure-skip-tls-verify=true"]),
        ):
            with self.subTest(context=context, insecure=insecure):
                port, = self.ports(1)
                result = self.run_bash('''
start_kube_port_forward PORT_FORWARD_PID "$work/app.log" -n synthetic service/paperless "$1:80"
''', port, context=context, insecure=insecure)
                self.assertEqual(result.returncode, 0, result.stderr)
                record = json.loads((self.root / f"{port}.json").read_text())
                self.assertEqual(record["args"], prefix + ["port-forward", "--address=127.0.0.1",
                                 "-n", "synthetic", "service/paperless", f"{port}:80"])
                self.assert_released(port)


if __name__ == "__main__":
    unittest.main()
