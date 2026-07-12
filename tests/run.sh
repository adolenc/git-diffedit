#!/bin/bash
# git-diffedit test suite. Hermetic: throwaway repos under $TMPDIR, no user
# git config, editors faked via GIT_EDITOR scripts. Run: tests/run.sh
set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
TOOL=$TESTS_DIR/../git-diffedit
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset EDITOR VISUAL GIT_EDITOR

WORK=$(mktemp -d "${TMPDIR:-/tmp}/diffedit-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

N=0; FAILED=0
ok()   { N=$((N+1)); printf 'ok %d - %s\n' "$N" "$1"; }
bad()  { N=$((N+1)); FAILED=$((FAILED+1)); printf 'FAIL %d - %s\n' "$N" "$1"; }
is()   { # is <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
line() { sed -n "$2p" "$1"; }
sedi() { # in-place sed, portably (BSD sed's -i wants a suffix argument)
	local e=$1 f; shift
	for f in "$@"; do sed "$e" "$f" > "$f.sedi" && mv "$f.sedi" "$f"; done
}
ins() { # ins before|after <exact line> <text, \n for multi-line> <file>...
	local m=$1 p=$2 t=$3 f; shift 3  # awk -v expands the \n escapes
	for f in "$@"; do
		awk -v m="$m" -v p="$p" -v t="$t" \
			'$0 == p && m == "before" { print t } { print } $0 == p && m == "after" { print t }' \
			"$f" > "$f.ins" && mv "$f.ins" "$f"
	done
}

# --- fixtures ---------------------------------------------------------------

make_wip() { # $1: dir. base commit + unstaged "foo knobs" edits (2 files)
	git init -q "$1" && cd "$1" || exit 1
	cat > a.py <<-'EOF'
	import os
	import sys

	def main():
	    x = 1
	    print("hi")
	    return x
	EOF
	cp a.py b.py
	git add . && git commit -qm base
	ins after 'import sys' 'foo_timeout = 5' a.py b.py
	ins after '    x = 1' '    foo_retry = 3' a.py b.py
	cd - >/dev/null || exit 1
}

RENAME_ED() { # $1: path. editor that renames foo_ -> bar_ on '+' lines only
	cat > "$1" <<'EOF'
#!/bin/sh
sed -e '/^+/{/^+++ /!s/foo_/bar_/;}' "$1" > "$1.n" && mv "$1.n" "$1"
EOF
	chmod +x "$1"
}
RENAME_ED "$WORK/rename-ed"

# --- 1: rename the WIP identifier via the editor ------------------------------

make_wip "$WORK/t1"
before=$(git -C "$WORK/t1" status --porcelain | sort | tr -d '\n')
( cd "$WORK/t1" && GIT_EDITOR="$WORK/rename-ed" "$TOOL" -q )
is "rename: exit code" "$?" 0
is "rename: a.py timeout line" "$(line "$WORK/t1/a.py" 3)" "bar_timeout = 5"
is "rename: a.py retry line"   "$(line "$WORK/t1/a.py" 7)" "    bar_retry = 3"
is "rename: b.py timeout line" "$(line "$WORK/t1/b.py" 3)" "bar_timeout = 5"
is "rename: index untouched" "$(git -C "$WORK/t1" status --porcelain | sort | tr -d '\n')" "$before"

# --- 2: quitting without saving aborts, tree untouched -------------------------

make_wip "$WORK/t2"
before=$(git -C "$WORK/t2" diff)
printf '#!/bin/sh\nexit 0\n' > "$WORK/ed2"; chmod +x "$WORK/ed2"
err=$( cd "$WORK/t2" && GIT_EDITOR="$WORK/ed2" "$TOOL" -q 2>&1 )
is "unsaved: exit code" "$?" 1
case "$err" in *"not saved"*) ok "unsaved: explained" ;; *) bad "unsaved: explained ($err)" ;; esac
is "unsaved: tree untouched" "$(git -C "$WORK/t2" diff)" "$before"

# --- 3: saving the buffer unchanged is a no-op ---------------------------------

make_wip "$WORK/t3"
before=$(git -C "$WORK/t3" diff)
printf '#!/bin/sh\ntouch "$1"\n' > "$WORK/ed3"; chmod +x "$WORK/ed3"
out=$( cd "$WORK/t3" && GIT_EDITOR="$WORK/ed3" "$TOOL" 2>&1 )
is "unchanged: exit code" "$?" 0
case "$out" in *"not changed"*) ok "unchanged: explained" ;; *) bad "unchanged: explained ($out)" ;; esac
is "unchanged: tree untouched" "$(git -C "$WORK/t3" diff)" "$before"

# --- 4: deleting a hunk reverts that change; undo patch restores it ------------

git init -q "$WORK/t4" && ( cd "$WORK/t4" \
	&& printf 'm1\nm2\nm3\nm4\nm5\nm6\nm7\nm8\nm9\nm10\nm11\nm12\nm13\nm14\nm15\nm16\nm17\nm18\nm19\nm20\n' > g.txt \
	&& git add . && git commit -qm base \
	&& ins after 'm4' 'foo_a = 1' g.txt \
	&& ins after 'm12' 'foo_b = 1' g.txt )
before=$(git -C "$WORK/t4" diff)
printf '#!/bin/sh\nawk %s/^@@ /{n++} n<2%s "$1" > "$1.n" && mv "$1.n" "$1"\n' "'" "'" > "$WORK/ed4"
chmod +x "$WORK/ed4"
( cd "$WORK/t4" && GIT_EDITOR="$WORK/ed4" "$TOOL" -q )
is "drop hunk: exit code" "$?" 0
is "drop hunk: first insert kept" "$(line "$WORK/t4/g.txt" 5)" "foo_a = 1"
is "drop hunk: second insert reverted" "$(grep -c foo_b "$WORK/t4/g.txt")" 0
grep -q '+foo_b = 1' "$WORK/t4/.git/DIFFEDIT_ORIG.diff" \
	&& ok "drop hunk: reverted hunk kept in ORIG" || bad "drop hunk: reverted hunk kept in ORIG"
( cd "$WORK/t4" && git apply -R .git/DIFFEDIT_UNDO.diff )
is "drop hunk: undo restores the pre-edit diff" "$(git -C "$WORK/t4" diff)" "$before"

# --- 5: editor deletes a '+' line; later hunk must still land exactly ----------

git init -q "$WORK/t5" && ( cd "$WORK/t5" \
	&& printf 'import os\nimport sys\n\ndef main():\n    x = 1\n    print("hi")\n    return x\n' > a.py \
	&& git add . && git commit -qm base \
	&& ins before 'def main():' 'def foo_setup():\n    fa = 1\n    fb = 2\n    return fa + fb\n' a.py \
	&& ins after '    x = 1' '    foo_retry = 3' a.py )
cat > "$WORK/ed5" <<'EOF'
#!/bin/sh
sed -e '/^+    fb = 2$/d' -e '/^+/{/^+++ /!s/foo_/bar_/;}' "$1" > "$1.n" && mv "$1.n" "$1"
EOF
chmod +x "$WORK/ed5"
( cd "$WORK/t5" && GIT_EDITOR="$WORK/ed5" "$TOOL" -q )
is "recount: exit code" "$?" 0
is "recount: shortened block" "$(sed -n '4,6p' "$WORK/t5/a.py" | tr '\n' '|')" \
	"def bar_setup():|    fa = 1|    return fa + fb|"
is "recount: later hunk not shifted" "$(line "$WORK/t5/a.py" 10)" "    bar_retry = 3"

# --- 6: turning '-' into ' ' keeps the line (un-deletes) ------------------------

make_wip "$WORK/t6"
( cd "$WORK/t6" \
	&& git checkout -q -- b.py \
	&& git checkout -q -- a.py && sedi '/^    print("hi")$/d' a.py \
	&& ins after 'import sys' 'foo_x = 1' b.py )
cat > "$WORK/ed6" <<'EOF'
#!/bin/sh
sed 's/^-    print("hi")$/     print("hi")/' "$1" > "$1.n" && mv "$1.n" "$1"
EOF
chmod +x "$WORK/ed6"
( cd "$WORK/t6" && GIT_EDITOR="$WORK/ed6" "$TOOL" -q )
is "undelete: exit code" "$?" 0
is "undelete: line is back" "$(line "$WORK/t6/a.py" 6)" '    print("hi")'
is "undelete: only b.py still dirty" "$(git -C "$WORK/t6" diff --name-only | tr -d '\n')" "b.py"
is "undelete: b.py WIP intact" "$(line "$WORK/t6/b.py" 3)" "foo_x = 1"

# --- 7: mangled context -> apply fails atomically -> retry -> abort ------------

make_wip "$WORK/t7"
before=$(git -C "$WORK/t7" diff)
cat > "$WORK/ed7" <<'EOF'
#!/bin/sh
if grep -q 'APPLY FAILED' "$1"; then : > "$1"; else sed 's/^ import os/ import oops/' "$1" > "$1.n" && mv "$1.n" "$1"; fi
EOF
chmod +x "$WORK/ed7"
( cd "$WORK/t7" && GIT_EDITOR="$WORK/ed7" "$TOOL" -q 2>/dev/null )
is "mangle: aborted via retry loop" "$?" 1
is "mangle: nothing written" "$(git -C "$WORK/t7" diff)" "$before"

# --- 8: empty buffer aborts instead of reverting everything --------------------

make_wip "$WORK/t8"
before=$(git -C "$WORK/t8" diff)
printf '#!/bin/sh\n: > "$1"\n' > "$WORK/ed8"; chmod +x "$WORK/ed8"
err=$( cd "$WORK/t8" && GIT_EDITOR="$WORK/ed8" "$TOOL" -q 2>&1 )
is "empty: exit code" "$?" 1
case "$err" in *"refusing to revert"*) ok "empty: explained" ;; *) bad "empty: explained ($err)" ;; esac
is "empty: tree untouched" "$(git -C "$WORK/t8" diff)" "$before"

# --- 9: binary changes stay untouched, text still edits ------------------------

make_wip "$WORK/t9"
( cd "$WORK/t9" \
	&& printf '\000\001\002' > blob.bin && git add blob.bin && git commit -qm bin \
	&& printf '\000\007' > blob.bin )
cat > "$WORK/ed9" <<EOF
#!/bin/sh
cp "\$1" "$WORK/t9.buffer"
sed -e '/^+/{/^+++ /!s/foo_/bar_/;}' "\$1" > "\$1.n" && mv "\$1.n" "\$1"
EOF
chmod +x "$WORK/ed9"
( cd "$WORK/t9" && GIT_EDITOR="$WORK/ed9" "$TOOL" -q 2>/dev/null )
is "binary: exit code" "$?" 0
grep -q 'left untouched (binary file)' "$WORK/t9.buffer" \
	&& ok "binary: note present" || bad "binary: note present"
is "binary: text edit applied" "$(line "$WORK/t9/a.py" 3)" "bar_timeout = 5"
is "binary: binary WIP still there" \
	"$(git -C "$WORK/t9" status --porcelain | sort | tr -d '\n')" " M a.py M b.py M blob.bin"

# --- 10: deleted file: kept when its section stays, restored when dropped ------

make_wip "$WORK/t10"
( cd "$WORK/t10" && git checkout -q -- b.py && rm b.py )
( cd "$WORK/t10" && GIT_EDITOR="$WORK/rename-ed" "$TOOL" -q )
is "deleted kept: exit code" "$?" 0
[ ! -e "$WORK/t10/b.py" ] && ok "deleted kept: file still gone" || bad "deleted kept: file still gone"
is "deleted kept: a.py edited" "$(line "$WORK/t10/a.py" 3)" "bar_timeout = 5"

make_wip "$WORK/t10b"
( cd "$WORK/t10b" && git checkout -q -- b.py && rm b.py )
cat > "$WORK/ed10b" <<'EOF'
#!/bin/sh
sed -e '/^diff --git a\/b\.py /,$d' -e '/^+/{/^+++ /!s/foo_/bar_/;}' "$1" > "$1.n" && mv "$1.n" "$1"
EOF
chmod +x "$WORK/ed10b"
( cd "$WORK/t10b" && GIT_EDITOR="$WORK/ed10b" "$TOOL" -q )
is "deleted dropped: exit code" "$?" 0
[ -f "$WORK/t10b/b.py" ] && ok "deleted dropped: file restored" || bad "deleted dropped: file restored"
is "deleted dropped: only a.py dirty" "$(git -C "$WORK/t10b" diff --name-only | tr -d '\n')" "a.py"

# --- 11: intent-to-add file is editable -----------------------------------------

make_wip "$WORK/t11"
( cd "$WORK/t11" && git add -u && printf 'foo_new = 1\n' > n.py && git add -N n.py )
( cd "$WORK/t11" && GIT_EDITOR="$WORK/rename-ed" "$TOOL" -q )
is "intent-to-add: exit code" "$?" 0
is "intent-to-add: content edited" "$(line "$WORK/t11/n.py" 1)" "bar_new = 1"

# --- 12: pathspec limiting -------------------------------------------------------

make_wip "$WORK/t12"
( cd "$WORK/t12" && GIT_EDITOR="$WORK/rename-ed" "$TOOL" -q -- a.py )
is "pathspec: exit code" "$?" 0
is "pathspec: a.py edited" "$(line "$WORK/t12/a.py" 3)" "bar_timeout = 5"
is "pathspec: b.py untouched" "$(line "$WORK/t12/b.py" 3)" "foo_timeout = 5"

# --- 13: invoked from a subdirectory ---------------------------------------------

make_wip "$WORK/t13"
( cd "$WORK/t13" && mkdir -p sub && cd sub && GIT_EDITOR="$WORK/rename-ed" "$TOOL" -q )
is "subdir: exit code" "$?" 0
is "subdir: applied at toplevel" "$(line "$WORK/t13/a.py" 3)" "bar_timeout = 5"

# --- 14: no unstaged changes -> exit 1 -------------------------------------------

make_wip "$WORK/t14"
( cd "$WORK/t14" && git add -u )
err=$( cd "$WORK/t14" && "$TOOL" -q 2>&1 )
is "no unstaged: exit code" "$?" 1
case "$err" in *"no unstaged changes"*) ok "no unstaged: explained" ;; *) bad "no unstaged: explained ($err)" ;; esac

# --- 15: staged changes are never touched ----------------------------------------

make_wip "$WORK/t15"
( cd "$WORK/t15" && git add b.py )
( cd "$WORK/t15" && GIT_EDITOR="$WORK/rename-ed" "$TOOL" -q )
is "staged: exit code" "$?" 0
is "staged: a.py edited" "$(line "$WORK/t15/a.py" 3)" "bar_timeout = 5"
is "staged: b.py worktree untouched" "$(line "$WORK/t15/b.py" 3)" "foo_timeout = 5"
is "staged: b.py index untouched" "$(git -C "$WORK/t15" show :b.py | sed -n 3p)" "foo_timeout = 5"
is "staged: status" "$(git -C "$WORK/t15" status --porcelain | sort | tr -d '\n')" " M a.pyM  b.py"

# --- 16: file without trailing newline -------------------------------------------

git init -q "$WORK/t16" && ( cd "$WORK/t16" \
	&& printf 'import os\na = 1' > f.py && git add . && git commit -qm one \
	&& printf 'import os\nfoo_mid = 5\na = 1' > f.py )
( cd "$WORK/t16" && GIT_EDITOR="$WORK/rename-ed" "$TOOL" -q )
is "no-newline: exit code" "$?" 0
is "no-newline: placement" "$(line "$WORK/t16/f.py" 2)" "bar_mid = 5"
[ -n "$(tail -c1 "$WORK/t16/f.py")" ] \
	&& ok "no-newline: EOF still has no newline" || bad "no-newline: EOF still has no newline"

# --- 17: -U validation and -U1 end-to-end ----------------------------------------

make_wip "$WORK/t17"
err=$( cd "$WORK/t17" && "$TOOL" -q -U0 2>&1 )
is "unified: -U0 refused" "$?" 3
case "$err" in *"at least 1"*) ok "unified: -U0 explained" ;; *) bad "unified: -U0 explained ($err)" ;; esac
err=$( cd "$WORK/t17" && "$TOOL" -q --unified=lots 2>&1 )
is "unified: non-numeric refused" "$?" 3
( cd "$WORK/t17" && GIT_EDITOR="$WORK/rename-ed" "$TOOL" -q -U1 )
is "unified: -U1 exit code" "$?" 0
is "unified: -U1 placement" "$(line "$WORK/t17/a.py" 3)" "bar_timeout = 5"

# --- 18: installed as a git subcommand -------------------------------------------

# -h, not --help: git intercepts --help for external commands (man lookup)
out=$(PATH="$TESTS_DIR/..:$PATH" git diffedit -h 2>&1)
is "git diffedit -h: exit code" "$?" 0
case "$out" in *"usage: git diffedit"*) ok "git diffedit -h: usage shown" ;; *) bad "git diffedit -h: usage shown" ;; esac

# --- 19: editor exiting non-zero aborts ------------------------------------------

make_wip "$WORK/t19"
before=$(git -C "$WORK/t19" diff)
printf '#!/bin/sh\nexit 7\n' > "$WORK/ed19"; chmod +x "$WORK/ed19"
( cd "$WORK/t19" && GIT_EDITOR="$WORK/ed19" "$TOOL" -q 2>/dev/null )
is "editor fail: exit code" "$?" 2
is "editor fail: tree untouched" "$(git -C "$WORK/t19" diff)" "$before"

# --- 20: a vim-family editor is handed -c 'set modified' (pre-dirtying) ----------

make_wip "$WORK/t20"
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/nvim" <<'EOF'
#!/bin/sh
[ "$1" = "-c" ] && [ "$2" = "set modified" ] || exit 7
touch "$3"   # a dirtied buffer means :x/ZZ write even with no edits
EOF
chmod +x "$WORK/fakebin/nvim"
out=$( cd "$WORK/t20" && GIT_EDITOR="$WORK/fakebin/nvim" "$TOOL" 2>&1 )
is "vim dirty: exit code" "$?" 0
case "$out" in *"not changed"*) ok "vim dirty: unchanged save is a no-op" ;; *) bad "vim dirty: unchanged save is a no-op ($out)" ;; esac

# ------------------------------------------------------------------------------

printf '\n%d tests, %d failed\n' "$N" "$FAILED"
[ "$FAILED" -eq 0 ]
