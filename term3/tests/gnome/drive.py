"""term3 GNOME test tier driver (run by term3/tests/gnome.sh, never directly).

Runs inside gnome.sh's private session: its own D-Bus, HOME, settings and a
headless GNOME Shell with the test extension. Starts term3 with the key
recorder in its terminal, sends real key events through Mutter's
RemoteDesktop API (the same path a keyboard takes) and checks what reached
the terminal and what GNOME Shell did.

What it covers:
  - super+v pastes and the keys after it arrive without super;
  - the race: super and v pressed together reach GNOME before term3's
    shortcuts inhibit exists, and GNOME opens the notification list, which
    takes the keyboard (reported, since how often it happens depends on
    timing);
  - gtk-defuse-gnome-shortcuts, toggled through the real Settings menu
    action: exactly the clashing GNOME shortcuts are removed, a fast super+v
    then still pastes and never opens a GNOME popup, the choice is saved to
    the config file, it is idempotent across restarts and config reloads,
    and turning it off restores exactly what it removed, keeping the user's
    own changes.
"""
import ast
import json
import os
import re
import subprocess
import sys
import time

import dbus

BIN, TMP = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
APPID = "io.github.kernelzeroday.term3"
OBJPATH = "/io/github/kernelzeroday/term3"
CONFIG = os.path.join(os.environ["XDG_CONFIG_HOME"], "term3", "config")
STATE = os.path.join(os.environ["XDG_STATE_HOME"], "term3", "defused-gnome-shortcuts")
EVENTS = os.environ["T3TEST_EVENTS"]
CLIP = os.environ["T3TEST_CLIPBOARD"]
SCHEMA = "org.gnome.shell.keybindings"
DEFUSED = {
    "toggle-message-tray": "<Super>v",
    "toggle-application-view": "<Super>a",
    "focus-active-notification": "<Super>n",
    "shift-overview-up": "<Super><Alt>Up",
    "shift-overview-down": "<Super><Alt>Down",
}
SUPER, V, A, X, ENTER, UP, ESC = 125, 47, 30, 45, 28, 103, 1
CLEAN_AFTER = ["a", "Enter", "Up"]

failures = []


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what, flush=True)
    if not ok:
        failures.append(what)
    return ok


# --- keys -------------------------------------------------------------------

bus = dbus.SessionBus()
_rd = dbus.Interface(
    bus.get_object("org.gnome.Mutter.RemoteDesktop", "/org/gnome/Mutter/RemoteDesktop"),
    "org.gnome.Mutter.RemoteDesktop")
_sess = dbus.Interface(
    bus.get_object("org.gnome.Mutter.RemoteDesktop", _rd.CreateSession()),
    "org.gnome.Mutter.RemoteDesktop.Session")
_sess.Start()


def key(code, down):
    _sess.NotifyKeyboardKeycode(dbus.UInt32(code), dbus.Boolean(down))


def tap(code, hold=0.04):
    key(code, True)
    time.sleep(hold)
    key(code, False)


def super_v(gap):
    """Super down, V after `gap` seconds; gap=0 is both at once."""
    key(SUPER, True)
    if gap:
        time.sleep(gap)
        tap(V)
        time.sleep(0.04)
    else:
        key(V, True)
        key(V, False)
    key(SUPER, False)


def super_a_instant():
    key(SUPER, True)
    key(A, True)
    key(A, False)
    key(SUPER, False)


# --- what reached the terminal, and what the shell did ----------------------

MODS = {1: "shift", 2: "alt", 4: "ctrl", 8: "super", 16: "hyper", 32: "meta"}
NAMES = {13: "Enter", 27: "Esc", 9: "Tab", 127: "Backspace"}
TOKEN = re.compile(
    rb"\x1b\[200~(.*?)\x1b\[201~"             # bracketed paste
    rb"|\x1b\[(\d+)(?::\d+)*(?:;(\d+))?u"     # kitty CSI u key
    rb"|\x1b\[(?:1;(\d+))?([ABCD])"           # arrows
    rb"|(.)", re.S)


def mods_name(n):
    n = int(n) - 1
    return "+".join(v for k, v in MODS.items() if n & k)


def decode(data):
    out = []
    for m in TOKEN.finditer(data):
        if m[1] is not None:
            out.append("PASTE:" + m[1].decode(errors="replace"))
        elif m[2]:
            c = int(m[2])
            name = NAMES.get(c, chr(c) if 32 < c < 127 else f"#{c}")
            md = mods_name(m[3]) if m[3] else ""
            out.append(f"{md}+{name}" if md else name)
        elif m[5]:
            name = {"A": "Up", "B": "Down", "C": "Right", "D": "Left"}[m[5].decode()]
            md = mods_name(m[4]) if m[4] else ""
            out.append(f"{md}+{name}" if md else name)
        else:
            out.append(repr(m[6]))
    return out


class Recorder:
    def __init__(self, path):
        self.path = path

    def lines(self):
        try:
            with open(self.path) as f:
                return [l.split(" ", 2) for l in f if l.strip()]
        except FileNotFoundError:
            return []

    def keys(self, t0, t1):
        # Join the reads first: one paste can arrive in several of them.
        data = b"".join(ast.literal_eval(rest) for t, kind, rest in self.lines()
                        if kind == "IN" and t0 <= float(t) < t1)
        out = decode(data)
        # The super press itself is reported too (CSI 57444): leave it out.
        return [k for k in out if not k.endswith("#57444")]

    def ready(self):
        return any(kind == "READY" for _, kind, _ in self.lines())


def events(t0, t1, name):
    try:
        with open(EVENTS) as f:
            evs = [json.loads(l) for l in f if l.strip()]
    except FileNotFoundError:
        return []
    return [e for e in evs if e["ev"] == name and t0 <= e["t"] < t1]


# --- term3 ------------------------------------------------------------------

_rec_path = None


def write_config(defuse):
    """The test config. term3 runs the recorder as its `command` (not -e,
    which makes it a non-unique instance with no D-Bus name or actions)."""
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        f.write("confirm-close-surface = false\n"
                "quit-after-last-window-closed = true\n"
                "linux-cgroup = never\n"
                f"command = {sys.executable} -I {os.path.join(HERE, 'recorder.py')} {_rec_path}\n"
                f"gtk-defuse-gnome-shortcuts = {'true' if defuse else 'false'}\n")


def set_recorder(path):
    """Point the config's command at a new recorder log, keeping the rest."""
    global _rec_path
    _rec_path = path
    with open(CONFIG) as f:
        text = f.read()
    text = re.sub(r"^command = .*$", f"command = {sys.executable} -I "
                  f"{os.path.join(HERE, 'recorder.py')} {path}", text, flags=re.M)
    with open(CONFIG, "w") as f:
        f.write(text)


def config_value():
    with open(CONFIG) as f:
        vals = re.findall(r"^gtk-defuse-gnome-shortcuts\s*=\s*(\S+)", f.read(), re.M)
    return vals[-1] if vals else None


class Term3:
    n = 0

    def __init__(self):
        Term3.n += 1
        self.rec = Recorder(os.path.join(TMP, f"rec-{Term3.n}.log"))
        set_recorder(self.rec.path)
        self.log = open(os.path.join(TMP, f"term3-{Term3.n}.log"), "w")
        self.proc = subprocess.Popen(
            [BIN, "--gtk-single-instance=true"],
            stdout=self.log, stderr=subprocess.STDOUT,
            # No accessibility bus in the private session: without this GTK fails
            # to register the app (and its actions) on D-Bus.
            env=dict(os.environ, GHOSTTY_LOG="stderr", GTK_A11Y="none"))
        deadline = time.time() + 30
        while time.time() < deadline and not self.rec.ready():
            if self.proc.poll() is not None:
                raise SystemExit(f"term3 exited at startup, see {self.log.name}")
            time.sleep(0.1)
        if not self.rec.ready():
            raise SystemExit("recorder never started in term3")
        # Wait until injected keys actually reach the terminal.
        for _ in range(40):
            t0 = time.time()
            tap(X)
            time.sleep(0.25)
            if "x" in self.rec.keys(t0, time.time()):
                return
        raise SystemExit("keys never reached term3 (window not focused?)")

    def act(self, name):
        r = subprocess.run(
            ["/usr/bin/gdbus", "call", "--session", "--dest", APPID, "--object-path", OBJPATH,
             "--method", "org.gtk.Actions.Activate", name, "@av []", "@a{sv} {}"],
            capture_output=True, text=True)
        if r.returncode != 0:
            names = subprocess.run(
                ["/usr/bin/gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
                 "--object-path", "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.ListNames"],
                capture_output=True, text=True).stdout
            raise SystemExit(f"action {name} failed: {r.stderr.strip()}\n"
                             f"term3 names on the bus: {[n for n in re.findall(r"'([^']+)'", names) if 'term3' in n]}")
        time.sleep(0.5)

    def quit(self):
        try:
            self.act("quit")
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        self.log.close()
        return self.proc.returncode

    def trial(self, press):
        """Run `press`, then type a, Enter, Up. Returns what reached the
        terminal during and after, and whether GNOME opened a popup."""
        t0 = time.time()
        press()
        time.sleep(0.4)
        t1 = time.time()
        tap(A)
        time.sleep(0.12)
        tap(ENTER)
        time.sleep(0.12)
        tap(UP)
        time.sleep(0.6)
        t2 = time.time()
        return dict(
            during=self.rec.keys(t0, t1), after=self.rec.keys(t1, t2),
            menu=bool(events(t0, t2, "menu-open")),
            overview=bool(events(t0, t2, "overview-showing")))


# --- GNOME settings ---------------------------------------------------------

def gget(key):
    out = subprocess.run(["/usr/bin/gsettings", "get", SCHEMA, key], check=True,
                         capture_output=True, text=True).stdout.strip()
    return [] if out.startswith("@as") else ast.literal_eval(out)


def gset(key, value):
    subprocess.run(["/usr/bin/gsettings", "set", SCHEMA, key, str(value)], check=True)


def snapshot():
    return {k: gget(k) for k in DEFUSED}


def same_combo(a, b):
    def norm(s):
        mods = set(x.lower().replace("mod4", "super").replace("primary", "control")
                   for x in re.findall(r"<([^>]+)>", s))
        return mods, re.sub(r"<[^>]+>", "", s).lower()
    return norm(a) == norm(b)


def stored_keys():
    """The defusable keys that hold a value of their own in the settings
    database (rather than following GNOME's default)."""
    out = subprocess.run(["/usr/bin/dconf", "dump", "/org/gnome/shell/keybindings/"],
                         capture_output=True, text=True).stdout
    return [k for k in DEFUSED if re.search(rf"^{re.escape(k)}=", out, re.M)]


def state_lines():
    try:
        with open(STATE) as f:
            return [l for l in f.read().splitlines() if l]
    except FileNotFoundError:
        return None


def pasted(r):
    return f"PASTE:{CLIP}" in r["during"]


# --- the tests --------------------------------------------------------------

def main():
    defaults = snapshot()
    print("GNOME defaults:", defaults, flush=True)
    check(all(any(same_combo(a, acc) for a in defaults[k]) for k, acc in DEFUSED.items()),
          "this GNOME binds every shortcut on term3's defuse list by default")

    print("== off (default): term3 leaves GNOME alone", flush=True)
    write_config(False)
    t = Term3()
    check(snapshot() == defaults, "starting with the setting off changes no GNOME shortcut")
    check(state_lines() is None, "no record file while nothing is defused")

    r = t.trial(lambda: super_v(0.08))
    check(pasted(r), f"super+v pastes ({r['during']})")
    check(r["after"] == CLEAN_AFTER, f"keys after super+v arrive without super ({r['after']})")

    reproduced = False
    for _ in range(3):
        r = t.trial(lambda: super_v(0))
        if r["menu"]:
            reproduced = True
            print(f"      race reproduced: GNOME opened the notification list; "
                  f"keys after it reached term3: {r['after']}", flush=True)
            check(r["after"] != CLEAN_AFTER, "while GNOME's popup is open the terminal gets no keys")
            tap(ESC)
            time.sleep(0.6)
            r2 = t.trial(lambda: None)
            check(r2["after"] == CLEAN_AFTER, f"closing the popup gives the keys back ({r2['after']})")
            break
    if not reproduced:
        print("      note: the super+v race didn't happen on this machine; "
              "the checks below still run", flush=True)

    print("== turned on from the Settings menu", flush=True)
    t.act("toggle-defuse-gnome-shortcuts")
    on = snapshot()
    for k, acc in DEFUSED.items():
        check(not any(same_combo(a, acc) for a in on[k]), f"{k}: {acc} removed (now {on[k]})")
        check([a for a in defaults[k] if not same_combo(a, acc)] == on[k],
              f"{k}: the other bindings are kept")
    check(on["toggle-message-tray"] == ["<Super>m"], "super+m still opens the notification list")
    lines = state_lines() or []
    check(len(lines) == len(DEFUSED), f"record file lists the {len(DEFUSED)} removed shortcuts")
    check(config_value() == "true", "the choice is saved to the config file")

    for i in range(5):
        r = t.trial(lambda: super_v(0))
        check(not r["menu"], f"fast super+v #{i + 1}: no GNOME popup")
        check(pasted(r), f"fast super+v #{i + 1}: pastes ({r['during']})")
        check(r["after"] == CLEAN_AFTER, f"fast super+v #{i + 1}: keys after it reach term3 ({r['after']})")
    for i in range(3):
        r = t.trial(super_a_instant)
        check(not r["overview"], f"fast super+a #{i + 1}: GNOME's app grid stays closed")
        check(r["after"] == CLEAN_AFTER, f"fast super+a #{i + 1}: keys after it reach term3 ({r['after']})")
    r = t.trial(lambda: super_v(0.08))
    # super+a selected the screen and copy-on-select (term3's default) put it
    # on the clipboard, so any paste counts here.
    check(any(k.startswith("PASTE:") for k in r["during"]) and r["after"] == CLEAN_AFTER,
          f"normal super+v still pastes ({r})")
    check(t.quit() == 0, "term3 quits cleanly")

    print("== on, after a restart", flush=True)
    t = Term3()
    check(snapshot() == on, "a restart with the setting on changes nothing more")
    check(state_lines() == lines, "the record is not duplicated")

    print("== turned off from the Settings menu", flush=True)
    t.act("toggle-defuse-gnome-shortcuts")
    check(snapshot() == defaults, f"every removed shortcut is back as it was ({snapshot()})")
    check(not stored_keys(), f"restored keys are back at GNOME's default, not a stored copy ({stored_keys()})")
    check(state_lines() is None, "the record file is removed")
    check(config_value() == "false", "the choice is saved to the config file")
    if reproduced:
        got = False
        for _ in range(3):
            r = t.trial(lambda: super_v(0))
            if r["menu"]:
                got = True
                tap(ESC)
                time.sleep(0.6)
                break
        check(got, "with GNOME's super+v back, the race opens its popup again")
    check(t.quit() == 0, "term3 quits cleanly")

    print("== the user's own changes are kept", flush=True)
    gset("toggle-message-tray", ["<Mod4>V", "<Super>m", "<Super>F12"])
    write_config(True)
    t = Term3()
    check(gget("toggle-message-tray") == ["<Super>m", "<Super>F12"],
          f"a differently spelled <Mod4>V is removed too ({gget('toggle-message-tray')})")
    check(any(l.endswith("\t<Mod4>V") for l in state_lines() or []),
          "the record keeps GNOME's own spelling")
    gset("toggle-message-tray", ["<Super>m", "<Super>F12", "<Super>v"])  # user re-binds it
    t.act("toggle-defuse-gnome-shortcuts")
    check(gget("toggle-message-tray") == ["<Super>m", "<Super>F12", "<Super>v"],
          "turning off doesn't add a shortcut the user already bound again")
    check(gget("toggle-application-view") == defaults["toggle-application-view"],
          "the other shortcuts are restored")
    check(t.quit() == 0, "term3 quits cleanly")
    subprocess.run(["/usr/bin/gsettings", "reset", SCHEMA, "toggle-message-tray"], check=True)

    print("== the config file and Reload Configuration", flush=True)
    write_config(False)
    t = Term3()
    write_config(True)
    t.act("reload-config")
    check(all(not any(same_combo(a, acc) for a in gget(k)) for k, acc in DEFUSED.items()),
          "setting it in the config file and reloading defuses")
    write_config(False)
    t.act("reload-config")
    check(snapshot() == defaults and not stored_keys(),
          "turning it off in the config file and reloading restores")
    check(t.quit() == 0, "term3 quits cleanly")

    bad = []
    for n in range(1, Term3.n + 1):
        with open(os.path.join(TMP, f"term3-{n}.log")) as f:
            bad += [l.strip() for l in f
                    if re.search(r"CRITICAL|panic|warning\(term3_gnome_shortcuts\)", l)]
    check(not bad, "no criticals or defuse warnings in term3's log" + (f": {bad[:5]}" if bad else ""))

    _sess.Stop()
    print()
    if failures:
        print(f"gnome: {len(failures)} FAILED")
        sys.exit(1)
    print("gnome: passed")


main()
