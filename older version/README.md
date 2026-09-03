# Older version

This folder holds **one** complete previous distribution, kept whole so you can choose between
the two workflows rather than having the choice made for you.

| | |
| --- | --- |
| **[`v3.4.1/`](v3.4.1/)** | The last release before the review chain was replaced. Complete: `phanes.md`, `PhanesUpgrade.md`, its own `README.md` and `Changelog.md`, and the full `templates/` script library. |

## Why this folder changed shape

It used to hold a flat list of bare prompt files going back to v1. It now holds a single complete
distribution instead, because v3.6.0 made a change worth being able to decline: it retired the
per-artifact review chain, the Critic pass on every diff, the two mandatory verdicts, the Reflect
loop and the six-to-ten persona roster, and replaced them with a fixed five-agent lineup and an
**escalation ladder** in which findings travel upward by severity. That is a deliberate reduction
in review coverage, traded for token economy. It is the right trade for most projects. It is not
obviously the right trade for every project, so the last version that works the other way is kept
in full rather than as a prompt file with no library behind it.

## Which one do you want?

**Take the current version (root of this repository)** if you want lower token cost per task, a
fixed roster whose always-on context does not grow with the project, and verification concentrated
at close time in independent re-derivation plus mandatory disclosure of every edit.

**Take v3.4.1** if you want every artifact reviewed before it is applied, and are willing to pay
several agent turns per step for it.

## Running v3.4.1

Install its prompt instead of the current one:

```bash
mkdir -p ~/.claude/commands
curl -L https://raw.githubusercontent.com/Aloim/phaneslight/main/older%20version/v3.4.1/phanes.md \
  -o ~/.claude/commands/phanes.md
```

Then run `/phanes`. Its install-time template fetch is pinned to the `v3.4.1` git tag, which is
still published, so it installs its own script library without needing this folder's copy; the copy
here is so you can read what it installs before you run it.

**Note:** v3.4.1 uses the pre-rename names throughout — `/phanes`, `.phanes/`, `phanes.md`. It is
frozen and receives no fixes. Running `/phaneslightupgrade` in a v3.4.1 project migrates it forward
to the current version whenever you decide you want it.
