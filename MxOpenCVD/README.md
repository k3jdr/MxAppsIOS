# MxOpenCVD

A native macOS machine-vision app in SwiftUI and AVFoundation, on OpenCV, ONNX Runtime, PaddleOCR's models and Apple Vision.
Build a job from inspection tools, point a camera at the part, and get a pass or fail with the reasons.

It requires an Apple silicon Mac on macOS 26.6 or later. OpenCV's C++ API is called directly, through a thin
Objective-C++ bridge. OpenCvSharp isn't used, because it is OpenCV's wrapper for C# and this is a Swift app.

## Build

```bash
scripts/build-install.command
```

That builds the native libraries the first time (a few minutes), then builds a Release copy, installs it in
`/Applications` and opens it. To work in Xcode instead, run `scripts/bootstrap.sh` once and open `MxOpenCVD.xcodeproj`.
`Vendor/` is git-ignored; the OCR models in `Models/` are committed.

## Cameras

| Order | Camera | How it's recognized |
| --- | --- | --- |
| Primary | iPhone, through Continuity Camera | Continuity device type, or an iPhone model ID |
| Secondary | USB web camera | External device on USB |
| Third | MacBook's built-in camera | Built-in device type |
| Last resort | Virtual cameras and capture cards | Any other external device |

With **Auto** on, the app uses the highest-ranked camera available. It moves down the list when a camera disconnects,
suspends or sends no frames for 6 seconds, and returns when a better camera comes back. Clicking a camera pins it.

Each camera runs at its largest landscape format at video rate: 1920 × 1440 on the iPhone 11 Pro Max tested. Center
Stage is turned off and mirroring is disabled, since either would change measurements or make text unreadable.
Portrait mode and Studio Light can only be changed from the menu bar's Video item, so the app warns when they're on.

**Close-ups on the iPhone.** Continuity Camera gives apps no focus or exposure control on the phone tested, so the
phone decides focus by itself, and very close parts can stay blurred. Add an Image Quality tool and watch its
sharpness while you set up. If the part won't come into focus, move it farther away or pin **iPhone Desk View Camera**,
which sees the desk below the phone.

## Tools

| Tool | What it gives you |
| --- | --- |
| Image Quality | Sharpness, brightness, contrast and clipped pixels |
| Blob Analysis | Count, total area and the largest object's size, with automatic, fixed or adaptive threshold |
| Caliper | Edge positions to a fraction of a pixel, and the distance between the outer two |
| Contours | Outlines to a fraction of a pixel, open or closed, with holes; area, perimeter, circularity, corners and more; export to DXF, SVG or CSV |
| Shape Fit | A line, circle, ellipse or rectangle fitted to the edges in a region, ignoring those that don't agree, with its size and how far it departs from ideal |
| Pattern Match | Position, angle, size and score of a taught part at any angle, by surface features or by edges; it can find several at once |
| QR / Barcode | QR, Data Matrix, Code 128, EAN, UPC, PDF417, Aztec and the other codes Apple Vision reads, at any angle |
| OCR | Printed text in English, from PP-OCRv5 models on ONNX Runtime, turning upside-down lines over |
| ONNX Model | Your own classifier or YOLO-style detector (`[1, N, 4 + classes]`, or `5 +` with objectness) |

### Contours and Shape Fit

Both find outlines in the same way, in `MxOpenCVD/Engine/Contours.cpp`. **Threshold** methods give closed outlines and tell
holes from outer edges. **Edges** needs no threshold and also gives open outlines, such as a scratch or a shape running out
of view, but it can't tell a hole from an outer edge. Either way, each point then moves to where the edge really peaks,
since tracing whole pixels would make every outline about half a pixel too small.

**Export Contours…** on the Contours tool saves the outlines at full precision: DXF for CAD, SVG for drawing programs, CSV for
spreadsheets. They're in millimetres when the camera is calibrated, and pixels otherwise. In a DXF, y points up, as CAD
expects, and outlines are on the layers `OUTLINE`, `HOLE` and `OPEN`.

Measured on sharp synthetic shapes of known size with slight blur and noise, which is a best case:

| Measurement | Typical error |
| --- | --- |
| Area, shapes 60 px across or more | Under 0.1% |
| Area, a circle of radius 20 px | About 0.4%, since blur and smoothing shrink small shapes |
| Circle perimeter | About 0.02%, or 0.16% at a radius of 20 px |
| Square perimeter | A few pixels too long, from its corners, so about 2% on a 60 px square and 0.3% on a 500 px one |
| Circle diameter | About 0.1 px |
| Circle diameter from a partial arc | 0.05 px on a half circle, 0.2 px on 110°, 1.6 px on 60° |
| Rectangle and ellipse sizes | About 0.1 px |
| Line angle | Under 0.01° |

Things to know:

- **Draw the region around the feature.** Lines and circles use every edge in the region, and the shape with the most agreeing
  points wins, so a long straight edge can beat a short arc. Busy surfaces such as wood grain make a fit less steady. A low
  **share used** warns of this, so draw the region tighter, or raise **Min length** or **Edge contrast**.
- **A short arc is much less certain.** Live, a third of a rounded corner gave a diameter with a spread of 0.6–3 px, ranging
  over as much as 49 px on a blurrier camera. Check **arc coverage** before trusting a diameter from it.
- **These are camera pixels.** Lens distortion isn't corrected, so a straight edge near the corners of a wide view can read
  as curved, and a tilted view changes shapes: a circle becomes an ellipse. Size in millimetres holds only at the calibrated
  distance. See the note below on the iPhone's focus.

### Color tools

These four follow what Cognex publicly documents for its color tools, and use its tool names and terms so they're
recognizable. They're this project's own code, and aren't made by, endorsed by or compatible with Cognex. They haven't been
compared with Cognex's tools. The code is in `MxOpenCVD/Engine/ColorTools.cpp`.

| Tool | What it does | Result |
| --- | --- | --- |
| **Color Segmenter** | Each color is a range per plane in RGB or HSI, from the nominal value it was taught plus a low and high tolerance, with an optional softness band. Multiple colors combine by logical OR. | Matching pixels, their share of the region, and the areas they form |
| **Color Extractor** | Each color is a volume in RGB, taught from all the colors in a region, with dilation, softness, a softness threshold, matte lines and a highlight line. It suits colors that vary. | The same, plus the color with the most pixels |
| **Color Match** | Compares the region's average color with reference colors, by distance in RGB or HSI. It's quick, and suits even colors. | A score, the best reference, and how far ahead it is |
| **Composite Color Match** | Compares the region's mix of colors with reference samples. It tells apart patterns with the same average, such as a fine red-and-blue check and a flat purple. | The same |

HSI uses 0 to 255 on each plane: hue is the angle on the color wheel from red, saturation 0 is grey, and intensity is the mean of
R, G and B.

Where Cognex doesn't publish the details, these are this project's own choices, so values won't match Cognex's:

- **Scores:** Color Match uses 1 minus the normalized distance, and in HSI that's measured in the double cone Cognex describes.
  Composite uses the Bhattacharyya coefficient on a 16 × 16 × 16 RGB histogram.
- **HSI:** the standard formula. Cognex's equations are published as images, which couldn't be read.
- **Starting tolerances, softness grading, and how dilation and the matte and highlight lines shape the volume.**

Not included from Cognex's documents: color groups in the extractor, passing results to a separate Blob tool (these report
areas themselves), showing the grey result image (they draw outlines instead), polygon regions, and color pattern search.

**Ignore brightness** on the Segmenter (in HSI), Color Match and Composite is this project's addition, not Cognex's. It compares
color alone, so dimmer or brighter light doesn't matter, but it can't tell apart colors that differ only in brightness, such as
dark and light red, or white, grey and black. The Extractor's matte lines do a similar job, in the way Cognex describes.

#### Color and the camera

Color depends on the light and the camera much more than shape does. These are from one real iPhone frame of a card on a desk, with
colors taught from it, then the frame's brightness or color balance changed in software. That only approximates a real change in
the light. Pixels are counted as a check on stability, since no exact count is known.

| Change to the frame | Segmenter pixels | With Ignore brightness | Extractor pixels, small region | With matte lines 0.4 | Color Match, as taught | With Ignore brightness | Composite, as taught | With Ignore brightness |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| None | 427,229 | 527,196 | 230,529 | 527,209 | Right | Right | Right | Right |
| 70% brightness | 158,160 | 529,631 | 252 | 535,051 | **Wrong on wood** | Right | Right, score 0.09 | Right, score 0.95 |
| 130% brightness | 3,152 | 528,430 | 59 | 411,794 | Right | Right | Right, score 0.20 | Right, score 0.92 |
| 8% warmer | 125,565 | 172,486 | 7 | 2,728 | Right | Right | Right, score 0.48 | Right, score 0.66 |
| 8% cooler | 138,198 | 139,012 | 1,080 | 7,443 | Right | Right | Right, score 0.51 | Right, score 0.69 |
| 20% warmer | 0 | 9 | 0 | 0 | Right | Right | **Wrong on the label** | **Wrong on the label** |

Things to know:

- **Keep the light steady, or use Ignore brightness or matte lines.** Without them, a modest change in brightness can make these
  tools find nothing, or the wrong color.
- **A shift in color balance is the harder problem.** Nothing here corrects it. Comparing an average holds up far better than finding
  pixels by range, so prefer Color Match where it fits. Shield the part from changing daylight.
- **Your camera may not help.** On the cameras tested, none could lock white balance, and only the USB camera could lock exposure, so
  the camera can change a color reading by itself when something new fills the view. Use `--probe-cameras` to check yours.
- **Teach on the camera you'll inspect with.** The same wood on the iPhone's two lenses differed by up to 7 levels. Color Match still
  named it at 0.98, but Composite fell to 0.71. Failing over to another camera can break a color job, so try it first.
- **Teach from a generous region.** A small patch misses the color's natural variation: the Extractor found 230,529 pixels from a
  small patch of a label where wider settings find about 527,000, and a sheen left the Segmenter's outline jagged.
- **Too much tolerance takes in other colors.** Dilating the Extractor to cover that label also took in dark background.

Live on the same scene, with nothing changing, the red, green and blue averages held to under 0.2 levels out of 255 over 360 frames, and every tool picked
the right answer in every frame, with all eight tools taking about 17 ms in all.

### Pattern Match

Pattern Match has three kinds of **Search**:

| Search | For | How it works |
| --- | --- | --- |
| **Surface features** (the default) | Printed or textured parts, tilted or not, from about a third to four times the taught size | Matches ORB or SIFT features |
| **Edges** | Plain parts, such as machined or stamped ones, and changing light | Matches the outline's geometry |
| **Same angle and size** | Parts a fixture always holds the same way | Slides the pattern over the image |

### Surface features

This is a matcher of its own, in `MxOpenCVD/Engine/PatternMatch.cpp`:

1. It finds ORB or SIFT features on the part and in the image. ORB is the default: in testing it found as many parts or
   more at about half the time, and SIFT was better only at some steep tilts.
2. It keeps a candidate only if it's clearly better than the first neighbour that can't be real, which still works with
   several identical parts in view.
3. Candidates vote on the part's angle, size and center, which separates parts and leaves most false matches alone.
4. Each group of agreeing candidates gives a rigid pose, which grows into a perspective one, so it follows a tilted part.
5. The result is scored as the median across small cells of the pattern, so background in the taught region doesn't
   count against a part. Plain cells and cells beyond the edge of the image don't vote.

Tilt is the main thing this handles. A phone is rarely square to a part, and a rigid pose scored 0.01–0.42 at 45° where a
perspective pose scored 0.95–1.00. The four detailed parts tested held to 60°. A soft part with few features held only to
about 30°, and failed in some cluttered scenes.

A plain part has too few features to search that way, and the tool says so: set **Search** to **Edges**. At least 60% of
the taught region must be in view.

### Edges

This follows the same idea as geometric pattern matching tools such as Cognex PatMax, built from published methods. It
isn't their algorithm, and it hasn't been compared with them. The code is in `MxOpenCVD/Engine/EdgeMatch.cpp`:

1. Teaching extracts the part's edges and their directions, placed to a fraction of a pixel, at several resolutions.
2. The search tries every position, angle and size at the coarsest level, comparing edge directions rather than
   brightness, so dim, uneven or reversed lighting barely matters. It stops early at positions that can't reach the score.
3. The best candidates are sharpened level by level, then fitted to the image's real edges.
4. The result reports **fit**, **coverage** and **clutter** separately. The **score** counts only true edge crests in
   connected runs along the outline, since a busy image has plenty of edges that happen to lie near some points.

Measured on plain test parts at 1920 × 1440, at the default sizes and any angle:

| | Surface (ORB) | Edges |
| --- | --- | --- |
| Synthetic scenes found, of 52 (rotation, size, blur, noise, dim light, gradients, reversed contrast, hidden areas, clutter) | 35 | 50 |
| False finds with the part absent, of 48 | not measured here | 1 (a small, simple part in dense clutter) |
| Time | about 13 ms | about 55 ms, or about 110 ms in a busy scene with no part |
| Live, on a blurred USB receiver: frames found, of 217 | 0 | 217 |
| Live, on a card corner: position spread (standard deviation) | 0.71, 0.86 px | 0.15, 0.13 px |
| Live, on a card corner: angle spread | 0.17° | 0.008° |

The spread shows repeatability on a still scene, not accuracy against a known size, which hasn't been measured on real
parts. Synthetic images give about 0.01 px, but those are best-case images with perfectly sharp edges, so don't expect
that from a camera.

Things to know:

- **Set the ranges tightly.** A narrower **Angle range** and size range are much faster and leave less room for a false
  find. An exact size at ±15° takes about 18 ms.
- **It finds parts rather than checking them.** A missing hole only took the score from 1.00 to 0.93, and a mirror image of
  a nearly symmetrical part scored 0.69. Use limits on **clutter** and **coverage**, or other tools, to catch defects.
- **Teach a tight region.** Edges in the background become part of the pattern, unlike in the surface search.
- **Symmetrical parts** can report any of their matching angles, unless **Angle range** rules the others out.
- **It only follows a slight tilt**, tested to 10°. For more, use the surface search.
- **Dense text** can be missed: it found a printed label in 183 of 200 poses, so use the surface search for labels.

### Focus changes the iPhone's scale

On the iPhone's main camera, a part's measured size shifted by 1.9% between frames taken apart, and its position by about
15 px near the edge of the image, with nothing moving. That matches the magnification change autofocus can cause, and
Continuity Camera gives apps no way to lock focus on the phone tested. Don't rely on a calibrated scale from that camera
across a refocus. The Desk View camera stayed at 1.000× in the same test. Use `--repeat` to check your own setup.

Each tool can have a region of interest, limits on any measure, and for text a regular expression to match. A job
passes when every enabled tool does. Jobs are JSON files; the current one is autosaved in
`~/Library/Application Support/MxOpenCVD`.

**Preview** only shows the camera. **Inspect** runs the job on the newest frame whenever the last run finishes, so a
slow job lowers the inspection rate rather than falling behind. **Trigger** (⌘T) inspects once, and **Freeze** (⌘F)
holds an image so you can tune tools against it. You can also open an image file, including HEIC from an iPhone.

### Scale

Measurements are in pixels until you calibrate, from a chessboard in view or by typing a value (Job tab). Each camera
keeps its own scale, which holds only at the distance it was calibrated. If a job has any calibration and fails over to
a camera without one, limits on lengths and areas fail rather than compare pixels with millimetres.

Lens distortion isn't corrected, so keep measurements near the middle of the image.

## Quick Help

**View ▸ Quick Help** (⌥⌘/) shows a panel at the bottom left of the window, at the foot of the sidebar, telling what's
under the pointer in a sentence or two, with its shortcut. It covers the toolbar, each camera and why it's in the order
it is, every tool, setting and measure, and the job and results. Over the image, it names what a tool found under the
pointer and why that tool failed, or else gives the pixel position, in millimetres when calibrated. Over a results row,
it shows the whole failure text, which the column often cuts off. With the pointer over nothing it can describe, it
tells about the selected tool and its latest result.

**View ▸ Float Quick Help** (or the panel's float button) puts it in a small window of its own, which first opens at the
bottom left of the main window; closing that window docks it again. Both choices are remembered. The panel is a copy of
the one in the other Mx apps (`MxOpenCVD/QuickHelp/QuickHelp.swift`); what it says here is in `AppQuickHelp.swift`.

## Command line

The app's executable also runs without a window:

```bash
/Applications/MxOpenCVD.app/Contents/MacOS/MxOpenCVD --inspect job.json image.png --out results.json
```

The exit status is 0 if every image passes, 1 if any fails or can't be read, and 2 for a bad job file. Six more modes
are for checking the app itself:

| Mode | What it does |
| --- | --- |
| `--self-test` | Checks camera ranking, failover and pass/fail logic, with no camera |
| `--probe-cameras [--snapshots dir] [--out file]` | Starts each camera and measures a real frame from it |
| `--ui-check dir [--job file] [--image file] [--soak seconds]` | Runs the real window off screen on the live cameras, and records CPU and memory |
| `--repeat job.json [--seconds 10] [--camera name] [--out file]` | Runs a job on a live camera and reports how much each measure varies; keep the scene still |
| `--teach-color job.json "tool" "color" image x y width height out.json` | Adds a color to a color tool from a region of an image |
| `--export-contours job.json image out.dxf` | Exports the outlines from the job's first Contours tool; the extension sets the format, `.dxf`, `.svg` or `.csv` |

Run `--probe-cameras`, `--ui-check` and `--repeat` with `open -g -n MxOpenCVD.app --args ...` so macOS applies the app's camera
permission. Neither one changes the saved job or camera choice.

## Tests

```bash
Tests/run.sh
```

This runs the engine against images with known answers, including parts at any angle and OCR on a printed label. Code
reading is tested by the app's `--self-test`, since it uses Apple Vision.
`Tests/make_fixtures.py` regenerates the fixtures.

## Layout

| Path | Contents |
| --- | --- |
| `MxOpenCVD/Engine` | The vision engine: C++ on OpenCV and ONNX Runtime, with no Apple frameworks |
| `MxOpenCVD/Bridge` | The Objective-C++ layer that Swift calls, and the code-reading tool on Apple Vision |
| `MxOpenCVD/Camera` | Camera ranking, failover choice and capture |
| `MxOpenCVD/Inspection` | Jobs, tool definitions, the runner and pass/fail evaluation |
| `MxOpenCVD/UI`, `MxOpenCVD/App` | The window, app state and command-line modes |
| `MxOpenCVD/QuickHelp` | The Quick Help panel, and what it says in this app |
| `Models` | PaddleOCR models in ONNX form; see `THIRD_PARTY.md` for where they come from |
| `scripts` | Native library build, model conversion and install |

To add a tool, write its function in the engine, dispatch to it in `Engine::run`, and add a case to `ToolKind` in
`Job.swift`. The inspector builds its settings from that definition. Then describe its settings and measures in
`AppQuickHelp.swift`; `--self-test` fails if any are missing.
