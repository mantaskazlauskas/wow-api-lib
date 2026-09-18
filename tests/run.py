#!/usr/bin/env python3
"""
Load WoW API Lib into a real Lua 5.1 interpreter against a stubbed client,
run the suite under each scenario, then feed each scenario's export through
tools/convert.py.

    pip install lupa
    python tests/run.py                   # fixtures, every scenario
    python tests/run.py fresh             # one scenario
    python tests/run.py --ui <AddOns dir> # Blizzard's real documentation

--ui points at a folder holding Blizzard_APIDocumentation/ and
Blizzard_APIDocumentationGenerated/, i.e. Interface/AddOns of a checkout of
https://github.com/Gethe/wow-ui-source (or of the client's own exported
interface files).
"""

import argparse
import json
import os
import pathlib
import sys
import tempfile

try:
    from lupa.lua51 import LuaRuntime          # WoW runs Lua 5.1
except ImportError:
    sys.exit("tests need lupa: pip install lupa")

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "tools"))
import convert  # noqa: E402

SCENARIOS = ["fresh", "preloaded", "noapi"]


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    return 0 if cond else 1


def run_lua(scenario, ui_root):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('SCENARIO = "%s"' % scenario)
    load = lua.eval("function(path, ...) return assert(loadfile(path))(...) end")
    load(str(HERE / "harness.lua"), (REPO / "WowApiLib").as_posix(),
         (HERE / "fixtures").as_posix(), ui_root)
    load(str(HERE / "suite_core.lua"))
    return lua


def run_converter(lua, scenario, real):
    print("\n-- converter")
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        # Where the client puts it, so the install folder can be read back.
        sv = pathlib.Path(tmp) / "_ptr_" / "WTF" / "Account" / "TEST" / "SavedVariables" / "WowApiLib.lua"
        sv.parent.mkdir(parents=True)
        # lupa hands Lua strings back decoded as UTF-8; re-encoding gives the
        # bytes the client would have written.
        sv.write_bytes(lua.eval("SerializeSavedVariables()").encode("utf-8"))
        out = pathlib.Path(tmp) / "out"
        convert.main([str(sv), "--out", str(out)])

        api = json.loads((out / "api.json").read_text(encoding="utf-8"))
        meta = api["meta"]
        failed += check(meta["schema"] == 1, "api.json has the meta")
        failed += check(meta.get("clientFolder") == "_ptr_", "client folder read from the path")
        failed += check(pathlib.Path(convert.default_out_dir(meta)).name == "12.0.1.99999-ptr",
                        "default output folder names the client: " + pathlib.Path(convert.default_out_dir(meta)).name)
        index = (out / "index.md").read_text(encoding="utf-8")
        failed += check(index.startswith("# WoW API 12.0.1 (99999) -- ptr"), "index.md title names the client")
        for row in ("| Project | MAINLINE (1) |", "| Client folder | `_ptr_` |", "| PTR client | yes |",
                    "| Test build | no |", "| Localized version | Version 12.0.1 |", "| Build info | Release x64 |"):
            failed += check(row in index, "index.md " + row)
        failed += check("Beta build" not in index, "index.md leaves out what the client did not report")
        failed += check((out / "runtime.md").exists(), "runtime.md written")

        if scenario == "noapi":
            failed += check("docs" not in api, "no docs in a runtime-only export")
            return failed

        n_lua = int(lua.eval("#NS.Docs.Files()"))
        failed += check(len(api["docs"]["files"]) == n_lua, "every documentation file round-trips (%d)" % n_lua)

        if real:
            md = (out / "systems" / "MapUI.md").read_text(encoding="utf-8")
            failed += check("local uiMapID = C_Map.GetBestMapForUnit(unitToken)" in md, "real MapUI page")
            return failed

        shared = next(f for f in api["docs"]["files"] if "Name" not in f)
        label = shared["Tables"][0]["Values"][1]["Value"]
        failed += check(label == 'line one\nline "two" \\ ü', "escapes and UTF-8 survive: %r" % label)
        failed += check(shared["Tables"][0]["Values"][0]["Value"] == 1.5, "floats survive")

        md = (out / "systems" / "MapUI.md").read_text(encoding="utf-8")
        failed += check("local uiMapID = C_Map.GetBestMapForUnit(unitToken)" in md, "function signature in Markdown")
        failed += check("Localized \"name\"\\|with a pipe" in md, "pipes escaped in Markdown tables")
        failed += check("`SecretArguments = AllowedWhenUntainted`" in md, "flags in Markdown")

        rt = (out / "runtime.md").read_text(encoding="utf-8")
        failed += check("`C_Map.GoneInThisClient`" in rt, "missing function reported")
        failed += check("`C_Map.SecretNewThing`" in rt, "undocumented function reported")
        failed += check("### C_Hidden" in rt, "undocumented namespace reported")
        failed += check("### Enum.UndocumentedE" in rt, "undocumented enum reported")
        failed += check("SomeBlizzardGlobal" in (out / "globals.txt").read_text(encoding="utf-8"), "globals.txt")
    return failed


def parser_selftest():
    print("\n#### converter parser " + "#" * 40)
    failed = 0
    data = convert.parse_saved_variables('''
X = {
["a"] = "b\\"c\\n\\195\\188",
["arr"] = {
"first", -- [1]
"second", -- [2]
},
[7] = 10,
["neg"] = -1.5e-09,
["hex"] = 0x1F,
["nested"] = { true, false, nil, },
bare = [[long
string]],
[3.5] = "float key",
}
Y = nil
''')
    x = data["X"]
    failed += check(x["a"] == 'b"c\nü', "escapes, including \\ddd bytes as UTF-8")
    failed += check(x["arr"] == ["first", "second"], "old-style arrays with -- [n] comments")
    failed += check(x["7"] == 10, "integer keys in a dict become strings")
    failed += check(x["neg"] == -1.5e-09 and x["hex"] == 31, "numbers")
    failed += check(x["nested"] == [True, False], "trailing nil dropped, list kept")
    failed += check(x["bare"] == "long\nstring", "long strings and bare keys")
    failed += check(x["3.5"] == "float key", "non-integer keys become strings")
    failed += check(data["Y"] is None, "nil globals")
    return failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenarios", nargs="*", help="any of: " + ", ".join(SCENARIOS))
    ap.add_argument("--ui", help="Interface/AddOns folder with Blizzard's documentation addons")
    args = ap.parse_args()
    for s in args.scenarios:
        if s not in SCENARIOS:
            ap.error("unknown scenario %r" % s)

    ui_root = pathlib.Path(args.ui).resolve().as_posix() if args.ui else None
    failed = parser_selftest()
    for scenario in args.scenarios or SCENARIOS:
        print("\n#### %s%s %s" % (scenario, " (real docs)" if ui_root else "", "#" * 40))
        lua = run_lua(scenario, ui_root)
        failed += int(lua.eval("FAILED") or 0)
        failed += run_converter(lua, scenario, ui_root is not None)

    print("\n" + "=" * 60)
    if failed:
        print("%d FAILED" % failed)
        return 1
    print("all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
