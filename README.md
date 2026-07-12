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
$ git diffedit -- src/            # limited to a pathspec
```

HEAD and the index are never touched, and every apply is strict: the edited
patch is replayed against pre-change copies of the files in a temp dir and
only the difference lands in your tree, so a failed apply writes nothing
(and reopens the editor), and files whose hunks you did not touch are never
rewritten.

## Install

Put [`git-diffedit`](./git-diffedit) somewhere on your `$PATH` and make it executable:

```sh
cp git-diffedit /usr/local/bin/
chmod +x /usr/local/bin/git-diffedit
```

## Usage

```
git diffedit [options] [--] [<pathspec>...]

options
  -U, --unified N  context lines around each change (default 3, minimum 1);
                   the context anchors the strict apply, more is safer
  -q, --quiet      suppress the report
```

In the editor: edit or add `+` lines freely; delete a `+` line to drop that
addition. Turn a `-` into a `' '` to keep that line after all, or a `' '`
into `-` to also delete it; never delete or reword `-`/`' '` lines otherwise
(they must keep matching the pre-change file). Deleting a whole hunk or file
section *reverts* that change from your working tree. Lines starting with
`#` are ignored. An empty buffer, or quitting without saving, aborts.

Nothing is more than one command from recovery: the pre-edit diff is saved
to `.git/DIFFEDIT_ORIG.diff` and the applied delta to
`.git/DIFFEDIT_UNDO.diff` (`git apply -R` it to undo).

## Examples

```sh
# rename the variable you have been typing all morning, everywhere
git diffedit          # in vim:  :g/^+/s/\<tmout\>/connect_timeout/g  then :wq

# touch up only what you changed under src/
git diffedit -- src/

# review what landed, or take it back
git diff
git apply -R .git/DIFFEDIT_UNDO.diff
```

## Caveats

- The buffer is the *unstaged* diff (working tree vs index): staged changes
  do not show up, so `git diffedit` right after `git add -u` has nothing to
  edit.
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
