"""Verify the two small models of the chip's state machines with Quint.

    python -u tools/vmmodel.py            # both models
    python -u tools/vmmodel.py loopmodel  # one of them

What this is for: the loop-depth and protected-call bugs were both "the state is
wrong LATER", which a case diff cannot see and a model finds in minutes.  What it
is not for: proving the chip.  A model of the *chip* would need the chip's own
constants, every gate and the host's float laws; this proves the RULES the chip
now implements, and the cases in tests/cases.py prove the chip.

Everything external is discovered, and a missing piece is a skip rather than a
failure: WQUINT (or quint on PATH), JAVA_HOME (or java on PATH), and an Apalache
distribution under ~/.quint.  Quint's own automatic Apalache spawn hangs on
Windows, so the server is started here, used, and stopped.
"""
import glob
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MODELS = ("loopmodel", "pcallmodel")
# Enough steps to nest two frames, run a loop in each and leave both: the shapes
# the bugs lived in.  Deeper grows the state space fast and proves no more.
MAX_STEPS = 8
PORT = 8822


def find_quint():
    """The quint executable, or None."""
    cands = [os.environ.get("WQUINT"), shutil.which("quint"),
             os.path.join(os.path.expanduser("~"), "AppData", "Roaming",
                          "npm", "quint.cmd"),
             os.path.join(usr_local_bin(), "quint")]
    for c in cands:
        if c and os.path.isfile(c):
            return os.path.abspath(c)
    return None


def usr_local_bin():
    return os.path.join(os.path.expanduser("~"), ".local", "bin")


def find_java():
    """The java executable, or None."""
    home = os.environ.get("JAVA_HOME")
    if home:
        p = os.path.join(home, "bin", "java.exe" if os.name == "nt" else "java")
        if os.path.isfile(p):
            return p
    return shutil.which("java")


def find_apalache():
    """The Apalache jar, or None.  Quint unpacks its own download here."""
    env = os.environ.get("APALACHE_JAR")
    if env and os.path.isfile(env):
        return env
    pat = os.path.join(os.path.expanduser("~"), ".quint",
                       "apalache-dist-*", "**", "apalache.jar")
    hits = sorted(glob.glob(pat, recursive=True))
    return hits[-1] if hits else None


def port_open(port, host="127.0.0.1"):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex((host, port)) == 0


def start_server(java, jar, port, wait=60.0):
    """Start Apalache's server and wait for the port.  Returns the process.

    The server writes _apalache-out where it runs, so it runs in a scratch
    directory too."""
    work = tempfile.mkdtemp(prefix="vmmodel-server")
    proc = subprocess.Popen(
        [java, "-Xmx4g", "-jar", jar, "server", "--port=%d" % port],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=work)
    deadline = time.time() + wait
    while time.time() < deadline:
        if port_open(port):
            return proc
        if proc.poll() is not None:
            return None
        time.sleep(0.5)
    proc.kill()
    return None


def invariants_of(path):
    """The module's invariants, read out of the model itself.

    quint checks nothing unless it is told which vals to check, and a list kept
    here would be a second copy of the model's rules to fall out of step.  Every
    top-level `val` in the file is an invariant, so a new one is picked up by
    being written down.
    """
    names = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s.startswith("val "):
                names.append(s[4:].split("=")[0].strip())
    return names


def verify(quint, model, steps, endpoint=None, extra=()):
    """Run quint verify on one model.  A name is a model in tools/; anything
    ending in .qnt is a path, which is how a variant gets checked.  Returns
    (rc, seconds, output)."""
    path = model if model.endswith(".qnt") else os.path.join(
        HERE, model + ".qnt")
    invs = invariants_of(path)
    if not invs:
        print("    %s declares no invariant" % os.path.basename(path))
    cmd = [quint, "verify", "--max-steps", str(steps)]
    if endpoint:
        cmd += ["--server-endpoint", endpoint]
    if invs:
        cmd += ["--invariant", ",".join(invs)]
    cmd += list(extra)
    cmd.append(path)
    # quint and Apalache write _apalache-out wherever they are run, so they run
    # in a scratch directory and the repo stays clean.
    work = tempfile.mkdtemp(prefix="vmmodel")
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=work,
                       encoding="utf-8", errors="replace")
    return p.returncode, time.time() - t0, (p.stdout or "") + (p.stderr or "")


def main(argv):
    wanted = [a for a in argv[1:] if not a.startswith("-")]
    known = list(MODELS) + [m + ".qnt" for m in MODELS]
    models = [m for m in wanted] if wanted else list(MODELS)
    unknown = [m for m in models
               if m not in known and not os.path.isfile(m)]
    if unknown:
        print("no such model: %s; known: %s" % (", ".join(unknown),
                                               ", ".join(known)))
        return 1

    quint = find_quint()
    if not quint:
        print("vmmodel: SKIP (no quint: set WQUINT, or npm i -g @informalsystems/quint)")
        return 0

    endpoint = None
    server = None
    java, jar = find_java(), find_apalache()
    if port_open(PORT):
        endpoint = "localhost:%d" % PORT
        print("vmmodel: using the Apalache server already on %s" % endpoint)
    elif java and jar:
        print("vmmodel: starting Apalache on %d ..." % PORT)
        server = start_server(java, jar, PORT)
        if server is None:
            print("vmmodel: SKIP (could not start Apalache from %s)" % jar)
            return 0
        endpoint = "localhost:%d" % PORT
    else:
        print("vmmodel: SKIP (need java and an Apalache dist under ~/.quint)")
        return 0

    rc = 0
    # --key=value flags are handed to quint; a bare --name is not, because the
    # value would be read as a model name.
    extra = tuple(a for a in argv[1:] if a.startswith("--") and "=" in a)
    try:
        for m in models:
            code, secs, out = verify(quint, m, MAX_STEPS, endpoint, extra)
            bad = code != 0 or "counterexample" in out.lower() \
                or "invariant violated" in out.lower()
            print("%-10s %s  %.1fs" % (m, "FAIL" if bad else "OK", secs))
            for line in out.splitlines():
                if line.strip():
                    print("    " + line)
            rc = rc or (1 if bad else 0)
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
    print("vmmodel: %s" % ("FAIL" if rc else "OK"))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
