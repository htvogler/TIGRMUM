# TIGRMUM Session Resume — 2026-04-30

## Current state

Branch: `robust_tracking` (branched from `master`, carries all prior fixes).
Test parameters: stp=1, smp=1702 — user about to run to find any remaining
problem frames between 1 and 1702.

---

## What was fixed this session

### 1. Orphaned-piece crash after gap repair (commit `64bad4d`)

**Symptom:** `bou{1}` crash at line 257: gap repair could add disconnected P
pieces that `imclose` didn't bridge; these survived as orphaned components with
their own skeleton endpoints, causing `K` sub-windows around them to be
all-zero → `bwboundaries(K)` returned `{}`.

**Fix 1:** `U = bwareafilt(U, 1)` after `imclose` — strips any component not
part of the main body.

**Fix 2:** `if ~isempty(bou)` guard around the `Kb = bou{1}` block.

### 2. Temporal gap repair — U_prev (commit `64bad4d`)

**Problem:** Original gap repair used global mask orientation (from
`regionprops`) to decide whether to include disconnected pieces. For bent
(arch-shaped) tubes this failed because the global orientation didn't match
the local exit direction at the gap end.

**Fix:** Store `U_prev = U` (after `bwareafilt`) at the end of each successful
frame. In the gap repair loop, test each candidate piece against a dilated
`U_prev` *first*. If it overlaps the previous frame's mask it is included
unconditionally — no geometry assumptions needed. The orientation check becomes
a fallback for the first frame only.

Key detail: `U_prev` is inside the `try` block and only updated on success, so
a failed frame leaves the last good mask available for the next frame.

### 3. Frame-skip system (commits `64bad4d`, `060f42b`, `9e0e249`, `1d8192d`)

The entire per-frame analysis body is wrapped in `try … catch ME`. On failure:

- Warning printed: `TIGRMUM: frame N failed — <message>`
- `frame_failed(count) = true`
- Black placeholder frame written to `growth.avi`
- Per-frame moving kymograph column stays zero (black)
- Fixed-line kymograph is **computed** in the catch block (only needs
  `L(:,:,count)` + the `smp` reference centerline, both always available)
- After the loop: all per-frame arrays (`tip_final`, `diamf_avg`, `Ucount`,
  `intensityM`, `intensityM_F`, all ROI/split variants) for failed frames are
  set to NaN before CSV export

Additional robustness fixes made along the way:

- All per-frame arrays pre-initialised as NaN before the loop — prevents
  "Unrecognized function or variable" crashes in post-loop plots/CSV when
  every frame fails
- `V_frame_size` pre-computed from a dummy figure before the loop — ensures
  the black placeholder frame is always the correct size, even when the first
  frame fails
- Kymograph post-processing guarded: `if exist('kymo_avg','var') &&
  ~isempty(kymo_avg)` — prevents crash when smp frame itself failed
- `axis()` calls on tip and diameter plots guarded against all-NaN data

### 4. right_col / ra_row NaN crash (no separate fix needed)

`round(mean([]))` → NaN → invalid index crash at line 466. Now caught by the
try/catch and handled as a skipped frame.

---

## Confirmed working

- Frame 1701 alone: correctly skipped, black frame written, plots complete
- Frames 1701+1702: temporal repair picks up the disconnected right-arm piece
  in 1701 using 1702's mask → analysis succeeds

---

## Known open items

- Running stp=1, smp=1702 to find any remaining problem frames
- Diagnostic blocks (images 01–14 per run) still in `main_track_movies.m`
- FRET-IBRA HDF5 attribute overflow on 9000-frame stack — fix in
  `fret-ibra/ibra/functions.py` line 274: store `res_range` as dataset
  not attribute
- `robust_tracking` branch not yet merged to `master` or pushed to remote
  (currently ~20+ commits ahead)

---

## Important preferences

- Do not change any code without asking the user first and getting explicit approval
- Do not commit after every small fix — wait until a change is confirmed working
