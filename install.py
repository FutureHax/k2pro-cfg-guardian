#!/usr/bin/env python3
# On the printer, as root, without cloning:
#   python3 -c "import urllib.request;exec(urllib.request.urlopen('https://raw.githubusercontent.com/FutureHax/k2pro-cfg-guardian/main/install.py').read())"
# After a clone, from this directory:
#   python3 install.py

import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

REPO = "FutureHax/k2pro-cfg-guardian"
BRANCH = os.environ.get("CFG_BRANCH", "main")
URL = "https://github.com/%s/archive/refs/heads/%s.tar.gz" % (REPO, BRANCH)


def install_local(script):
    try:
        subprocess.check_call(["sh", script])
    except subprocess.CalledProcessError as err:
        sys.exit("sh %s failed (exit %s)" % (script, err.returncode))


def install_from_github():
    work = tempfile.mkdtemp(prefix="cfg-guardian-", dir="/tmp")
    try:
        print("downloading", URL, flush=True)
        try:
            data = urllib.request.urlopen(URL, timeout=90).read()
        except urllib.error.HTTPError as err:
            sys.exit("HTTP %s fetching %s" % (err.code, URL))
        except urllib.error.URLError as err:
            sys.exit("Could not fetch %s: %s" % (URL, err.reason))
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            tar.extractall(work)
        top = next(
            os.path.join(work, name)
            for name in os.listdir(work)
            if os.path.isdir(os.path.join(work, name))
        )
        install_local(os.path.join(top, "src", "install.sh"))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    if os.geteuid() != 0:
        sys.exit("run as root on the printer")

    # __file__ is missing when this file is exec'd from python3 -c.
    source = globals().get("__file__")
    local = None
    if source:
        candidate = os.path.join(os.path.dirname(os.path.abspath(source)), "src", "install.sh")
        if os.path.isfile(candidate):
            local = candidate
    if local:
        install_local(local)
    else:
        install_from_github()


if __name__ == "__main__":
    main()
