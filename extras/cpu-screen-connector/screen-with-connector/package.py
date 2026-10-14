"""Package the screen and the connector: build both separate artifacts.

The two chips stay separate, always -- this script never combines
their sources and writes no wrapper file.  It regenerates each
artifact from its own source with its own builder, refusing success
unless every compiler call exits 0 (the compiler writes NO artifact
on diagnostics, so an unchecked build ships yesterday's chip):

  screen.ws     -> extras/screen/screen.brz
  connector.ws  -> extras/cpu-screen-connector/connector.brz

  python -u extras/cpu-screen-connector/screen-with-connector/package.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))

SCREEN_DIR = os.path.join(ROOT, "extras", "screen")
CONN_DIR = os.path.join(ROOT, "extras", "cpu-screen-connector")


def run_step(label, argv):
    p = subprocess.run(argv, capture_output=True, text=True, cwd=ROOT,
                       encoding="utf-8", errors="replace")
    diag = [l.strip() for l in (p.stdout + "\n" + p.stderr).splitlines()
            if "WS" in l and "Error" in l]
    if p.returncode != 0:
        print("%s FAILED rc=%d, %d diagnostic(s)" % (label, p.returncode,
                                                     len(diag)))
        for l in diag[:8]:
            print("  %s" % l[:170])
        sys.exit(1)
    print("%s ok" % label)


def main():
    run_step("screen.gen", [sys.executable, "-u",
                            os.path.join(SCREEN_DIR, "gen.py")])
    run_step("screen.build", [sys.executable, "-u",
                              os.path.join(SCREEN_DIR, "build.py")])
    run_step("connector.build", [sys.executable, "-u",
                                 os.path.join(CONN_DIR, "build.py")])
    print("package: ALL GREEN (screen.brz + connector.brz, separate)")


if __name__ == "__main__":
    main()
