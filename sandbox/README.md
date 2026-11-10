# sandbox

A scratch area for trying zvim by hand.

    ./sandbox/run.sh

builds the editor and launches it with `sandbox/` as the working directory, so
anything zvim creates here stays out of the source tree. Pass a file to open it:

    ./sandbox/run.sh sample.txt

`sample.txt` exercises tabs, accents, wide characters, emoji, control
characters, a long line and 200 lines of scrolling. Drop throwaway files in
here freely; everything except this README, `run.sh` and `sample.txt` is
git-ignored.

Controls so far (a small subset of Vim's):

- Normal mode: `h` `j` `k` `l` / arrows move, `0` / `$` line start / end,
  `x` deletes a character
- Enter insert mode: `i` before the cursor, `a` after, `I` at the first
  non-blank, `A` at the line end, `o` / `O` on a new line below / above
- Insert mode: type, Enter, Backspace, Delete, Tab, arrows; Esc to leave
- Commands: `:w` save, `:w name` save as, `:q` quit (refused with unsaved
  changes), `:q!` quit anyway, `:wq` / `:x` save and quit

The status bar shows the file name, `[+]` for unsaved changes, the mode, the
terminal size, and the cursor position: `Ln` (line / total lines) and `Col`
(screen column).
