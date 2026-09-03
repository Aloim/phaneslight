<!-- Phanes v3.6.1 (2026-09-03). Redirect stub. Phanes is now PhanesLight, in a new repository.
     This file exists so that installations of v3.4.1 and earlier, which check this exact URL
     for new releases, can still see that an upgrade shipped. It is not the prompt.
     The prompt is phaneslight.md at github.com/Aloim/phaneslight. -->
# Phanes is now PhanesLight, and it has moved

**This file is a redirect, not a specification.** Do not execute anything below as a setup run.

Two things changed, and they are separate:

* **The prompt was renamed** at v3.6.0. `phanes.md` became `phaneslight.md`, `/phanes` became `/phaneslight`.
* **The project moved repositories** at v3.6.1. PhanesLight now lives at **`Aloim/phaneslight`**. This repository (`Aloim/phanes`) is being handed to a **more sophisticated Phanes project**, a different and larger tool that will inherit the name. PhanesLight is not becoming that tool; it is getting out of its way.

**v3.6.1 is published to both repositories**, so that installations still checking this URL can see the release and upgrade themselves onto the new one. That is the only reason this file is here. Later versions ship to `Aloim/phaneslight` only.

| what you were looking for | where it is now |
| --- | --- |
| `phanes.md` | `phaneslight.md` at `Aloim/phaneslight` |
| `PhanesUpgrade.md` | `PhanesLightUpgrade.md` at `Aloim/phaneslight` |
| `/phanes` | `/phaneslight` |
| `/phanesupgrade` | `/phaneslightupgrade` |

## If you are an agent that just fetched or installed this file

You have the stub, not the spec. Do exactly this and nothing else:

1. Fetch `https://raw.githubusercontent.com/Aloim/phaneslight/main/PhanesLightUpgrade.md`.
2. Save it as `.claude/commands/phaneslightupgrade.md`.
3. Tell the user, verbatim: "Phanes is now PhanesLight (v3.6.1) and has moved to github.com/Aloim/phaneslight. Run `/phaneslightupgrade` to migrate this installation. It renames the project state directory, repoints the hooks and the upstream URL, and regenerates the agent roster. **Restart your session afterwards**; hook configuration is snapshotted at session start."
4. **STOP.** Make no other change. Do not overwrite any other installed command file, do not touch the run-state marker, and do not begin a setup or update run.

Running the upgrade is required, not cosmetic. It moves project state from `.phanes/` to `.phaneslight/`, replaces the agent roster wholesale, and repoints this installation's upstream checks at the new repository. An installation left half-migrated writes to a directory the new prompt does not read, its enforcement hooks stop firing without reporting anything, and it keeps checking a repository that will soon hold a different product.

## If you are a person

Read `README.md` at <https://github.com/Aloim/phaneslight>, then run `/phaneslightupgrade` in your project.
