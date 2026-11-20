#!/usr/bin/env python3
"""Run the fixture tests. Pass --gui in a logged-in Mac session to test normal quit."""
import argparse
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gui", action="store_true")
    gui = parser.parse_args().gui
    source = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="headroom-tests-") as temp:
        for test in sorted((source / "tests").glob("*Tests.swift")):
            module = test.stem.removesuffix("Tests")
            if module == "Vitals" and not gui:
                continue
            flags = ["-D", "DISKCARE_TESTING"] if module == "DiskCare" else []
            swift_file = {"Workspace": "WorkspaceScan", "Simulator": "SimulatorCare",
                          "Inventory": "WorkspaceInventory"}.get(module, module)
            dependencies = {"BackupMonitor": ["BackupProbe"], "BackupHistory": ["BackupMonitor", "BackupProbe"]}
            sources = [source / (name + ".swift") for name in [swift_file, *dependencies.get(module, [])]]
            binary = Path(temp) / test.stem
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", *flags,
                            *sources, test, "-o", binary], check=True)
            subprocess.run([binary], check=True)


if __name__ == "__main__":
    main()
