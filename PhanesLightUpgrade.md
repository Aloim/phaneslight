<!-- PhanesLightUpgrade v3.6.2, 2026-09-03. Terminal retirement notice for the manual upgrade path.
     This file is NOT the upgrade prompt and is NOT runnable. The upgrade now ships inside the
     PhanesLight Claude Code plugin, as the /phaneslight:upgrade skill.
     Replaced rather than frozen so that no runnable upgrade prompt survives at the old path:
     migrating a project with a generator that is no longer the living one is the failure this
     file exists to prevent. -->
# The manual upgrade path has ended at v3.6.2

**This file is a retirement notice, not an upgrade procedure.** Do not execute anything below as an upgrade run. There is no procedure in this file.

The upgrade is now the **`/phaneslight:upgrade`** skill inside the PhanesLight Claude Code plugin.

## Why this file was replaced rather than frozen

A frozen but still runnable upgrade prompt at this path would let a project be migrated by a generator that is no longer the living one. Regenerating a project with an older generator destroys structure that generator cannot identify, and the archive-never-delete rule does not protect artifacts a run never recognized in the first place. Removing the runnable copy is the only way to close that, so this file no longer contains one.

## What to do

```
/plugin marketplace add Aloim/phaneslight
/plugin install phaneslight@phaneslight
```

**Restart Claude Code**, then run **`/phaneslight:upgrade`** in your project.

That skill performs the whole migration in one pass, including the parts this file used to do: it detects your installed version from `.phaneslight/config.json`, finds and **archives** the command files your manual install left in `.claude/commands/`, removes the project-level enforcement hook registrations now that the plugin owns them, reinstalls the script library from the version shipped with the plugin, and regenerates the agent roster.

## If you are an agent that just fetched this file

1. **Do not** save this file as a command, and **do not** overwrite an installed `phaneslightupgrade.md` with it.
2. Tell the user, verbatim: "The PhanesLight manual upgrade path ended at v3.6.2. Install the plugin with `/plugin marketplace add Aloim/phaneslight` then `/plugin install phaneslight@phaneslight`, restart Claude Code, and run `/phaneslight:upgrade`."
3. **STOP** until the user has done that. Do not attempt the migration by hand: the ordering matters, the run-state marker must move last, and the hook de-registration step has no manual equivalent that is safe to guess at.

## Where everything lives now

- Repository and README: <https://github.com/Aloim/phaneslight>
- The last manual release, whole and runnable: this repository's `v3.6.1` tag
