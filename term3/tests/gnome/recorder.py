# term3 GNOME test tier: runs inside the terminal under test and logs every
# byte term3 sends it, timestamped, to argv[1].
#
# It turns on the kitty keyboard protocol with flags 1|8 (disambiguate,
# report all keys as escape codes), so every key arrives as
# CSI <code>;<mods>u and a stuck or unexpected super shows up in <mods>.
# Bracketed paste is on, as in Claude Code, so a paste is distinguishable
# from typed keys.
import os
import select
import signal
import sys
import termios
import time
import tty

log = open(sys.argv[1], "a", buffering=1)
fd = os.open("/dev/tty", os.O_RDWR)
old = termios.tcgetattr(fd)


def note(kind, data):
    log.write(f"{time.time():.4f} {kind} {data!r}\n")


signal.signal(signal.SIGWINCH, lambda *_: note("RESIZE", os.get_terminal_size(fd)))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
tty.setraw(fd)
os.write(fd, b"\x1b[?2004h\x1b[>9u\x1b[2J\x1b[Hterm3 gnome test recorder\r\n")
note("READY", os.get_terminal_size(fd))
try:
    while True:
        try:
            ready, _, _ = select.select([fd], [], [], 0.5)
        except InterruptedError:
            continue
        if ready:
            data = os.read(fd, 4096)
            if not data:
                break
            note("IN", data)
finally:
    os.write(fd, b"\x1b[<u\x1b[?2004l")
    termios.tcsetattr(fd, termios.TCSAFLUSH, old)
