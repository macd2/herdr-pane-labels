"""Background watcher: relabel panes on every pane event, and every 5s as a fallback."""
import json, os, signal, socket, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOCK = os.environ.get("HERDR_SOCKET_PATH", os.path.expanduser("~/.config/herdr/herdr.sock"))
STATE = os.environ.get("HERDR_PLUGIN_STATE_DIR") or tempfile.gettempdir()
PIDFILE = os.path.join(STATE, "pane-labels-watch.pid")
EVENTS = ["pane.updated", "pane.agent_detected", "pane.exited",
          "pane.closed", "pane.focused", "pane.moved"]


def relabel():
    subprocess.run(["bash", os.path.join(HERE, "label.sh")], check=False)


def detach():
    # Startup hooks are one-shot: return to herdr at once and keep running on our own.
    if os.fork():
        sys.exit(0)
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)


def main():
    if "--foreground" not in sys.argv:
        detach()

    # One watcher per server: replace any previous one (startup reruns on live handoff).
    try:
        with open(PIDFILE) as f:
            os.kill(int(f.read()), signal.SIGTERM)
    except (OSError, ValueError):
        pass
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))

    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    s.sendall((json.dumps({"id": "pane-labels", "method": "events.subscribe",
                           "params": {"subscriptions": [{"type": e} for e in EVENTS]}}) + "\n").encode())
    relabel()
    while True:
        # Starting ssh emits no pane event, so also relabel on a 5s heartbeat.
        s.settimeout(5)
        try:
            if not s.recv(65536):
                break  # server gone; the next server's startup hook starts a fresh watcher
        except socket.timeout:
            relabel()
            continue
        s.settimeout(0.3)  # debounce: swallow the rest of the burst
        try:
            while s.recv(65536):
                pass
            break
        except socket.timeout:
            pass
        relabel()


if __name__ == "__main__":
    main()
