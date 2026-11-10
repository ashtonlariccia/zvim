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

Current controls (viewing only, no editing yet):

- `j` / `k` scroll down / up
- `h` / `l` scroll left / right (long lines)
- `q` quit
- resize the window to watch the view redraw

The status bar shows the file name, the terminal size, `Ln` (first visible
line / total lines) and `Col` (first visible column).
