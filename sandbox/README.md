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

Keys work like Vim's. What's supported so far:

| | |
|---|---|
| Move | `h j k l` / arrows, `w b e W B E`, `0 ^ $`, `gg G` (`5G` = line 5), `f t F T` + char, `; ,`, Ctrl-D / Ctrl-U, Enter / `+` |
| Counts | before anything: `3j`, `2dw`, `d3w`, `5x`, `3.` |
| Operators | `d` delete, `y` yank, `c` change, `>` `<` indent: + a motion (`dw`, `y$`, `c2w`, `d/foo`), doubled for lines (`dd yy cc >> <<`) |
| Shortcuts | `x X s S D C Y`, `J` join, `r` + char replace, `p P` paste, `.` repeat, `u` undo, Ctrl-R redo |
| Visual | `v` characters, `V` lines, Ctrl-V block; move to select; `o` (`O` in a block) other end; `y d x c > < J p`; block `I` / `A` |
| Insert | `i a I A o O`; type, Enter, Backspace, Delete, Tab, arrows; Esc |
| Search | `/text` and `?text` (plain text, not regex), `n N` |
| Commands | `:w`, `:w name`, `:q`, `:q!`, `:wq`, `:x` |

Yanks also go to your system clipboard (OSC 52, works over SSH in terminals
that support it, like wezterm). Pasting from your terminal inserts the text
as-is in any mode. Indenting uses tabs.

If zvim crashes, or your terminal or SSH connection closes while there are
unsaved changes, they're saved next to the file as `name.zvim-recover` (or in
`/tmp` if that directory isn't writable). Opening the file again shows a
reminder while that file exists; delete it once you've recovered what you need.
To try it, build with `zig build -Dtest-crash=true`, where Ctrl-\ crashes on
purpose.

The status bar shows the file name, `[+]` for unsaved changes, the mode, the
terminal size, and the cursor position: `Ln` (line / total lines) and `Col`
(screen column).
