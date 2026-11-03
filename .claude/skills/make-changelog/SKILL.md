---
name: make-changelog
description: Turn a commit's message into a changelog for the GitHub release page, written for people who use Majestic Media Player and leaving out project technicalities. Use when asked to make, write or translate a changelog, release notes or a release page text, e.g. "make a changelog of the last commit".
---

# Make a changelog

Translate a commit message into release notes that users would care to read. This is for the
GitHub release page, so it's written for people who use the player, not for its developers.

## 1. Gather the state

Always read the commit again; never reuse a message from the conversation. Unless told which one,
take the last commit:

```bash
git log -1 --format='%h %ad%n%B' --date=short && cat VERSION
```

If it was asked for a range of commits (for example since the last release), read them all and
merge their items.

If an item is too vague to explain to a user, read that part of the commit with `git show` rather
than guessing what it does. Don't describe anything the commit doesn't contain.

## 2. Write the changelog

Reply with one line naming the audience, then the changelog in one ```markdown code block, ready
to paste, in this shape:

```markdown
## Majestic v0.20.0

### Highlights

- **Instant frame stepping:** going back and forth frame by frame while paused now responds immediately.

### New

**Playlist**
- Move entries with Ctrl+Shift+Up/Down/Home/End, and duplicate them with Ctrl+D.

### Improved

- Dropped streams come back as soon as your network does.

### Fixed

- The end of audio files no longer gets cut off.
- Linux: dragged text no longer gets lost.
```

- **Title**: `Majestic` and the version in `VERSION`.
- **Highlights**: the few changes most users would upgrade for, each with a bold name. An item
  here can be summarized again in more detail under New, but only when New has more to say.
- **New**: features that didn't exist before, grouped under bold topics when there are enough to
  group. Leave a section out when it would be empty.
- **Improved**: things that already existed and now work better.
- **Fixed**: what was going wrong, told from the user's side. Say what no longer happens or what
  works now. Mark fixes that apply to one system with `Linux:` or `Windows:`, and put them last.
- Sort each list from major to minor.
- Write plainly for someone who uses the player and doesn't know how it's built. Say what they can
  now do or what got better, in "you" where it reads naturally. Items don't need to begin with a
  verb here.
- Name the menus, options and shortcuts people will actually touch.
- Leave out project technicalities: version bumps, docs, refactors, moved code, UI toolkit
  additions, automation or test commands, and internal names such as procs, files, formats and
  settings (`gapless-audio`, srv3, ASS).
- Merge items that mean the same thing to a user.
- Keep a technical name only when users need it, such as `.mkv` or a file name they'd create.
- Don't publish, tag or create the release. Only write the text.
