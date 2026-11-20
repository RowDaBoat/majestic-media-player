---
name: summarize-changes
description: Summarize all uncommitted (unstaged) changes in the working tree, skipping the .claude directory. Use when asked to summarize, review or describe the current unstaged changes / diff / working tree, e.g. "summarize all unstaged changes", "what changed?", "what about now?" after a previous summary.
---

# Summarize unstaged changes

Always re-read the repository state; never reuse an earlier summary from the conversation,
since the working tree may have changed (or been committed) since.

## 1. Gather the state

Run in one call:

```bash
git status --short && git log --oneline -3 && git diff --stat -- . ':!.claude'
```

- If changes summarized earlier in the conversation now appear in a commit, say so in one line
  (give the commit hash).
- Untracked files outside `.claude/` count as changes: read them and include them.
- If nothing is unstaged but changes are staged (`git status` shows them in the first column),
  summarize the staged ones instead: use `git diff --cached` below, and say so in one line.

## 2. Read the full diff

```bash
git diff -- . ':!.claude'
```

If the output is too large and gets persisted to a file, Read that file in full. Don't
summarize from the preview alone.

## 3. Write the summary

Write it as text worth of a commit, in one code block, with exactly these three lists in this
order. No title line goes above a list: each one ends with its `=== End of ... ===` line, followed
by a blank line between lists:

```
Make frame stepping instant.
Bump the version to 0.20.0.
=== End of Changes ===

Add YouTube seek bar previews, with a toggle in the seek bar's menu.
Add Ctrl+D to duplicate playlist entries.
=== End of New ===

Fix the end of audio files being cut off.
Stop listed YouTube playlists from adding their videos again after a restart.
=== End of Fixes ===
```

- Keep all three end lines, even for a list with no items.
- **Changes**: existing behavior that now works differently, plus refactors, docs and the version.
- **New**: features, options, shortcuts and tools that didn't exist before.
- **Fixes**: anything that was broken and now isn't, whichever verb describes it best.
- Sort each list from major to minor: what users will notice most goes first; internals, docs and
  the version go last.
- One line per item, ending in a period, **at most 80 characters**. Count them; a line that
  wraps is too long.
- Say what changed for the user, not how: leave out mechanisms, lists of edge cases, examples
  and parenthesized details. "Add a file list to the Run window: drag to reorder, add, drop,
  sort and remove." is right; a line listing every button, key and default is not.
- When a feature still doesn't fit in one short line, split it into a few short items, each a
  distinct thing users can do or notice (a second command, a feature's starting state, an
  option elsewhere), none repeating another. Splitting this way doesn't break the
  no-redundancy rules below; describing the same thing twice still does.
- Every item must begin with a verb in the imperative: Fix, Add, Make, Show, Separate, Clarify...
- Describe user-visible behavior (menus, shortcuts, buttons, OSD messages, saved files) in plain
  terms. Name a proc, file or setting only when there is no better way to say it.
- Split unrelated changes into separate items, and leave out steps of a single change.
- Don't list patch/diff noise (whitespace, reordering) unless that's all there is.
- Don't include `.claude/` in the summary.
- After the code block, write only real problems: something that would be wrong to commit as it
  is, such as leftover debug code, untracked personal notes, conflict markers, or a file the change
  needs that isn't in it. Give each one in a sentence that says what's wrong and what to do about
  it. When there is none, write the single line "Nothing to flag." Leave these out of the list
  itself.
- Write nothing else after the code block: no heading over the flags, no facts that need no
  action (what's staged, what a later step brings in, how Git records authors), and no notes on
  why a list is empty. Information next to a flag reads as a warning and gets mistaken for one.

### No redundancy, one kind per item

These two rules are strict. Check them before every summary, including a revised one.

1. **Every item is one unique action, listed once, in exactly one list.** Never describe the same
   action twice, in the same list or across lists:
   - not as a "Make ..." in Changes and again as its "Fix ..." in Fixes;
   - not as several items for its parts, its result or its mechanism: a bug and what fixes it are
     one item, and so are a feature and its edge cases;
   - not as separate items for something done only to support another change. For example, a
     dialog made to grow to fit its text so a reworded message can have bullet points belongs in
     the rewording's item;
   - not as separate items for pieces added together to the same spot. For example, a
     percentage and a time-left estimate added beside the same progress bar are one item.
2. **Every item is exactly one kind: a change, something new or a fix, never two at once.** An
   item can't be part change and part new feature, or a fix that also adds something. If an action
   has aspects of more than one kind, decide which kind it mainly is, describe it only as that, and
   leave the other aspect out, or mention it only as a detail of that item. If the aspects really
   are separate actions, split them into separate items, one in each list, that don't overlap.

Before writing the code block, go through every pair of items. If two describe the same action, or
one is part of, a support for, or a result of the other, merge them or drop the lesser. Then check
each item on its own: if it mixes kinds, settle it on one kind as above.
