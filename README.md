# Fetcher

A screenshot tool for the Figma ↔ AI loop, for macOS.

Drag a box, type what's wrong, press return. The export carries both halves —
the marked-up image *and* a numbered instruction list the model can read.

Targets Cursor, Claude Code and Codex, which is why every capture is written to
disk as well as copied: the terminal-first tools want a path, not a paste.

## Build

Requires the Command Line Tools only — no Xcode.

```bash
./scripts/build-app.sh release
```

Produces `dist/Fetcher.app`. Open it once; it lives in the menu bar, with no
Dock icon and no window until you press the shortcut.

## Screen Recording permission

macOS grants this to a *signed bundle identity*, so a bare executable can never
hold it — always run the `.app`. The build script ad-hoc signs, whose designated
requirement includes the code hash, so **a rebuild can invalidate the grant** and
macOS will ask again. Signing with a Developer ID certificate makes it stick:

```bash
codesign --force --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  --identifier com.fetcher.Fetcher dist/Fetcher.app
```

If the grant goes stale the app says so specifically, rather than reporting that
no displays were found — which is what the API actually reports, and which sends
you to look at your monitors.

## Shortcuts

| Key | Where | Action |
| --- | --- | --- |
| `⌃⌘C` | global | Capture a region |
| `⌃⌘X` | global | Re-capture the last region, straight to the editor |
| `⏎` | crosshair | Take the outlined frame under the pointer |
| drag | editor | New box — next color, next number, caret armed |
| `⏎` | note field | Commit and arm the next box |
| `⇧⏎` | note field | Newline inside the note |
| `⇥` / `⇧⇥` | note field | Commit and edit the next / previous note |
| `⌥1`–`⌥0` | note field | Recolor while typing (plain digits are text) |
| `esc` | note field | Revert; on a never-noted box, delete it |
| `1`–`0` | canvas | Recolor the selection |
| `⇥` / `⇧⇥` | canvas | Cycle selection |
| `⏎` | canvas | Edit the selected box's note |
| `⌫` | canvas | Delete the selection, renumber the rest |
| arrows | canvas | Nudge 1px · `⌥` resize · `⇧` ×10 |
| `⌘Z` / `⇧⌘Z` | canvas | Undo / redo |
| `⌘C` / `⌘⏎` | canvas | Copy the result — works with nothing marked too |
| `⌥⌘C` | canvas | Copy the prompt text only |
| `⌘S` | canvas | Save and copy the file path |
| `esc` | canvas | Deselect, then cancel the capture |
| `⌘,` | menu bar | Settings |

A global hotkey outranks every app's own menu shortcut, so whatever is bound
here stops working inside other applications. Letters are where every app puts
its commands, so most are ruled out: `⌘C` and `⌘X` are untouchable, `⇧⌘C` is
Copy as PNG in Figma, `⌥⌘C` is Copy Properties, `⌃⌘F` is Enter Full Screen.
The control variants are the exception — nothing standard claims `⌃⌘C` or `⌃⌘X`,
and they sit next to each other for one-handed use.

While the crosshair is up, hovering a card or a Figma frame outlines it — click
or press `⏎` to take it, or drag as usual to ignore it. Hold `⌥` to turn
snapping off.

A capture smaller than the editor's working minimum is magnified — at 1:1 a
small region produced a window narrower than its own toolbar. The zoom is
display only: annotation rects stay in image pixels, so the export is identical
either way.

Committed notes stay visible on the canvas under their boxes, two lines at most
with the overflow truncated. Click a note — or click its box without dragging —
to reopen it; dragging still moves the box. The toolbar carries visible Undo and Discard buttons beside Copy — a
keyboard-first tool still has to show its keys. They are on the canvas because
that is a working surface — in the *export* they move to the legend, because a
sentence pasted over a design covers the thing being judged.

A capture nobody marks up is a plain screenshot: left untouched for 3 seconds it
copies itself and moves to the corner card. Any input cancels that.

The corner card offers Back-to-editing, Copy, Copy path, and drag-out, then puts
itself away after 10 seconds with a draining progress bar. Pointing at it stops
the countdown. Back-to-editing reopens the capture with its markup intact —
which is what makes an unmarked capture finishing itself on its own safe to do.
Putting the card away discards nothing: the PNG was written to disk the moment
it was made. Both timings are in Settings, and either can be turned off.

## More than one display

Every display gets its own overlay, and the pointer decides which one you are
capturing — including for the keyboard, which follows the pointer across
screens. A selection spanning two displays is not supported.

## The export

The capture is inset on a ground with a shadow under it — grey in light mode, a
soft light halo in dark, since a shadow on a dark ground is invisible — and the
notes sit on that ground below it. The capture reads as an object rather than
running to the edges of the file.

This replaced a rule drawn between the capture and its notes. The rule was
asserting a separation the layout did not have; lifting the capture off the
ground gives it that separation for real, so the rule is gone.

Turn it off under Export for pixel-exact screenshots.

## Icons

SF Symbols, not a downloaded pack. The system set matches the weight of the text
beside it, follows the accent color, re-renders for dark mode and every scale
factor, and adds no files to keep in step. An icon pack does none of that.

## Settings

`⌘,` from the menu bar. Shortcuts, frame snapping, legend on/off and position,
the inset, 1× export, save folder, the ten colors, the prompt template, launch
at login.

Two things are deliberately *not* configurable, because they are what makes the
output trustworthy rather than matters of taste: the order colors are handed out
in, and the numbering that ties each badge to its line of text.

Colors have two names. The palette grid shows the designed one — Rose,
Eucalyptus — and the prompt uses a name derived from the color itself. A stored
name would survive a recolor and then lie to the model: set slot one to blue and
every prompt would still call it rose. When two slots land in the same hue
family, the prompt drops the color word for both rather than saying "(blue)"
twice; the numbers carry it.

## Testing

```bash
swift build
./.build/debug/Fetcher --selftest      # 88 unit checks
./.build/debug/Fetcher --e2e           # 54 end-to-end checks
./.build/debug/Fetcher --editor-demo   # writes UI state PNGs to dist/
```

`--selftest` runs in two tiers. The model, prompt and compositor checks need no
permission and no display. The capture checks need Screen Recording, which only
a person can grant — a missing permission blocks that leg, not the suite.

The compositor assertions sample pixels rather than only checking dimensions:
the export was once rendered vertically mirrored with upside-down text while
every dimension check still passed. Orientation has since been wrong in three
separate places, each silent, so every surface that draws a picture now asserts
its orientation from sampled pixels.

`--e2e` drives the real event handlers with synthetic `NSEvent`s, in-process:
drag out a box, confirm the caret landed in the note field with no extra input,
type, return, drag again, ⌘C, then check the clipboard and the file on disk.
Also tab/digit/arrow/delete/⌘Z editing, both meanings of escape, ⌥⌘C, dragging a
region, clicking an outlined frame, and routing across two displays. No
Accessibility grant and no window server automation — the events go straight to
the views, so every real handler, responder and animation is on the path.

What it cannot cover, and still needs a person: the Screen Recording grant
dialog, whether a drag actually lands in Figma or Cursor, and whether the loop
*feels* fast.

`--editor-demo` drives the editor and the shelf into each interactive state and
writes their content views to `dist/`, so the states stay reviewable on a machine
with nobody sitting at it. It also asserts the shelf thumbnail's orientation
from pixels.

Frame detection is verified against the synthetic fixture, whose three cards sit
at known coordinates: it must snap within 8px, distinguish neighbouring cards,
return nothing over empty background, and keep working on a large dark display —
the downsample cell is capped, because a cell derived from image width averages
thin borders away on a 5K screen and silently stops detecting anything.

## Layout

```
Sources/Fetcher/
  Capture/       ScreenCaptureKit freeze, region overlay, frame detection
  Model/         Annotation, MarkupDocument (snapshot undo), Palette
  Editor/        Canvas state machine, note field, toolbar, shelf, motion
  Output/        Compositor (pure), prompt template, clipboard and disk
  Settings/      Preferences, hotkey recorder, launch at login
```

The compositor is a pure function of (image, annotations, options). The editor
canvas calls into the *same* drawing code with a scaled CTM, so the editor is a
preview of the export by construction rather than a lookalike that has to be
kept in sync.
