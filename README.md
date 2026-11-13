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
| `/wal inspect` | pick a frame on screen and open its widget APIs |
| `/wal minimap` | hide or show the minimap button |

The browser also has a minimap button (left-drag moves it around the rim) and
an entry in the addon compartment, the grouped addons button by the minimap.
Click either to open or close it. UIs that collect minimap buttons into a grid,
such as EllesmereUI, pick the minimap button up there.

In the browser, click a group to see it listed in full, or an entry to see its
signature, types, documentation and flags. The detail pane is an edit box:
**Select text**, then Ctrl+C, copies it.

- **Search** matches names. `type:AuraData` finds everything whose arguments,
  returns, payload or fields use that type; `field:unitTarget` finds everything
  with an argument, return or field of that name.
- **Filters** under the search box narrow it to functions, events or types, and
  to restricted (a `Secret*` flag or a precondition such as `RequiresValidMap`),
  undocumented or missing entries. They work with or without search text.
  Restricted entries are tagged `R` in the list, and their flags are listed
  under **Restrictions**, ahead of the arguments.
- **Links** above the detail text go to the entry's group and to every type it
  uses. **<** and **>** (or the mouse's back and forward buttons) walk back
  through what you looked at.
- **Favorite** on an entry adds it to a Favorites group at the top of the list.
- **As Lua** switches the detail pane to Lua annotations (the LuaLS format VS
  Code's Lua extension reads): `---@param`/`---@return` with Lua types, classes
  for structures, `---@enum` for enums, restrictions as comments. Paste one into
  a definitions file for completion, or into a chat as the exact signature. It
  works for a whole group too, and the choice is remembered.
- **Inspect** (or `/wal inspect`) works like `/fstack`: hover a frame to see
  what it is, press Shift to open it, Escape to stop. The browser shows its
  size, anchors, parents and the scripts it has set, lists its widget type's
  methods, and links to the widget API docs that apply to it. Only frames that
  take the mouse can be picked, and it won't start in combat.

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

### Releasing

Bump `## Version:` in `WowApiLib/WowApiLib.toc`, commit it and get it onto
`main` on GitHub (push, or merge its pull request and `git pull`). Then, from the
repo root with nothing uncommitted:

```
python release.py                   # dry run: prints the tag and release it would create
python release.py --create          # tag v<version>, push it, create the GitHub release
python release.py --create --type beta    # v<version>-beta, marked as a pre-release
```

Publishing the release starts the GitHub Actions workflow in
`.github/workflows/release.yml`, which zips the `WowApiLib/` folder alone (no
tests, tools or docs) and attaches it to the release as
`WowApiLib-v<version>.zip`. The tag goes on whatever commit is checked out, and
the version comes from the `.toc` on disk, which is why the bump has to be
committed and on `main` first. `release.py` is shared verbatim with the other
addon repos, like `deploy.py`.
