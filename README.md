# WoW API Lib

Browse, search and export the World of Warcraft API from inside the game.

It reads two sources and shows where they disagree:

- **Blizzard's generated API documentation**: the data behind `/api`. It covers
  ~390 systems plus the widget script objects: every documented function with its
  argument and return types, every event and its payload, enums, structures,
  constants, callbacks, and the Midnight restriction flags (`SecretArguments`,
  `ConditionalSecret`, predicates...).
- **What actually exists in this client**: every global function, every `C_`
  namespace and Lua library, every `Enum`, and the methods of every widget type.
  This comes from walking `_G` and widget metatables. The scan only looks at
  names and never calls an API function.

Functions that exist but aren't documented are marked `?`. Functions that are
documented but absent from this client are marked `!`. Absent usually means the
system is `SecureOnly` or belongs to another game flavour.

## Use

| Command | |
|---|---|
| `/wal` (or `/apilib`) | open or close the browser |
| `/wal search <text>` | open the browser searching for `<text>` |
| `/wal export [all\|docs\|runtime]` | put the API into saved variables |
| `/wal clear` | drop the export from saved variables |
| `/wal rescan` | rescan the runtime, e.g. after other addons load more UI |
| `/wal stats` | counts |

In the browser, click a group to see it listed in full, or an entry to see its
signature, types, documentation and flags. The detail pane is an edit box:
**Select text**, then Ctrl+C, copies it.

Nothing loads at login. The documentation (a few megabytes of tables) and the
runtime scan load the first time you open the browser or export.

## Exporting to files

Addons can't write files, only saved variables. So:

1. In game: `/wal export`, then `/reload`. The client writes
   `WTF/Account/<ACCOUNT>/SavedVariables/WowApiLib.lua` (~3.5 MB).
2. Here: `python tools/convert.py`. It finds the newest export under
   `WOW_ROOT` (read from `deploy.py`) and writes
   `export/<version>.<build>-<client>/`, e.g. `export/12.0.1.64914-retail/`:
   - `WowApiLib.md`: everything in one readable file. Type names link to their
     definitions, and restriction flags link to a glossary that explains each one
   - `api.json`: everything, as exported
   - `index.md`: the client (version, build, interface, project, install
     folder, PTR/test/beta flags), systems, counts, and docs-vs-client differences
   - `systems/<Name>.md`: one page per system, with signatures and argument tables
   - `shared-types.md`, `runtime.md`, `globals.txt`
   For just the single file, from any copy of the export:
   `python tools/convert.py path/to/WowApiLib.lua --md WowApiLib.md`
   The single file is too big for VS Code's Markdown preview. For the same
   content split into topic pages (units, combat, items, housing, widgets...)
   with a `README.md` front page, in `wow-api-docs/<version>.<build>-<client>/`:
   `python tools/convert.py path/to/WowApiLib.lua --docs`
3. In game: `/wal clear`, then `/reload`, so the saved variables file stops
   being loaded at every login.

The export holds raw data: Blizzard's documentation tables as written, plus
the runtime scan. That means `tools/convert.py` can produce new formats without
a trip back into the game.

If you typed `/api` before WoW API Lib loaded the docs, the docs are rebuilt from
Blizzard's processed lists instead of captured. The only loss is the predicates
declared in files that belong to no system. `/reload` fixes it.

## Development

```
python deploy.py            # copy WowApiLib/ into a WoW install (WOW_ROOT at the top)
pip install lupa            # once; tests need a real Lua 5.1 interpreter
python tests/run.py         # fixtures, every scenario, plus the converter
python tests/run.py --ui <wow-ui-source>/Interface/AddOns
                            # the same suite against Blizzard's real documentation
```

The tests load the shipping addon, in `.toc` order, into Lua 5.1 against a
stubbed client. There are three scenarios: a normal load, docs already loaded
by `/api`, and the documentation addon refusing to load. Each scenario's export
is then written the way the client writes saved variables and run through the
converter.

`deploy.py` is shared verbatim with the other addon repos. It finds the addon
folder by its matching `.toc`, so it needs no edits.
