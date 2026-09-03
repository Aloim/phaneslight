<!-- PhanesLight v3.6.2 (2026-09-03). Terminal retirement notice for the manual install path.
     This file is NOT the prompt and is NOT runnable. The prompt now ships inside the
     PhanesLight Claude Code plugin, as the /phaneslight:run skill.
     This file exists so that manual installations, which poll this exact URL for a version
     change, see one final change and learn where the product went. It will not change again. -->
# The manual install path has ended at v3.6.2

**This file is a retirement notice, not a specification.** Do not execute anything below as a setup or update run. There is no prompt in this file.

PhanesLight is now distributed as a **Claude Code plugin**. The prompt you are looking for is the `/phaneslight:run` skill inside it, and that is the only runnable copy that still exists.

## Why this file stopped being the prompt

Fetching `phaneslight.md` into `.claude/commands/` was the install path up to v3.6.1. It is closed.

Freezing this file in place would have been silent: manual installs discover new versions by polling this URL for a changed version stamp, so a file that never changes again is a file that never tells anyone anything. Replacing it with this notice is the last thing the old mechanism can usefully do, and it is why the stamp above reads v3.6.2 rather than staying at v3.6.1.

Leaving the full prompt here would also have left two runnable copies in one repository, one frozen and one live, drifting apart. After v3.6.2 the repository holds exactly one runnable copy of the prompt, inside the plugin.

## If you are a person

```
/plugin marketplace add Aloim/phaneslight
/plugin install phaneslight@phaneslight
```

Then **restart Claude Code**. Plugin hooks load at session start, so the enforcement hooks arm on the next session rather than the current one.

Then run **`/phaneslight:upgrade`** in your project. Do this before `/phaneslight:run`. The upgrade is what finds the command files your manual install left in `.claude/commands/`, reports them with their versions, and **archives** them, so you are not left holding two live entry points at two different versions with no way to tell which one just ran.

After the upgrade, `/phaneslight:run` is the normal entry point.

| what you were looking for | where it is now |
| --- | --- |
| `phaneslight.md`, fetched into `.claude/commands/` | the `/phaneslight:run` skill, inside the plugin |
| `PhanesLightUpgrade.md` | the `/phaneslight:upgrade` skill, inside the plugin |
| `/phaneslight` | `/phaneslight:run` |
| `/phaneslightupgrade` | `/phaneslight:upgrade` |

## If you are an agent that just fetched or installed this file

You have a retirement notice, not the spec. **You cannot complete this migration yourself**, because installing a plugin is a user action. Do exactly this and nothing else:

1. **Do not** save this file as a command, and **do not** overwrite any installed command file with it. If you already saved it over an installed command, say so plainly; the previous file is recoverable from this repository's `v3.6.1` tag.
2. Tell the user, verbatim: "The PhanesLight manual install path ended at v3.6.2. PhanesLight is now a Claude Code plugin. Install it with `/plugin marketplace add Aloim/phaneslight` then `/plugin install phaneslight@phaneslight`, restart Claude Code, and run `/phaneslight:upgrade` to retire this manual installation. Your current installation keeps working until you do."
3. **STOP.** Make no other change. Do not touch the run-state marker, do not modify `.phaneslight/`, and do not begin a setup or update run.

Your existing installation is not broken by this notice and nothing about it changes today. It simply stops receiving new versions on this path.

## A known limitation, stated plainly

If you already have a v3.6.1 `/phaneslightupgrade` command installed locally, running it will migrate you to v3.6.1 structure and then find this notice again on its next check. It cannot install a plugin on your behalf. The plugin install above is the step that actually ends the loop, and it has to be you who runs it.

## Where everything lives now

- Repository and README: <https://github.com/Aloim/phaneslight>
- The last manual release, whole and runnable: this repository's `v3.6.1` tag
