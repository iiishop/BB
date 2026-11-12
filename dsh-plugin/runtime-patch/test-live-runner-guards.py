"""Exercise the runner's signal guard without launching or signalling processes."""

import ast
import signal
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock


class SignalGuardTest(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).with_name("test-live-r3.py").read_text()
        function = next(
            node
            for node in ast.parse(source).body
            if isinstance(node, ast.FunctionDef) and node.name == "signal_owned_group"
        )
        self.process = SimpleNamespace(pid=222)
        self.os = SimpleNamespace(getpgid=Mock(return_value=111), killpg=Mock())
        self.scope = {"os": self.os, "daemon_pid": 111, "owned": [(self.process, None)]}
        # Load only our checked-in guard, never the runner's service startup.
        exec(  # noqa: S102
            compile(ast.Module(body=[function], type_ignores=[]), "guard", "exec"),
            self.scope,
        )
        self.guard = self.scope["signal_owned_group"]

    def test_owned_group_is_signalled(self):
        self.guard(self.process, signal.SIGTERM)
        self.os.killpg.assert_called_once_with(222, signal.SIGTERM)

    def test_missing_daemon_does_not_skip_owned_cleanup(self):
        self.os.getpgid.side_effect = ProcessLookupError
        self.guard(self.process, signal.SIGKILL)
        self.os.killpg.assert_called_once_with(222, signal.SIGKILL)

    def test_daemon_pid_rejected(self):
        self.process.pid = 111
        with self.assertRaises(AssertionError):
            self.guard(self.process, signal.SIGKILL)
        self.os.killpg.assert_not_called()

    def test_daemon_group_rejected(self):
        self.os.getpgid.return_value = 222
        with self.assertRaises(AssertionError):
            self.guard(self.process, signal.SIGTERM)
        self.os.killpg.assert_not_called()

    def test_unowned_process_rejected(self):
        with self.assertRaises(AssertionError):
            self.guard(SimpleNamespace(pid=333), signal.SIGTERM)
        self.os.killpg.assert_not_called()

    def test_already_exited_group_is_harmless(self):
        self.os.killpg.side_effect = ProcessLookupError
        self.guard(self.process, signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
