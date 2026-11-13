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

--md PATH writes just the single-file WowApiLib.md. --docs writes just the
same content split into topic pages, with a README.md front page, under
wow-api-docs/<version>.<build>-<client>/ -- small enough for an editor's
Markdown preview, which gives up on the single file.

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
    live_enums = runtime.get("enums") or {}
    undocumented_enums = sorted(n for n in live_enums
                                if n not in doc_enums and not is_meta_enum(n, live_enums))
    return missing, undocumented, undocumented_ns, undocumented_enums


META_KEYS = {"NumValues", "MinValue", "MaxValue"}


def is_meta_enum(name, enums):
    """
    Enum.FooMeta is the client's companion to Enum.Foo: NumValues, MinValue and
    MaxValue, which the documentation already carries on Foo itself. Nearly
    every enum has one, so without this they swamp the real undocumented ones.
    """
    if not name.endswith("Meta") or name[:-4] not in enums:
        return False
    values = enums[name]
    return isinstance(values, dict) and bool(values) and set(values) <= META_KEYS


# ---------------------------------------------------------------------------
# One file: WowApiLib.md
#
# Everything in a single Markdown document, laid out for reading and
# searching rather than for one-page-per-system browsing: lists instead of
# tables, every type name linked to its definition, and every restriction
# flag linked to one glossary entry that explains it, instead of repeating
# the explanation under each of the thousands of functions that carry it.
# Anchors are explicit <a id> tags, so they don't depend on how a renderer
# slugs headings full of dots and colons.
# ---------------------------------------------------------------------------

def anchor(kind, name):
    return kind + "-" + re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


class Linker:
    def __init__(self, files):
        self.tables, self.predicates = {}, {}
        for f in files:
            for t in f.get("Tables") or []:
                self.tables.setdefault(t["Name"], anchor("t", table_path(t)))
            # Widget types are referred to by object name (SimpleTexture,
            # LuaDurationObject) and documented as script objects with an
            # API suffix; point the one at the other.
            name = f.get("Name") or ""
            if f.get("Type") == "ScriptObject" and name.endswith("API"):
                self.tables.setdefault(name[:-3], anchor("s", name))
            for p in f.get("Predicates") or []:
                self.predicates.setdefault(p["Name"], (anchor("p", p["Name"]), p))

    def type_name(self, name):
        a = self.tables.get(name)
        return "[%s](#%s)" % (name, a) if a else name

    def type_of(self, f):
        t, inner, key = f.get("Type", "?"), f.get("InnerType"), f.get("KeyType")
        if key:
            s = "table<%s, %s>" % (self.type_name(key), self.type_name(inner or "?"))
        elif inner:
            s = "%s of %s" % (t, self.type_name(inner))
        else:
            s = self.type_name(t)
        if f.get("Mixin"):
            s += " (%s)" % f["Mixin"]
        return s

    def flags(self, doc, skip):
        """Flag names that are predicates link to the glossary; `true` is implied."""
        out = []
        for k in sorted(doc):
            if k in skip or not k[:1].isupper():
                continue
            v = doc[k]
            if k in self.predicates:
                link = "[%s](#%s)" % (k, self.predicates[k][0])
                out.append(link if v is True else "%s = `%s`" % (link, inline(v)))
            else:
                out.append("`%s = %s`" % (k, inline(v)))
        return out


def single_fields(linker, fields, heading):
    if not fields:
        return []
    out = ["*%s*" % heading, ""]
    for f in fields:
        line = "- `%s`%s: %s" % (f.get("Name", "?"), "?" if f.get("Nilable") else "", linker.type_of(f))
        if "Default" in f:
            line += " = `%s`" % inline(f["Default"])
        if docs_text(f):
            line += " -- " + docs_text(f).replace("\n", " ")
        extra = linker.flags(f, FIELD_LAID_OUT)
        if extra:
            line += " · " + " · ".join(extra)
        out.append(line)
    return out + [""]


def single_flags(linker, doc, skip=LAID_OUT):
    fl = linker.flags(doc, skip)
    return ["Flags: " + " · ".join(fl), ""] if fl else []


def single_function(linker, system, fn, missing):
    path = function_path(system, fn)
    call = "%s(%s)" % (path, names(fn.get("Arguments"), True))
    if fn.get("Returns"):
        call = "local %s = %s" % (names(fn["Returns"]), call)
    out = ['<a id="%s"></a>' % anchor("f", path), "#### %s" % path, ""]
    if path in missing:
        out += ["> **Missing** from the exporting client (SecureOnly, internal, or another platform).", ""]
    out += ["```lua", call, "```", ""]
    if docs_text(fn):
        out += [docs_text(fn), ""]
    out += single_fields(linker, fn.get("Arguments"), "Arguments")
    out += single_fields(linker, fn.get("Returns"), "Returns")
    out += single_flags(linker, fn)
    return out


def single_event(linker, ev):
    name = ev.get("LiteralName") or ev["Name"]
    out = ['<a id="%s"></a>' % anchor("e", name), "#### %s" % name, ""]
    out += ["```lua", "%s: %s" % (name, names(ev.get("Payload"), True)) if ev.get("Payload") else name, "```", ""]
    if docs_text(ev):
        out += [docs_text(ev), ""]
    out += single_fields(linker, ev.get("Payload"), "Payload")
    out += single_flags(linker, ev)
    return out


def single_table(linker, t):
    path = table_path(t)
    out = ['<a id="%s"></a>' % anchor("t", path), "#### %s" % path, "", "*%s*" % t.get("Type", "table"), ""]
    if docs_text(t):
        out += [docs_text(t), ""]
    if t.get("Type") == "Enumeration":
        out += ["- `%s` = %s" % (f["Name"], inline(f.get("EnumValue"))) for f in t.get("Fields") or []]
        out.append("")
    elif t.get("Type") == "Constants":
        out += ["- `%s` = `%s` (%s)" % (v["Name"], inline(v.get("Value")), v.get("Type", ""))
                for v in t.get("Values") or []]
        out.append("")
    elif t.get("Type") == "CallbackType":
        out += ["```lua", "%s = function(%s)" % (path, names(t.get("Arguments"))), "```", ""]
        out += single_fields(linker, t.get("Arguments"), "Arguments")
    else:
        out += single_fields(linker, t.get("Fields"), "Fields")
        out += single_fields(linker, t.get("Values"), "Values")
    out += single_flags(linker, t, LAID_OUT | {"NumValues", "MinValue", "MaxValue"})
    return out


def system_title(s):
    return s.get("Namespace") or s["Name"]


class Reader:
    """
    The pieces of the linked, reading-oriented Markdown, shared by the single
    WowApiLib.md and the split wow-api-docs/ pages. Every piece links with bare
    #anchors as if it were all one file; split_links() fixes that up per page.
    """

    def __init__(self, export):
        self.meta = export.get("meta") or {}
        self.docs = export.get("docs") or {}
        files = self.docs.get("files") or []
        self.files = files
        self.runtime = export.get("runtime")
        self.missing, self.undocumented, self.undocumented_ns, self.undocumented_enums = compare(files, self.runtime)
        self.linker = Linker(files)
        self.systems = sorted((f for f in files if f.get("Name") and f.get("Type") != "ScriptObject"),
                              key=lambda s: system_title(s).lower())
        self.scripts = sorted((f for f in files if f.get("Type") == "ScriptObject"),
                              key=lambda s: s["Name"].lower())
        self.shared = sorted((t for f in files if not f.get("Name") for t in f.get("Tables") or []),
                             key=lambda t: t["Name"].lower())
        self.predicates = sorted((p for _, p in self.linker.predicates.values()), key=lambda p: p["Name"].lower())

    def title(self):
        label = client_label(self.meta)
        return "WoW API %s (%s)%s" % (self.meta.get("gameVersion", "?"), self.meta.get("build", "?"),
                                      " -- " + label if label else "")

    def preamble(self):
        out = client_table(self.meta)
        out += ["How to read this:", "",
                "- Signatures are written the way they are called; `name?` is optional or nilable.",
                "- Type names link to their definition. Unlinked ones (`number`, `WOWGUID`, `UnitToken`, "
                "`AuraData`...) are built into the client and not defined in the documentation.",
                "- Flags that are restrictions link to [Restriction flags](#restriction-flags), "
                "which explains each one once.",
                "- **Missing** means documented but absent from the exporting client.", ""]
        if self.docs and not self.docs.get("complete"):
            out += ["> The documentation was already loaded by /api when this was exported; "
                    "predicates declared in shared files are missing.", ""]
        return out

    def restriction_flags(self):
        out = ["*Secret* flags mean the call works but may return secret values; "
               "*Precondition* flags mean it fails (see FailureMode) when the condition isn't met.", ""]
        for p in self.predicates:
            extra = self.linker.flags(p, {"Name", "Type", "Documentation"})
            line = '- <a id="%s"></a>**%s** (%s)' % (anchor("p", p["Name"]), p["Name"], p.get("Type", ""))
            if docs_text(p):
                line += ": " + docs_text(p).replace("\n", " ")
            if extra:
                line += " · " + " · ".join(extra)
            out.append(line)
        return out + [""]

    @staticmethod
    def system_index(items):
        rows = []
        for s in items:
            counts = "%d fn, %d ev, %d types" % (len(s.get("Functions") or []), len(s.get("Events") or []),
                                                 len(s.get("Tables") or []))
            sub = " (%s)" % s["Name"] if s.get("Namespace") else ""
            rows.append("- [%s](#%s)%s -- %s" % (system_title(s), anchor("s", s["Name"]), sub, counts))
        return rows + [""]

    def system_body(self, s):
        linker = self.linker
        body = ['<a id="%s"></a>' % anchor("s", s["Name"]),
                "### %s%s" % (system_title(s), " (%s)" % s["Name"] if s.get("Namespace") else ""), ""]
        if s.get("Environment") and s["Environment"] != "All":
            body += ["Environment: `%s`" % s["Environment"], ""]
        if docs_text(s):
            body += [docs_text(s), ""]
        body += single_flags(linker, s, LAID_OUT | {"Environment"})
        for fn in s.get("Functions") or []:
            body += single_function(linker, s, fn, self.missing)
        for ev in s.get("Events") or []:
            body += single_event(linker, ev)
        for t in s.get("Tables") or []:
            body += single_table(linker, t)
        if s.get("Predicates"):
            body += ["Declares restriction flags: " + ", ".join(
                "[%s](#%s)" % (p["Name"], anchor("p", p["Name"])) for p in s["Predicates"]), ""]
        return body

    def tables(self, tables):
        out = []
        for t in tables:
            out += single_table(self.linker, t)
        return out

    def runtime_missing(self):
        out = ["### Documented but missing (%d)" % len(self.missing), "",
               "Usually SecureOnly systems (callable only by Blizzard's code), internal tools, "
               "or another platform.", ""]
        return out + ["- [`%s`](#%s)" % (m, anchor("f", m)) for m in sorted(self.missing)] + [""]

    def runtime_undocumented(self):
        undocumented, runtime = self.undocumented, self.runtime
        total = sum(len(v) for v in undocumented.values())
        out = ["### Undocumented functions in documented namespaces (%d)" % total, "",
               "Callable, but with no declared arguments or returns.", ""]
        for nsname in sorted(undocumented):
            out.append("- `%s`: %s" % (nsname, ", ".join("`%s`" % fn for fn in undocumented[nsname])))
        out.append("")
        out += ["### Undocumented namespaces (%d)" % len(self.undocumented_ns), ""]
        for nsname in self.undocumented_ns:
            fns = runtime["namespaces"][nsname] or []
            out.append("- `%s`: %s" % (nsname, ", ".join("`%s`" % fn for fn in fns) or "(no functions)"))
        out.append("")
        out += ["### Undocumented enums (%d)" % len(self.undocumented_enums), ""]
        for name in self.undocumented_enums:
            values = runtime["enums"][name] or {}
            pairs = sorted(values.items(), key=lambda kv: (str(type(kv[1])), kv[1], kv[0])) \
                if isinstance(values, dict) else []
            out.append("- `Enum.%s`: %s" % (name, ", ".join("`%s` = %s" % (k, inline(v)) for k, v in pairs)))
        return out + [""]

    def widgets(self):
        return self.runtime.get("widgets") or {}

    def runtime_widgets(self):
        widgets = self.widgets()
        out = ["### Widget methods (%d types)" % len(widgets), "",
               "Read from each widget type's metatable in the live client.", ""]
        for w in sorted(widgets):
            out.append("- **%s** (%d): %s" % (w, len(widgets[w] or []),
                                             ", ".join("`%s`" % m for m in widgets[w] or [])))
        return out + [""]

    def extra_globals(self):
        docglobals = {fn["Name"] for f in self.files if f.get("Name") and not f.get("Namespace")
                      and f.get("Type") != "ScriptObject" for fn in f.get("Functions") or []}
        return [g for g in self.runtime.get("functions") or [] if g not in docglobals]

    def runtime_globals(self, by_letter=False):
        extra = self.extra_globals()
        out = ["### Global functions not in the docs (%d)" % len(extra), "",
               "The C API's undocumented globals and Blizzard's own Lua functions; %s more were "
               "defined by addons and left out." % self.runtime.get("addonFunctions", "?"), ""]
        if not by_letter:
            return out + [", ".join("`%s`" % g for g in extra), ""]
        letters = {}
        for g in extra:
            letters.setdefault(g[:1].upper(), []).append(g)
        for letter in sorted(letters):
            out += ["- **%s**: %s" % (letter, ", ".join("`%s`" % g for g in sorted(letters[letter], key=str.lower)))]
        return out + [""]


def single_markdown(export):
    r = Reader(export)
    out = ["# " + r.title(), ""] + r.preamble()

    out += ["## Contents", "",
            "- [Restriction flags](#restriction-flags) (%d)" % len(r.predicates),
            "- [Systems](#systems) (%d)" % len(r.systems),
            "- [Script objects](#script-objects) (widget APIs, %d)" % len(r.scripts),
            "- [Shared types](#shared-types) (%d)" % len(r.shared)]
    if r.runtime:
        out.append("- [Runtime](#runtime): what the client has that the docs don't, and the reverse")
    out.append("")

    out += ['<a id="restriction-flags"></a>', "## Restriction flags", ""] + r.restriction_flags()

    out += ['<a id="systems"></a>', "## Systems", ""] + r.system_index(r.systems)
    for s in r.systems:
        out += r.system_body(s)

    out += ['<a id="script-objects"></a>', "## Script objects", "",
            "The methods of widgets and other script objects, as `Object:Method`.", ""] + r.system_index(r.scripts)
    for s in r.scripts:
        out += r.system_body(s)

    out += ['<a id="shared-types"></a>', "## Shared types", "",
            "Types declared outside any system and used by several.", ""]
    out += r.tables(r.shared)

    if r.runtime:
        out += ['<a id="runtime"></a>', "## Runtime", "",
                "What existed in the exporting client, set against the documentation.", ""]
        out += r.runtime_missing() + r.runtime_undocumented() + r.runtime_widgets() + r.runtime_globals()
    return out


# ---------------------------------------------------------------------------
# Split pages: wow-api-docs/<version>.<build>-<client>/
#
# The same content as WowApiLib.md, cut into topic pages small enough for an
# editor's Markdown preview (the single file is several megabytes), plus a
# README.md front page linking to all of them. Links that cross pages are
# rewritten to page.md#anchor.
#
# Systems are grouped by their documentation name (MapUI, not C_Map), first
# match wins. A system no group claims lands in "Other systems", which is the
# cue to add it here.
# ---------------------------------------------------------------------------

SYSTEM_GROUPS = [
    ("units", "Units, the player and nameplates",
     "Unit info, auras, threat, deaths, unit frames and nameplates.",
     r"Unit|UnitAuras|UnitRole|PlayerScript|TargetScript|Threat|Totem|Title|RaidMarkers|PlayerInfo"
     r"|PlayerLocationInfo|CreatureInfo|ClassColor|AlliedRaces|Death.*|PaperDollInfo|CompactUnitFrames"
     r"|NamePlate.*|AuraContainerUtil|LossOfControl|IncomingSummon|SummonInfo|LevelLink|LevelSquish"),
    ("combat", "Spells, talents and combat",
     "Spells, the spellbook, action bars, talents and traits, specializations and the combat log.",
     r"Spell.*|ActionBar|AssistedCombat|ClassTalents|SharedTraits|TraitConfig|Specialization.*|GlyphInfo"
     r"|Combat.*|DamageMeter|CooldownViewer|ZoneAbility|Vehicle|PetInfo|ClickBindings"),
    ("items", "Items, bags and loot",
     "Items, containers and banks, equipment sets, upgrades, loot and currencies.",
     r"Item|Container|Bank|BagIndexConstants|EquipmentSet|ItemInteractionUI|ItemSocketInfo|ItemText"
     r"|ItemUpgrade|NewItems|Loot.*|WorldLootObject|ScrappingMachineUI|CurrencySystem"),
    ("economy", "Professions, trade and the auction house",
     "Professions and crafting orders, trainers, vendors, mail, trade and the auction house.",
     r"AuctionHouse|BlackMarketInfo|MerchantFrame|MailInfo|TradeInfo|GuildBank|WowTokenUI|TradeSkillUI"
     r"|CraftingOrderUI|ProfessionSpecUI|SkillInfo|Trainer"),
    ("collections", "Collections, appearance and pets",
     "Transmog, mounts, pets and pet battles, toys, heirlooms, the barber shop and the Trading Post.",
     r"Transmog.*|MountJournal|PetJournalInfo|BattlePet|PetBattles|StableInfo|ToyBoxInfo|HeirloomInfo"
     r"|DyeColorInfo|BarberShop|WarbandSceneInfo|Perks.*"),
    ("quests", "Quests, achievements and story",
     "The quest log, gossip, player choices, campaigns, achievements and tracking.",
     r"Quest.*|GossipInfo|PlayerChoice|WarCampaign|Achievement.*|TalkingHead|ContentTracking"
     r"|SuperTrackManager|ChromieTimeInfo|ResearchInfo|LoreText"),
    ("world", "Maps, zones and world events",
     "Maps, the minimap, flight paths, points of interest, vignettes and world events.",
     r"MapUI|MapExplorationInfo|Minimap|TaxiMap|AreaPoiInfo|Vignette|FogOfWar|InGameNavigation|AdventureMap"
     r"|InvasionInfo|WorldStateInfo|ZoneScript|ContributionCollector|EventSchedulerUI|LiveEvent"
     r"|WorldSafeLocs.*"),
    ("instances", "Dungeons, raids and the group finder",
     "The group finder, encounters and the journal, Mythic+, delves, scenarios and weekly rewards.",
     r"LFG.*|Encounter.*|Instance.*|RaidLocks|ChallengeModeInfo|MythicPlusInfo|DelvesUI|ScenarioInfo"
     r"|Islands.*|WeeklyRewards|AdventureJournal|PartyPose|UIModifiedInstance|RolesetSystem"),
    ("pvp", "PvP and the commentator",
     "Battlegrounds, arenas, rated PvP, duels, match results and the commentator.",
     r"PvpInfo|CommentatorFrame|DuelInfo|EndOfMatchUI|LobbyMatchmakerInfo"),
    ("progression", "Reputation, seasons and expansion features",
     "Reputations and renown, seasons, trials, and the systems of past expansions: garrisons, "
     "artifacts, Azerite, covenants.",
     r"ReputationInfo|MajorFactionsUI|SeasonInfo|Expansion.*|ClassTrial|TimerunningUI|GarrisonInfo"
     r"|Covenant.*|Soulbinds|AnimaDiversionInfo|ArdenwealdGardening|Azerite.*|ArtifactUI|RemixArtifactUI"
     r"|LegendaryCrafting"),
    ("chat", "Chat, voice and pings",
     "Chat channels and messages, chat bubbles, voice and text to speech, reporting and pings.",
     r"ChatInfo|ChatBubbles|VoiceChat|TTSSettings|ReportSystem|SocialRestrictions|BehavioralMessaging"
     r"|AutoComplete|PingManager.*"),
    ("social", "Friends, guilds, communities and groups",
     "Battle.net, friends, guilds and communities, parties and raids, social queue and the calendar.",
     r"Club|ClubFinderInfo|BattleNet|BNetOutage|FriendList|GuildInfo|PartyInfo|SocialQueue.*|SocialUI"
     r"|RecentAllies|RecruitAFriend|PlayerMentorship|Calendar|Discord|PhotoSharingUI"),
    ("housing", "Player housing",
     "Houses, neighborhoods, decor and the house editor.",
     r"Housing.*|House.*|NeighborhoodInitiative"),
    ("account", "Account, shop and support",
     "Account info, the in-game shop, entitlements, surveys, feedback and GM tickets.",
     r"AccountInfo|AccountStore|CatalogShop|StorePublic|WowEntitlementInfo|WowSurvey|UserFeedback"
     r"|GMTicketInfo|ExternalEventURL|ParentalControls|Browser"),
    ("interface", "Interface: widgets, tooltips and frames",
     "UI widgets, tooltips, Edit Mode, frame management, cursor, macros and key bindings, "
     "textures, models, cinematics and the screen.",
     r"UIWidgetManager|GenericWidgetDisplay|EditModeManager|UIFrameManager|Tooltip.*|GameUI|UI|UIColor"
     r"|ColorOverrides|KeyBindings|UIMacros|SlashCommand|Cursor|GameCursor|CursorUtil|TextureUtils"
     r"|UIFileAssetAPI|Font|UIEventToastManagerInfo|SplashScreen|Tutorial|LoadingScreen|ScriptedAnimations"
     r"|ModelInfo|Camera|Cinematic|CinematicList|Movie|ClientScene|Screen|MirrorTimer"
     r"|UISystemVisibilityManager|UIActionHandlerSystem|ImmersiveInteraction|PlayerInteractionManager"
     r"|GameError|LimitedInput|AccessibilityOptions"),
    ("client", "Client, settings and addons",
     "CVars and settings, sound, video, input and gamepad, the client and build, locale, time, "
     "addons and profiling, the console.",
     r"SettingsUtil|CVarScripts|Sound|Video|MacOptions|GamePad|Input|SystemInfo|Build|Client"
     r"|ConnectionScript|Glue|Streaming|Platform|Locale|Localization|URL|DateAndTime|SystemTime|Os"
     r"|AddOns|AddOnProfiler|PerformanceScript|Console|ConsoleScriptCollection|DebugToggle"
     r"|ConfigurationWarnings|InterfaceFileManifest|Log|ScriptWarnings|GameRules|Pony"),
    ("scripting", "Lua utilities, timers and secrets",
     "String, table, color, curve, duration and encoding helpers, timers, event utilities, "
     "secret values and restricted actions.",
     r"FrameScript|StringUtil|LuaTableUtil|ColorUtil|CurveUtil|DurationUtil|EncodingUtil|XMLUtil|EventUtils"
     r"|UITimer|SecretUtil|SecureTransfer|RestrictedActions"),
]
OTHER_GROUP = ("other", "Other systems", "Systems not yet sorted into a topic.")

SCRIPT_GROUPS = [
    ("widgets-regions", "Widgets: base objects, regions and animations",
     "The methods every widget inherits, plus textures, font strings, lines and animations.",
     r"Simple(Object|FrameScriptObject|Region|ScriptRegion|ScriptRegionResizing|Texture|TextureBase"
     r"|MaskTexture|Line|Font|FontString|VectorGraphics|ControlPoint|Anim.*)API"),
    ("widgets-frames", "Widgets: frames",
     "Frame and every frame type: buttons, edit boxes, sliders, status bars, models, cooldowns, "
     "tooltips, nameplates, map pins.",
     r"Simple.*|FrameAPI.*|.*FrameAPI"),
    ("script-objects", "Script objects: curves, durations and formatters",
     "Script objects that are not widgets.",
     r".*"),
]


def group_of(groups, name):
    for g in groups:
        if re.fullmatch(g[3], name):
            return g[0]
    return OTHER_GROUP[0]


def split_links(pages):
    """
    Point #anchor links at the page that holds the anchor. Where an anchor
    appears on several pages, the first page wins, as the first id would in
    one file.
    """
    home = {}
    for name, lines in pages.items():
        for line in lines:
            for a in re.findall(r'<a id="([^"]+)"></a>', line):
                home.setdefault(a, name)

    def fix(page):
        def repl(m):
            target = home.get(m.group(1))
            return "](%s#%s)" % (target, m.group(1)) if target and target != page else m.group(0)
        return repl

    return {name: [re.sub(r"\]\(#([^)\s]+)\)", fix(name), line) for line in lines]
            for name, lines in pages.items()}


def split_markdown(export):
    """{file name: lines}, README.md being the front page."""
    r = Reader(export)
    front = "README.md"
    pages, contents = {}, []

    def page(name, title, blurb, body):
        pages[name] = ["# " + title, "", "[%s](%s)" % (r.title(), front), ""] + \
                      ([blurb, ""] if blurb else []) + body
        return name

    def grouped(items, groups, key, kind, intro):
        by = {}
        for s in items:
            by.setdefault(group_of(groups, key(s)), []).append(s)
        rows = ["## " + kind, "", intro, ""]
        for slug, title, blurb, _ in list(groups) + [OTHER_GROUP + (None,)]:
            members = by.get(slug)
            if not members:
                continue
            body = r.system_index(members)
            for s in members:
                body += r.system_body(s)
            name = page(slug + ".md", title, blurb, body)
            rows += ["### [%s](%s)" % (title, name), "", blurb, ""]
            titles = [system_title(s) for s in members]
            rows += [", ".join("[%s](%s#%s)" % (
                system_title(s) + (" (%s)" % s["Name"] if titles.count(system_title(s)) > 1 else ""),
                name, anchor("s", s["Name"])) for s in members), ""]
        return rows

    contents += grouped(r.systems, SYSTEM_GROUPS, lambda s: s["Name"], "Systems (%d)" % len(r.systems),
                        "Functions, events and types, by topic.")
    contents += grouped(r.scripts, SCRIPT_GROUPS, lambda s: s["Name"],
                        "Script objects (%d)" % len(r.scripts),
                        "The methods of widgets and other script objects, as `Object:Method`.")

    reference = ["## Reference", ""]
    page("restriction-flags.md", "Restriction flags", None,
         ['<a id="restriction-flags"></a>'] + r.restriction_flags())
    reference.append("- [Restriction flags](restriction-flags.md) (%d): what each restriction flag on a "
                     "function means" % len(r.predicates))

    enums = [t for t in r.shared if t.get("Type") == "Enumeration"]
    others = [t for t in r.shared if t.get("Type") != "Enumeration"]
    if enums:
        page("shared-enums.md", "Shared enums", "Enums declared outside any system and used by several.",
             r.tables(enums))
        reference.append("- [Shared enums](shared-enums.md) (%d)" % len(enums))
    if others:
        page("shared-types.md", "Shared types",
             "Structures, constants and callbacks declared outside any system and used by several.",
             r.tables(others))
        reference.append("- [Shared types](shared-types.md) (%d): structures, constants, callbacks" % len(others))
    reference.append("")

    if r.runtime:
        page("runtime.md", "Runtime: docs vs client",
             "What existed in the exporting client, set against the documentation.",
             r.runtime_missing() + r.runtime_undocumented())
        page("runtime-widgets.md", "Runtime: widget methods", None, r.runtime_widgets())
        page("runtime-globals.md", "Runtime: global functions", None, r.runtime_globals(by_letter=True))
        reference += ["## Runtime", "",
                      "- [Docs vs client](runtime.md): %d documented functions missing from the client, "
                      "%d undocumented functions in documented namespaces, %d undocumented namespaces, "
                      "%d undocumented enums" % (len(r.missing), sum(len(v) for v in r.undocumented.values()),
                                                 len(r.undocumented_ns), len(r.undocumented_enums)),
                      "- [Widget methods](runtime-widgets.md) (%d types), from the live metatables" % len(r.widgets()),
                      "- [Global functions](runtime-globals.md) not in the docs (%d)" % len(r.extra_globals()),
                      ""]

    pages[front] = ["# " + r.title(), ""] + r.preamble() + contents + reference
    return split_links(pages)


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
    write(os.path.join(out_dir, "WowApiLib.md"), single_markdown(export))


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


def client_version(meta):
    """'12.0.1.64914-retail': the folder name for one client's output."""
    name = "%s.%s" % (meta.get("gameVersion", "unknown"), meta.get("build", "0"))
    if client_label(meta):
        name += "-" + client_label(meta)
    return safe_filename(name)


def default_out_dir(meta):
    return os.path.join(REPO, "export", client_version(meta))


def write_docs(export, root):
    """The split pages into <root>/<client version>/, replacing what was there."""
    out_dir = os.path.join(root, client_version(export.get("meta") or {}))
    if os.path.isdir(out_dir):
        for old in glob.glob(os.path.join(out_dir, "*.md")):
            os.remove(old)
    for name, lines in split_markdown(export).items():
        write(os.path.join(out_dir, name), lines)
    return out_dir


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
    ap.add_argument("--md", metavar="PATH",
                    help="write only the single-file WowApiLib.md, to PATH, and nothing else")
    ap.add_argument("--docs", metavar="DIR", nargs="?", const=os.path.join(REPO, "wow-api-docs"),
                    help="write only the split Markdown pages, to DIR/<version>.<build>-<client>/ "
                         "(default DIR: wow-api-docs in this repo), and nothing else")
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
    if args.md:
        write(os.path.abspath(args.md), single_markdown(export))
        print("wrote " + args.md)
    if args.docs:
        print("wrote " + write_docs(export, os.path.abspath(args.docs)))
    if args.md or args.docs:
        return 0

    out_dir = args.out or default_out_dir(meta)
    convert(export, out_dir)
    print("wrote " + out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
