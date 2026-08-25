#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace


MODULE_PATH = Path(__file__).with_name("fli_cx_alt_loader_ab_supervisor.py")
SPEC = importlib.util.spec_from_file_location("fli_cx_alt_loader_ab_supervisor", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
SUPERVISOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUPERVISOR
SPEC.loader.exec_module(SUPERVISOR)


class SupervisorTests(unittest.TestCase):
    def test_parent_command_passes_dash_argument_as_separate_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            options = SimpleNamespace(
                runner=root / "runner",
                library=root / "library",
                fex_source=root / "source",
                fex_build=root / "build",
                parent_output=root / "parent-output",
                rootfs=root / "rootfs",
            )
            command = SUPERVISOR.build_parent_command(
                options,
                Path("/private/tmp/regression-fli-cx-alt-loader.test/loader.sock"),
            )
        argument_index = command.index("--guest-arg", command.index(r"C:\windows\system32\wineboot.exe"))
        self.assertEqual(command[argument_index : argument_index + 2], ["--guest-arg", "--init"])
        self.assertNotIn("--guest-arg=--init", command)

    def test_parent_command_keeps_private_wineserver_bridge_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            options = SimpleNamespace(
                runner=root / "runner",
                library=root / "library",
                fex_source=root / "source",
                fex_build=root / "build",
                parent_output=root / "parent-output",
                rootfs=root / "rootfs",
            )
            command = SUPERVISOR.build_parent_command(
                options,
                Path("/private/tmp/regression-fli-cx-alt-loader.test/loader.sock"),
            )

        self.assertIn("--instrument-vfork-parent-wineserver-bridge", command)
        self.assertLess(
            command.index("--instrument-vfork-parent-wineserver-bridge"),
            command.index("--initial-wine-command-line"),
        )

    def test_select_sample_targets_prefers_real_probe(self) -> None:
        rows = [
            {"pid": 101, "command": "/bin/bash runner"},
            {"pid": 102, "command": "/private/tmp/fli-fexcore-process-probe --real-rootfs"},
            {"pid": 103, "command": "/usr/bin/true"},
        ]
        self.assertEqual(SUPERVISOR.select_sample_targets(rows), [102])

    def test_terminate_group_collects_only_owned_session(self) -> None:
        external = subprocess.Popen(["/bin/sleep", "30"])
        owned = subprocess.Popen(
            ["/bin/sh", "-c", "/bin/sleep 30 & wait"],
            start_new_session=True,
        )
        try:
            time.sleep(0.1)
            result = SUPERVISOR.terminate_group(owned)
            self.assertTrue(result["term_sent"])
            self.assertIsNotNone(result["return_code"])
            self.assertIsNone(external.poll())
            self.assertEqual(SUPERVISOR.group_rows(owned.pid), [])
        finally:
            external.terminate()
            external.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
