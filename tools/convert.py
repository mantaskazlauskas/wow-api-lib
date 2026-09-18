#!/usr/bin/env python3
"""
Turn a WoW API Lib export into JSON and Markdown.

In game:  /wal export   then   /reload
Here:     python tools/convert.py

With no argument the newest SavedVariables/WowApiLib.lua under any flavour and
account of WOW_ROOT (read from deploy.py) is used. The WoW folder is only ever
read. Output goes to export/<version>.<build>-<client>/ in this repo (client:
retail, ptr, classic_era... from the install folder) unless --out says
otherwise:

    api.json                 everything, as exported
    index.md                 systems, counts, and where docs and client disagree
    systems/<Name>.md        one page per documented system / script object
    shared-types.md          tables and predicates that belong to no system
    runtime.md               undocumented namespaces and enums, missing APIs,
                             widget methods
    globals.txt              every Blizzard global function, one per line

Standard library only.
"""

import argparse
import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SV_NAME = "WowApiLib.lua"
DB_NAME = "WowApiLibDB"
SCHEMA = 1


# ---------------------------------------------------------------------------
# Lua table literal parser
#
# Enough of Lua for what the client writes into saved variables: nested table
# constructors, ["string"] / [number] / bare-name keys, positional values,
# strings with escapes, numbers (including e-notation and hex), booleans, nil,
# and comments -- the client used to write `-- [n]` after array values.
# ---------------------------------------------------------------------------

TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<lcomment>--\[(?P<leq>=*)\[.*?\](?P=leq)\])
  | (?P<comment>--[^\n]*)
  | (?P<str>"(?:\\.|\\\n|[^"\\\n])*"|'(?:\\.|\\\n|[^'\\\n])*')
  | (?P<lstr>\[(?P<seq>=*)\[.*?\](?P=seq)\])
  | (?P<num>0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<punct>[{}\[\]=,;\-])
""", re.VERBOSE | re.DOTALL)

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b",
           "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


def unescape(body):
    # Works on latin-1 text, where one char is one byte, so \ddd escapes
    # (which are bytes) and raw UTF-8 bytes can both be put back together and
    # decoded once at the end.
    out, i, n = [], 0, len(body)
    while i < n:
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt.isdigit():
            m = re.match(r"\d{1,3}", body[i + 1:])
            out.append(chr(int(m.group(0))))
            i += 1 + len(m.group(0))
        else:
            out.append(ESCAPES.get(nxt, nxt))
            i += 2
    return "".join(out).encode("latin-1").decode("utf-8", "replace")


def tokenize(text):
    tokens = []
    pos, n = 0, len(text)
    while pos < n:
        m = TOKEN.match(text, pos)
        if not m:
            line = text.count("\n", 0, pos) + 1
            raise ValueError("unexpected character %r at line %d" % (text[pos], line))
        # lastgroup is the outermost group that matched, so the long forms
        # report as lcomment/lstr rather than their inner leq/seq.
        kind = m.lastgroup
        pos = m.end()
        if kind in ("ws", "comment", "lcomment"):
            continue
        tokens.append((kind, m.group(kind)))
    return tokens


class Parser:
    def __init__(self, tokens):
        self.t = tokens
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.t[j] if j < len(self.t) else (None, None)

    def take(self, value=None):
        tok = self.peek()
        if value is not None and tok[1] != value:
            raise ValueError("expected %r, got %r (token %d)" % (value, tok[1], self.i))
        self.i += 1
        return tok

    def value(self):
        kind, v = self.take()
        if kind == "str":
            return unescape(v[1:-1])
        if kind == "lstr":
            body = v[v.index("[", 1) + 1: v.rindex("]", 0, len(v) - 1)]
            if body.startswith("\n"):
                body = body[1:]
            return body.encode("latin-1").decode("utf-8", "replace")
        if kind == "num":
            return number(v)
        if kind == "name":
            if v == "true":
                return True
            if v == "false":
                return False
            if v == "nil":
                return None
            if v in ("inf", "huge"):
                return float("inf")
            if v == "nan":
                return float("nan")
            raise ValueError("unexpected name %r" % v)
        if v == "-":
            x = self.value()
            return -x
        if v == "{":
            return self.table()
        raise ValueError("unexpected %r" % v)

    def table(self):
        array, hashed = [], {}
        while True:
            kind, v = self.peek()
            if v == "}":
                self.take()
                break
            if v == "[" and self.peek(1)[0] != "lstr":
                self.take("[")
                key = self.value()
                self.take("]")
                self.take("=")
                hashed[key] = self.value()
            elif kind == "name" and self.peek(1)[1] == "=":
                self.take()
                self.take("=")
                hashed[v] = self.value()
            else:
                array.append(self.value())
            if self.peek()[1] in (",", ";"):
                self.take()
        return to_python(array, hashed)


def number(v):
    if v.lower().startswith("0x"):
        return int(v, 16)
    f = float(v)
    return int(f) if f.is_integer() and not re.search(r"[.eE]", v) else f


def to_python(array, hashed):
    """
    A Lua table with keys 1..n and nothing else is a list, anything else a
    dict. Positional values and explicit integer keys are the same thing in
    Lua, so they are merged before deciding.
    """
    merged = dict(hashed)
    for i, v in enumerate(array, start=1):
        merged[i] = v
    merged = {k: v for k, v in merged.items() if v is not None}
    n = len(merged)
    if all(isinstance(k, int) and not isinstance(k, bool) for k in merged) and \
            set(merged) == set(range(1, n + 1)):
        return [merged[i] for i in range(1, n + 1)]
    return {str(k) if not isinstance(k, str) else k: v for k, v in merged.items()}


def parse_saved_variables(text):
    """Return {global name: value} for every top-level assignment."""
    p = Parser(tokenize(text))
    out = {}
    while p.peek()[0] is not None:
        kind, name = p.take()
        if kind != "name":
            raise ValueError("expected a global name, got %r" % name)
        p.take("=")
        out[name] = p.value()
        if p.peek()[1] == ";":
            p.take()
    return out


# ---------------------------------------------------------------------------
# Locating the export
# ---------------------------------------------------------------------------

def wow_root():
    try:
        with open(os.path.join(REPO, "deploy.py"), encoding="utf-8") as f:
            m = re.search(r'^WOW_ROOT\s*=\s*r?["\'](.+?)["\']', f.read(), re.M)
            return m.group(1) if m else None
    except OSError:
        return None


def find_saved_variables():
    root = wow_root()
    if not root:
        sys.exit("no path given, and WOW_ROOT could not be read from deploy.py")
    pattern = os.path.join(root, "*", "WTF", "Account", "*", "SavedVariables", SV_NAME)
    found = glob.glob(pattern)
    if not found:
        sys.exit("no %s under %s\n(in game: /wal export, then /reload)" % (SV_NAME, root))
    found.sort(key=os.path.getmtime, reverse=True)
    if len(found) > 1:
        print("found %d, using the newest:" % len(found))
        for f in found:
            print("   " + f)
    return found[0]


# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------

LAID_OUT = {"Name", "Type", "Arguments", "Returns", "Payload", "Fields", "Values",
            "Documentation", "LiteralName", "Namespace", "Functions", "Events",
            "Tables", "Predicates"}
FIELD_LAID_OUT = {"Name", "Type", "Nilable", "Default", "InnerType", "KeyType",
                  "Mixin", "EnumValue", "Documentation"}


def md_escape(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def inline(v):
    if isinstance(v, list):
        return "{ " + ", ".join(inline(x) for x in v) + " }"
    if isinstance(v, dict):
        return "{ " + ", ".join("%s=%s" % (k, inline(v[k])) for k in sorted(v)) + " }"
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def lua_type(f):
    t = f.get("Type", "?")
    if f.get("KeyType"):
        t = "table<%s, %s>" % (f["KeyType"], f.get("InnerType", "?"))
    elif f.get("InnerType"):
        t = "%s of %s" % (t, f["InnerType"])
    if f.get("Mixin"):
        t += " (%s)" % f["Mixin"]
    return t


def names(fields, optional_mark=False):
    out = []
    for f in fields or []:
        opt = optional_mark and (f.get("Nilable") or "Default" in f)
        out.append(f.get("Name", "?") + ("?" if opt else ""))
    return ", ".join(out)


def flags(doc, skip):
    return ["%s = %s" % (k, inline(doc[k])) for k in sorted(doc)
            if k not in skip and k[:1].isupper()]


def docs_text(doc):
    d = doc.get("Documentation")
    return "\n".join(d) if isinstance(d, list) else ""


def field_table(fields, heading):
    if not fields:
        return []
    lines = ["**%s**" % heading, "", "| Name | Type | Nilable | Default | Notes |",
             "|---|---|---|---|---|"]
    for f in fields:
        notes = [docs_text(f)] + flags(f, FIELD_LAID_OUT)
        lines.append("| %s | %s | %s | %s | %s |" % (
            md_escape(f.get("Name", "?")), md_escape(lua_type(f)),
            "yes" if f.get("Nilable") else "",
            md_escape(inline(f["Default"])) if "Default" in f else "",
            md_escape("; ".join(n for n in notes if n))))
    lines.append("")
    return lines


def function_path(system, fn):
    if system.get("Type") == "ScriptObject":
        return "%s:%s" % (system["Name"], fn["Name"])
    if system.get("Namespace"):
        return "%s.%s" % (system["Namespace"], fn["Name"])
    return fn["Name"]


def table_path(t):
    if t.get("Type") == "Enumeration":
        return "Enum." + t["Name"]
    if t.get("Type") == "Constants":
        return "Constants." + t["Name"]
    return t["Name"]


def flag_lines(doc, skip=LAID_OUT):
    fl = flags(doc, skip)
    return (["Flags: " + ", ".join("`%s`" % x for x in fl), ""]) if fl else []


def md_function(system, fn, missing):
    path = function_path(system, fn)
    call = "%s(%s)" % (path, names(fn.get("Arguments"), True))
    if fn.get("Returns"):
        call = "local %s = %s" % (names(fn["Returns"]), call)
    out = ["### %s" % path, ""]
    if path in missing:
        out += ["> Documented, but not present in the exporting client.", ""]
    out += ["```lua", call, "```", ""]
    if docs_text(fn):
        out += [docs_text(fn), ""]
    out += field_table(fn.get("Arguments"), "Arguments")
    out += field_table(fn.get("Returns"), "Returns")
    out += flag_lines(fn)
    return out


def md_event(ev):
    name = ev.get("LiteralName") or ev["Name"]
    out = ["### %s" % name, ""]
    if ev.get("Payload"):
        out += ["```lua", "%s: %s" % (name, names(ev["Payload"], True)), "```", ""]
    if docs_text(ev):
        out += [docs_text(ev), ""]
    out += field_table(ev.get("Payload"), "Payload")
    out += flag_lines(ev)
    return out


def md_table(t):
    out = ["### %s" % table_path(t), "", "*%s*" % t.get("Type", "table"), ""]
    if docs_text(t):
        out += [docs_text(t), ""]
    if t.get("Type") == "Enumeration":
        out += ["| Name | Value |", "|---|---|"]
        out += ["| %s | %s |" % (f["Name"], inline(f.get("EnumValue")))
                for f in t.get("Fields", [])]
        out.append("")
    elif t.get("Type") == "Constants":
        out += ["| Name | Value | Type |", "|---|---|---|"]
        out += ["| %s | %s | %s |" % (v["Name"], md_escape(inline(v.get("Value"))), v.get("Type", ""))
                for v in t.get("Values", [])]
        out.append("")
    elif t.get("Type") == "CallbackType":
        out += field_table(t.get("Arguments"), "Arguments")
    else:
        out += field_table(t.get("Fields"), "Fields")
        out += field_table(t.get("Values"), "Values")
    out += flag_lines(t, LAID_OUT | {"NumValues", "MinValue", "MaxValue"})
    return out


def md_predicates(preds):
    if not preds:
        return []
    out = ["## Predicates", "", "| Name | Type | Notes |", "|---|---|---|"]
    for p in preds:
        notes = [docs_text(p)] + flags(p, {"Name", "Type", "Documentation"})
        out.append("| %s | %s | %s |" % (p["Name"], p.get("Type", ""),
                                          md_escape("; ".join(n for n in notes if n))))
    out.append("")
    return out


def md_system(system, missing):
    title = system.get("Namespace") or system["Name"]
    out = ["# %s" % title, ""]
    meta = ["System `%s`" % system["Name"]]
    if system.get("Type") == "ScriptObject":
        meta = ["Script object `%s`" % system["Name"]]
    if system.get("Environment") and system["Environment"] != "All":
        meta.append("environment `%s`" % system["Environment"])
    out += [", ".join(meta), ""]
    if docs_text(system):
        out += [docs_text(system), ""]
    out += flag_lines(system, LAID_OUT | {"Environment"})
    if system.get("Functions"):
        out += ["## Functions", ""]
        for fn in system["Functions"]:
            out += md_function(system, fn, missing)
    if system.get("Events"):
        out += ["## Events", ""]
        for ev in system["Events"]:
            out += md_event(ev)
    if system.get("Tables"):
        out += ["## Tables", ""]
        for t in system["Tables"]:
            out += md_table(t)
    out += md_predicates(system.get("Predicates"))
    return out


def safe_filename(name):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name)


# ---------------------------------------------------------------------------
# Docs vs runtime
# ---------------------------------------------------------------------------

def compare(files, runtime):
    """Returns (missing paths, undocumented namespace functions, undocumented namespaces, undocumented enums)."""
    if not runtime:
        return set(), {}, [], []
    live_ns = runtime.get("namespaces") or {}
    live_globals = set(runtime.get("functions") or [])
    doc_ns, doc_globals, doc_enums = {}, set(), set()
    missing = set()

    for f in files:
        for t in f.get("Tables") or []:
            if t.get("Type") == "Enumeration":
                doc_enums.add(t["Name"])
        if not f.get("Name") or f.get("Type") == "ScriptObject":
            continue
        nsname = f.get("Namespace")
        for fn in f.get("Functions") or []:
            if nsname:
                doc_ns.setdefault(nsname, set()).add(fn["Name"])
                if fn["Name"] not in set(live_ns.get(nsname) or []):
                    missing.add("%s.%s" % (nsname, fn["Name"]))
            else:
                doc_globals.add(fn["Name"])
                if fn["Name"] not in live_globals:
                    missing.add(fn["Name"])

    undocumented = {}
    for nsname, fns in doc_ns.items():
        extra = sorted(set(live_ns.get(nsname) or []) - fns)
        if extra:
            undocumented[nsname] = extra
    lua_libs = {"bit", "coroutine", "debug", "math", "os", "string", "table"}
    undocumented_ns = sorted(n for n in live_ns if n not in doc_ns and n not in lua_libs)
    undocumented_enums = sorted(n for n in (runtime.get("enums") or {}) if n not in doc_enums)
    return missing, undocumented, undocumented_ns, undocumented_enums


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines).rstrip() + "\n")


def convert(export, out_dir):
    meta = export.get("meta") or {}
    if meta.get("schema") != SCHEMA:
        print("warning: export schema %r, this converter knows %d" % (meta.get("schema"), SCHEMA))

    docs = export.get("docs") or {}
    files = docs.get("files") or []
    runtime = export.get("runtime")

    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "api.json"), "w", encoding="utf-8") as f:
        json.dump(export, f, indent=1, ensure_ascii=False)

    missing, undocumented, undocumented_ns, undocumented_enums = compare(files, runtime)

    systems = sorted((f for f in files if f.get("Name")),
                     key=lambda s: (s.get("Type") == "ScriptObject", (s.get("Namespace") or s["Name"]).lower()))
    shared = [f for f in files if not f.get("Name")]

    index = ["# WoW API %s (%s)%s" % (meta.get("gameVersion", "?"), meta.get("build", "?"),
                                       " -- " + client_label(meta) if client_label(meta) else ""), ""]
    index += client_table(meta)
    if docs and not docs.get("complete"):
        index += ["> The documentation was already loaded by /api when this was exported, so it was "
                  "rebuilt rather than captured: predicates declared in shared files are missing.", ""]

    if files:
        index += ["## Systems", "", "| System | Namespace | Functions | Events | Tables |",
                  "|---|---|---|---|---|"]
        for s in systems:
            fname = safe_filename(s["Name"]) + ".md"
            index.append("| [%s](systems/%s) | %s | %d | %d | %d |" % (
                s["Name"], fname, s.get("Namespace") or "",
                len(s.get("Functions") or []), len(s.get("Events") or []), len(s.get("Tables") or [])))
            write(os.path.join(out_dir, "systems", fname), md_system(s, missing))
        index.append("")

    if shared:
        lines = ["# Shared types", "", "Tables and predicates declared in files that belong to no system.", ""]
        preds = []
        for f in shared:
            for t in f.get("Tables") or []:
                lines += md_table(t)
            preds += f.get("Predicates") or []
        lines += md_predicates(preds)
        write(os.path.join(out_dir, "shared-types.md"), lines)
        index += ["[Shared types](shared-types.md)", ""]

    if runtime:
        rt = ["# Runtime", "", "What existed in the exporting client, set against the documentation.", ""]
        if missing:
            rt += ["## Documented but missing (%d)" % len(missing), ""]
            rt += ["- `%s`" % m for m in sorted(missing)] + [""]
        if undocumented:
            total = sum(len(v) for v in undocumented.values())
            rt += ["## Undocumented functions in documented namespaces (%d)" % total, ""]
            for nsname in sorted(undocumented):
                rt += ["- `%s.%s`" % (nsname, fn) for fn in undocumented[nsname]]
            rt.append("")
        if undocumented_ns:
            rt += ["## Undocumented namespaces (%d)" % len(undocumented_ns), ""]
            for nsname in undocumented_ns:
                fns = runtime["namespaces"][nsname] or []
                rt += ["### %s" % nsname, ""] + ["- `%s.%s`" % (nsname, fn) for fn in fns] + [""]
        if undocumented_enums:
            rt += ["## Undocumented enums (%d)" % len(undocumented_enums), ""]
            for name in undocumented_enums:
                values = runtime["enums"][name] or {}
                rt += ["### Enum.%s" % name, "", "| Name | Value |", "|---|---|"]
                rt += ["| %s | %s |" % (k, inline(v))
                       for k, v in sorted(values.items(), key=lambda kv: (str(type(kv[1])), kv[1], kv[0]))]
                rt.append("")
        widgets = runtime.get("widgets") or {}
        if widgets:
            rt += ["## Widget methods", ""]
            for w in sorted(widgets):
                rt += ["### %s (%d)" % (w, len(widgets[w] or [])), "",
                       ", ".join("`%s`" % m for m in widgets[w] or []), ""]
        write(os.path.join(out_dir, "runtime.md"), rt)
        write(os.path.join(out_dir, "globals.txt"), runtime.get("functions") or [])

        index += ["## Runtime", "",
                  "- %d Blizzard global functions ([globals.txt](globals.txt)); %s more defined by addons" % (
                      len(runtime.get("functions") or []), runtime.get("addonFunctions", "?")),
                  "- %d documented functions missing from the client" % len(missing),
                  "- %d undocumented functions in documented namespaces" % sum(len(v) for v in undocumented.values()),
                  "- %d undocumented namespaces, %d undocumented enums" % (len(undocumented_ns), len(undocumented_enums)),
                  "- %d widget types" % len(widgets),
                  "", "[Details](runtime.md)", ""]

    write(os.path.join(out_dir, "index.md"), index)


# ---------------------------------------------------------------------------
# Which client the export came from
#
# The addon records the version, build, project and test/beta flags. What it
# cannot see is which install folder it ran in, and that is what separates a
# retail export from a PTR one of the same version -- so it is read from the
# saved variables path here: <WOW_ROOT>/<folder>/WTF/Account/...
# ---------------------------------------------------------------------------

def client_folder(path):
    parts = os.path.normpath(os.path.abspath(path)).split(os.sep)
    for i in range(len(parts) - 1, 0, -1):
        if parts[i].upper() == "WTF":
            return parts[i - 1]
    return None


def client_label(meta):
    """'retail', 'ptr', 'classic_era'... from the folder, else the project name."""
    folder = meta.get("clientFolder")
    if folder and folder.startswith("_") and folder.endswith("_"):
        return folder.strip("_")
    if meta.get("projectName"):
        return str(meta["projectName"]).lower()
    return None


def default_out_dir(meta):
    name = "%s.%s" % (meta.get("gameVersion", "unknown"), meta.get("build", "0"))
    if client_label(meta):
        name += "-" + client_label(meta)
    return os.path.join(REPO, "export", safe_filename(name))


def client_table(meta):
    def yn(v):
        return "" if v is None else ("yes" if v else "no")

    project = meta.get("project")
    if meta.get("projectName"):
        project = "%s (%s)" % (meta["projectName"], project)
    rows = [
        ("Version", meta.get("gameVersion")),
        ("Build", meta.get("build")),
        ("Build date", meta.get("buildDate")),
        ("Interface", meta.get("interface")),
        ("Localized version", meta.get("localizedVersion")),
        ("Build info", meta.get("buildInfo")),
        ("Project", project),
        ("Client folder", meta.get("clientFolder") and "`%s`" % meta["clientFolder"]),
        ("PTR client", yn(meta.get("publicTestClient"))),
        ("Test build", yn(meta.get("testBuild"))),
        ("Beta build", yn(meta.get("betaBuild"))),
        ("Locale", meta.get("locale")),
        ("Exported", meta.get("exportedAt")),
        ("WoW API Lib", meta.get("addonVersion")),
    ]
    out = ["| Client | |", "|---|---|"]
    out += ["| %s | %s |" % (k, md_escape(v)) for k, v in rows if v not in (None, "")]
    return out + [""]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("saved_variables", nargs="?", help="path to %s (default: newest under WOW_ROOT)" % SV_NAME)
    ap.add_argument("--out", help="output directory (default: export/<version>.<build>-<client>)")
    args = ap.parse_args(argv)

    path = args.saved_variables or find_saved_variables()
    print("reading " + path)
    with open(path, encoding="latin-1") as f:
        data = parse_saved_variables(f.read())

    db = data.get(DB_NAME) or {}
    export = db.get("export") if isinstance(db, dict) else None
    if not export:
        sys.exit("no export in %s -- in game: /wal export, then /reload" % path)

    meta = export.setdefault("meta", {})
    folder = client_folder(path)
    if folder:
        meta["clientFolder"] = folder
    out_dir = args.out or default_out_dir(meta)
    convert(export, out_dir)
    print("wrote " + out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
