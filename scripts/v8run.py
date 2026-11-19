#!/usr/bin/env python3
"""Runs the 1C platform with a time limit. Used by run-tests.sh.

Usage: v8run.py [--timeout SECONDS] [--pidfile FILE] -- <executable> <argument>...

--pidfile writes the platform's process id to FILE right after the start: ui-check.sh runs the test client and the
test manager in the background and stops exactly these two processes (taskkill /T on Windows).

Arguments carry their own quotes inside the value, the way 1C expects them: /F"D:\\a b", /N"user",
/C"key=value". On Windows they are joined into one command line as they are (Git Bash would rewrite
/N..., /C..., /Out... as paths, and a list would be re-quoted). On macOS and Linux one layer of
framing quotes is removed, as the db-load-xml skill does: there the arguments go as a list and the
quotes would become part of the value.

Exit code: the platform's exit code; 124 if the time limit ran out (the process tree is killed first).
Call it with MSYS_NO_PATHCONV=1 under Git Bash so the arguments reach Python unchanged.
"""
import os
import subprocess
import sys


def strip_framing_quotes(arg):
    if len(arg) > 1 and arg[0] == '"' and arg[-1] == '"':
        return arg[1:-1]
    if arg[:1] == "/" and arg[-1:] == '"' and '"' in arg[:-1]:
        i = arg.index('"')
        return arg[:i] + arg[i + 1:-1]
    return arg


def main(argv):
    timeout = None
    pidfile = None
    while argv[:1] in (["--timeout"], ["--pidfile"]):
        if argv[0] == "--timeout":
            timeout = float(argv[1])
        else:
            pidfile = argv[1]
        argv = argv[2:]
    if argv[:1] == ["--"]:
        argv = argv[1:]
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    executable, arguments = argv[0], argv[1:]
    if os.name == "nt":
        command = '"' + executable + '" ' + " ".join(arguments)
    else:
        command = [executable] + [strip_framing_quotes(a) for a in arguments]
    process = subprocess.Popen(command)
    if pidfile:
        with open(pidfile, "w", encoding="ascii") as f:
            f.write(str(process.pid))
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True)
        else:
            process.kill()
        process.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
