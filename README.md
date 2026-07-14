# git-diffedit

Edit your unstaged diff in your editor; the saved buffer becomes your new
unstaged diff.

You are mid-change and realize the identifier you have been typing all
morning wants a different name. `git diffedit` opens your unstaged changes
(working tree vs index) as one patch -- rename it across every file you
touched with a single `:g/^+/s/old/new/g`, save, and the working tree is
rewritten so that `git diff` now shows exactly the saved patch. Quitting
without saving (`:q!`) aborts.

```
$ git diffedit                    # opens `git diff` in $EDITOR
$ git diffedit --staged           # opens `git diff --staged` instead
$ git diffedit -- src/            # limited to a pathspec
```

HEAD and the index are never touched, and every apply is strict: the edited
patch is replayed against pre-change copies of the files in a temp dir and
only the difference lands in your tree, so a failed apply writes nothing
(and reopens the editor), and files whose hunks you did not touch are never
rewritten.

`--staged` edits the staged diff (index vs HEAD) the same way: the saved
buffer becomes the new staged diff, and the edit lands in the working tree
too, so the files on disk keep matching what is staged and the unstaged
diff is preserved. If unstaged changes overlap the edited lines, the apply
refuses and writes nothing. Only HEAD is never touched then.

## Install

Put [`git-diffedit`](./git-diffedit) somewhere on your `$PATH` and make it executable:

```sh
cp git-diffedit /usr/local/bin/
chmod +x /usr/local/bin/git-diffedit
```

## Usage

```
git diffedit [options] [--] [<pathspec>...]
git diffedit undo [-q]

options
  --staged, --cached  edit the staged diff (index vs HEAD) instead
  -U, --unified N  context lines around each change (default 3, minimum 1);
                   the context anchors the strict apply, more is safer
  -q, --quiet      suppress the report
```

In the editor: edit or add `+` lines freely; delete a `+` line to drop that
addition. Turn a `-` into a `' '` to keep that line after all, or a `' '`
into `-` to also delete it; never delete or reword `-`/`' '` lines otherwise
(they must keep matching the pre-change file). Deleting a whole hunk or file
section *reverts* that change from your working tree (and the index with
`--staged`). Lines starting with `#` are ignored. An empty buffer, or
quitting without saving, aborts.

Nothing is more than one command from recovery: `git diffedit undo` takes
back the last landed edit (strictly -- it refuses if the tree was edited
since), restoring the index too after a `--staged` edit. The pre-edit diff
is also saved to `.git/DIFFEDIT_ORIG.diff` and the applied delta to
`.git/DIFFEDIT_UNDO.diff`.

## Examples

```sh
# rename the variable you have been typing all morning, everywhere
git diffedit          # in vim:  :g/^+/s/\<tmout\>/connect_timeout/g  then :wq

# same, but after you already ran `git add -u`
git diffedit --staged

# touch up only what you changed under src/
git diffedit -- src/

# review what landed, or take it back
git diff
git diffedit undo
```

## Caveats

- The default buffer is the *unstaged* diff (working tree vs index): staged
  changes do not show up, so `git diffedit` right after `git add -u` has
  nothing to edit -- use `git diffedit --staged` for those.
- Untracked files do not show up either; `git add -N <file>` makes one
  appear as an editable new-file section.
- Deleting a whole hunk or file section reverts it from the working tree --
  that is the point, but if it surprises you, the pre-edit diff is kept in
  `.git/DIFFEDIT_ORIG.diff`.
- Binary, submodule and symlink changes are left untouched (noted in the
  buffer).

## Tests

```bash
./tests/run.sh
```
