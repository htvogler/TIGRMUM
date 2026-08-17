% run_config.m — per-run analysis parameters.
% Copy this file to run_config.m (gitignored) and edit freely — that file
% will never show up in `git status`, so per-dataset/per-run changes stay
% local. main_track_movies.m loads it via run('run_config.m').

% Path to Mat file
path = '/Users/htv/Downloads/20260417/movies/tiff/FRET-IBRA_results/HV197_1_17'; % Input folder path (ADD PATH TO FILE HERE)
fname = 'HV197_1_17'; % Filename
stp = 1; % Start frame number
smp = 2010; % End frame number

% Options for analysis
tip_plot = 0; % Video tip detection, has no effect if video_intensity = 2
video_intensity = 1; % Intensity video: 0 = off, 1 = on + analysis, 2 = video only
frame_rate = 0.150; % Number of seconds per frame of input video
distributions = 0;  % Show histogram of results in the end
workspace = 0; % Save workspace
debug_mode = 0; % Save per-run diagnostic images + print ROI arc debug info to console
roi_debug_video = 0; % Save {fname}_roi_debug.avi (uncompressed -- MPEG-4 chroma
                     % subsampling mangled the thin overlay at this frame size):
                     % real intensity (jet colormap) with the traced centerline and
                     % ROI halves outlined (Half1=red, Half2=blue) overlaid, in the
                     % same orientation as the tracking geometry. Separate from growth.mp4 and
                     % _intensity.avi -- doesn't touch either. Meant for checking the ROI-split
                     % geometry directly against the real signal, e.g. if Half2/Half1 looks biased.
upsample = 0; % 0 = off (default). 1 = bicubic-upsample the raw stack 2x before
                     % segmentation/tracking. Experimental: tests whether more pixels per
                     % tube (currently only ~10px wide, so a 1px error is a much bigger
                     % fraction of the object than on a wider tube) reduces
                     % segmentation/centerline bias. All the pipeline's hardcoded
                     % pixel-based constants (erosion/closing radii, bwareaopen area
                     % thresholds) are scaled internally to match -- still enter the
                     % camera's true, native pixelsize below; it's halved internally
                     % when this is on. Roughly 4x the pixels/frame, so slower; try on
                     % a short stp/smp range first. Keep in mind: this interpolates
                     % existing pixels, it doesn't add real optical resolution -- for
                     % new acquisitions, a higher-mag objective/tube lens or no pixel
                     % binning addresses the root cause directly.

% Tip detection parameters
weight = 0.5; % Distance to eliminate branches (Higher means more reliance on the tip ellipse), 0 follows only the thinned edge.

% ROI options
ROItype = 1; % No ROI = 0; Moving ROI = 1; Stationary ROI = 2
split = 1; % Split ROI along center line
circle = 0; % Circle ROI as fraction of diameter
starti = 0; % Rectangle ROI Start length / no pixelsize means percentage as a fraction of length of tube
stopi = 10; % Rectangle/Circle ROI Stop length / no pixelsize means percentage as a fraction of length of tube
pixelsize = 0.645; % Pixel to um conversion

% Kymo, movie and measurements options
Cmin = 1.5; % Min pixel value in Ratio stack
Cmax = 3; % Max pixel value in Ratio stack
nkymo = 3; % Number of pixels line width average for kymograph (odd number) (0 means no kymo)
diamcutoff = 0; % In pixels if pixelsize is not given
bit_depth = 12; % Camera bit depth (12 or 16) — must match FRET-IBRA config
threshold_method = 'otsu'; % Per-frame background/foreground separation for single-channel
                 % and two-channel-without-ratio modes (ratio mode is unaffected -- its
                 % background is already handled upstream by FRET-IBRA). Pick based on the
                 % sensor's intensity distribution along the tube, not the imaging mode:
                 %   'otsu'     - per-frame Otsu, biased by otsu_sensitivity below. DEFAULT,
                 %                including for GCaMP (bright tip next to a dimmer-but-still-
                 %                clearly-above-background shank) -- reversing an earlier
                 %                recommendation to use 'triangle' here. Compared directly on a
                 %                real GCaMP dataset (HV207_9): with otsu_sensitivity relaxed
                 %                enough to stop severing the mask on real per-frame signal dips,
                 %                otsu beat triangle on every axis checked -- closer to the true
                 %                diameter (independently measured via cross-sectional FWHM: otsu
                 %                ~14% over vs. triangle ~36% over), visibly smoother mask
                 %                boundary, and ~3x more stable frame-to-frame diameter. See
                 %                signal_threshold.m for the full writeup.
                 %   'triangle' - for GENUINELY weak signal specifically: the tip still bright,
                 %                but the shank barely above the background noise floor at all
                 %                (not just dimmer than the tip). otsu_sensitivity has no good
                 %                setting there -- relaxed enough to admit a barely-visible
                 %                shank, it also admits background noise broadly, since there's
                 %                no longer a comfortable margin between "real dim shank" and
                 %                "noise" for a fixed fraction-of-Otsu-level cut to exploit.
                 %                Triangle finds where the histogram departs from the
                 %                background peak's own shape instead of a fixed offset, so it
                 %                can still separate real-but-faint signal from noise here.
otsu_sensitivity = 0.7; % otsu method only. Multiplier on the raw Otsu level -- 1.0 is
                 % unbiased Otsu, <1.0 lowers the effective cutoff to admit more of the
                 % dim-but-real signal (e.g. GCaMP shank) as foreground. 0.7 is what stopped
                 % per-frame mask severing on HV207_9 (0.8 was not enough); not yet swept on
                 % other datasets, so treat 0.7 as a starting point, not a proven constant --
                 % if severing/NaN'd frames show up, try lowering it before switching to
                 % 'triangle'. See signal_threshold.m for the full writeup.
tip_method = 'skeleton'; % How to find the tip each frame (fluorescence-only pipeline).
                 %   'skeleton' - thin the mask, prune spurious branches (branch_removal.m),
                 %                seed an ellipse fit from the surviving endpoint. Default,
                 %                battle-tested, but branch-removal can occasionally fail to
                 %                prune down to exactly 2 endpoints at a sharp bend, leaving the
                 %                tip seeded from an arbitrary leftover candidate instead of the
                 %                real tip (confirmed on HV200_2_24_cropped frames 1482/1500).
                 %   'ringwalk' - skeleton-free alternative (ring_walk_tip.m, after Zhu et al.
                 %                2025 doi:10.1002/advs.202507434): walk outward from the base
                 %                via expanding ring-intersection centroids, no branch graph to
                 %                get wrong. Verified via a full 999-frame run on
                 %                20260327_3_cropped: reaches 0 NaN frames with
                 %                ringwalk_seed_from_tip and ringwalk_fallback_to_skeleton both
                 %                on (see their own doc comments below for what each fixes).
                 %                Still validated on only that one dataset -- one frame rate,
                 %                one tube geometry, one growth pattern -- so run side by side
                 %                against 'skeleton' on a new dataset before trusting it there;
                 %                'skeleton' remains the only method validated across many
                 %                datasets.
weak_signal = 0; % 0 = plain segmentation only (default). 1 = two-pass repair for stacks
                 % with fragmented/dropout signal:
                 %  1) The main (reverse, smp:-1:stp) pass runs fully plain -- no gap-repair
                 %     machinery touches any frame's mask. It only flags frames as
                 %     needs_repair (severed into 2+ comparable components, noisy 3+
                 %     components, or fails to reach the tracking border when the previous
                 %     frame did) or frame_failed (diam_tol / tip-jump, see max_tip_jump_um).
                 %     This replaces the old always-on mechanism (reference-mask union +
                 %     temporal rescue applied to every frame regardless of need), which
                 %     could quietly distort already-good frames -- see session notes.
                 %  2) A forward repair pass (stp->smp, chronological order) then attempts
                 %     ONLY the flagged frames: unions in the reference (smp) frame's own
                 %     mask shape for the shank, then -- since forward order means "previous
                 %     frame" is the real previous-in-time frame -- extends the mask toward
                 %     the tip when it falls short of (previous frame's tip - max_tip_jump_um),
                 %     using max_tip_jump_um as a constructive lower bound instead of only a
                 %     post-hoc reject test. Frames it can't repair stay flagged/NaN'd exactly
                 %     as before. Recomputes tip/diameter/ROI-intensity together so a repaired
                 %     frame's numbers are mutually consistent; does NOT redo kymograph,
                 %     diagnostics, or the growth/roi_debug videos for repaired frames (those
                 %     stay as the plain pass produced them -- visualization only, not
                 %     measurements.csv). Also gates signal_threshold.m's two-component bridge
                 %     (severed mask -> bridge into one piece) the same as before.
                 % Applies to single-channel and two-channel-without-ratio modes only; ratio
                 % mode is unaffected either way.
max_tip_jump_um = -1; % Max plausible frame-to-frame tip displacement in um before a frame
                 % is considered a tracking failure rather than real growth+jitter.
                 % Unconditional -- applies (a) as the reject threshold for frame_failed in
                 % the reverse pass, (b) when weak_signal=1, as the forward repair pass's
                 % constructive lower bound on tip position -- regardless of weak_signal or
                 % tip_method (this is a "did the tip physically teleport" check, a different
                 % concern from weak_signal's "is the mask fragmented"). Confirmed needed with
                 % weak_signal=0: ring_walk_tip produced a catastrophic single-frame tip jump
                 % that went completely unflagged while this check used to be gated behind
                 % weak_signal, on a frame whose raw image was visually identical to its
                 % neighbors -- a pure tracking-algorithm failure, exactly what this check
                 % exists to catch.
                 % -1 (default) = auto-derive from jitter_margin_um/max_growth_rate_um_per_min/
                 % growth_safety_factor below, using this run's own frame_rate. Set to any
                 % positive number instead to override the derivation entirely and use that
                 % fixed value everywhere above, exactly the old (pre-derivation) behaviour.
jitter_margin_um = 10; % Only used when max_tip_jump_um <= 0 (see above). Fixed floor on the
                 % derived threshold: frame-to-frame tracking jitter alone (segmentation
                 % noise, boundary-tracing noise -- NOT real growth) that's present even at
                 % short frame intervals. Empirically calibrated: measured on 3 real datasets
                 % (~6500 transitions) -- genuine growth+jitter never exceeded ~9.7um on two
                 % clean datasets, while a third (known segmentation failures) showed a sharp
                 % gap in the distribution with nothing between ~5um and ~41um. Candidate for
                 % re-calibration now that frame_rate is known precisely for ~50 real stacks
                 % spanning a 6.7x range (0.15-1.0s), vs. the original 3-dataset calibration --
                 % re-check if working with a very different growth rate/frame rate regime.
max_growth_rate_um_per_min = 5; % Only used when max_tip_jump_um <= 0. Rare-case upper bound
                 % on real tip advancement, NOT a typical rate -- "a fast growing Arabidopsis
                 % PT grows 5um/min, however this speed is rare" is the biological anchor this
                 % default is based on. Deliberately conservative/high so the derived threshold
                 % doesn't clip genuine fast growth -- being too high here only costs a
                 % slightly looser jump-reject threshold, not a missed-growth bug.
growth_safety_factor = 3; % Only used when max_tip_jump_um <= 0. Multiplier on
                 % max_growth_rate_um_per_min in the derivation below, so the threshold doesn't
                 % clip right at the rare-case rate:
                 %   max_tip_jump_um = jitter_margin_um +
                 %                     (max_growth_rate_um_per_min/60) * growth_safety_factor * frame_rate
                 % At this project's actual frame rates so far (0.15-1.0s), the growth term
                 % contributes only 0.0125-0.083um per frame -- negligible next to
                 % jitter_margin_um -- so this mainly future-proofs much longer frame intervals
                 % (10s+), where growth's per-frame contribution would start to dominate and a
                 % fixed jitter constant would wrongly reject real fast growth.

% Ringwalk tip-seeding (tip_method='ringwalk' only)
ringwalk_seed_from_tip = 0; % 0 (default, conservative -- see below) = ring_walk_tip always
                 % starts from the base anchor, as before. 1 = when the previous (loop-order)
                 % frame's tip is available (last_flag) and a valid seed can be placed, start the
                 % walk near there instead -- shortens the walk and reduces exposure to
                 % ring_walk_tip's known failure modes (T-junction misjudgment, false
                 % width-collapse stops), both of which scale with walk length. Falls back to a
                 % full base-anchored walk automatically when seeding isn't possible (out of
                 % bounds, no local mask support, seeded walk takes zero steps) or periodically
                 % per ringwalk_reanchor_interval below, to bound accumulated seed-to-seed drift.
                 %
                 % Two earlier approaches (both estimating a direction to bias the walk FROM
                 % tip_final_last itself) were tried and failed, for a shared root cause: seeded
                 % exactly at tip_final_last, real per-frame growth (~1px on
                 % 20260327_3_cropped) leaves almost no genuine mask beyond it -- far short of
                 % the ring's own radius (~0.65*diamo, ~20-25px on that stack). The ring can't
                 % detect a crossing that close; it only finds the substantial base-ward shank,
                 % and ring_walk_tip.m takes a lone candidate unconditionally (no scoring
                 % happens at all when ncomp==1) -- so no direction estimate, however accurate,
                 % could matter: there was never a second candidate for it to prefer.
                 %
                 % Current approach: seed ringwalk_seed_offset_factor*diamo back (base-ward)
                 % from tip_final_last along a local skeleton tangent (local_tip_tangent,
                 % main_track_movies.m), snapped to the nearest real mask pixel. This guarantees
                 % real mask on BOTH sides of the very first ring, so a genuine tip-ward
                 % candidate actually exists. Step 1 then picks between them with a hard rule
                 % (ring_walk_tip's prefer_smaller_col) instead of a soft direction score: this
                 % pipeline's own crop convention already guarantees tip-ward = smaller column
                 % (every tube enters the crop from the right border), so this needs no estimate
                 % at all, just a direct comparison -- more robust than scoring against a tangent
                 % that curvature right at the seed could throw off. From step 2 on,
                 % ring_walk_tip's normal direction-continuity scoring takes over on its own
                 % (prev_dir is always set from the actual observed move after step 1), so this
                 % rule only ever resolves that single first-step choice -- everything after
                 % behaves exactly like a base-anchored walk's own final approach to the tip,
                 % which was never the broken part. Verified via a full 999-frame run on
                 % 20260327_3_cropped: the original frame 11 catastrophic jump is fixed, plus a
                 % second latent failure (frame 2) that the base-anchored-every-frame approach
                 % also has. Combined with ringwalk_fallback_to_skeleton below (needed for
                 % frames 63/97/134 on that same stack, a separate pre-existing ring_walk_tip
                 % branch-selection weakness this seeding change doesn't itself fix), the
                 % combination reaches 0 NaN frames on that stack. Still validated on only that
                 % one dataset (one frame rate, one tube geometry, one growth pattern) -- run
                 % side by side against 'skeleton' on a new dataset before trusting it there.
ringwalk_seed_offset_factor = 2.5; % ringwalk_seed_from_tip only: how far back (base-ward,
                 % in units of diamo) from tip_final_last to place the seed point, along the
                 % local tangent. Must comfortably exceed the ring radius (~0.65*diamo) so the
                 % first ring's tip-ward side has enough real, established tube to detect a
                 % genuine crossing on (see ringwalk_seed_from_tip above) -- 2.5x leaves a solid
                 % margin without wasting many steps re-walking already-known territory.
ringwalk_seed_max_steps = 30; % ringwalk_seed_from_tip only: max_steps passed to ring_walk_tip
                 % for a SEEDED walk only (a base-anchored walk keeps ring_walk_tip.m's own 500
                 % default). A seeded walk only needs to cover one frame's worth of
                 % growth+jitter, not the whole crop -- a small cap keeps a misbehaving seeded
                 % walk cheap to detect and fall back from.
ringwalk_reanchor_interval = 50; % ringwalk_seed_from_tip only: force a full base-anchored walk
                 % every N frames (0 = never force, always seed when possible). Frame-to-frame
                 % jump limiting alone doesn't catch slow SYSTEMATIC drift accumulated over many
                 % consecutive seeded walks (each individually within max_tip_jump_um);
                 % periodic re-anchoring to the base resets any such drift. Counted in
                 % loop-processing order, same convention as tip_final_last throughout.
ringwalk_fallback_to_skeleton = 0; % ringwalk only (tip_method='ringwalk'). 0 (default, opt-in
                 % off) = a frame that fails the tip-jump check (max_tip_jump_um) is flagged/NaN'd
                 % exactly as before. 1 = before giving up, retry that SAME frame using the
                 % skeleton method's own Qef/branch-removal/voting logic (a self-contained copy,
                 % skeleton_tip_fallback in main_track_movies.m -- NOT shared with the primary
                 % 'skeleton' path or with find_tip_and_measure's forward-repair copy, by design:
                 % duplicated rather than refactored to keep zero risk to those already-verified
                 % paths) and adds its result to the jump-check's candidate pool. Confirmed needed
                 % on 20260327_3_cropped (ringwalk_seed_from_tip=1): frames 63/97/134 hit a sharp
                 % bend where ring_walk_tip's per-step direction-continuity scoring picks the
                 % wrong branch with a clear, non-tied margin, producing a ~55px jump -- today
                 % these have no alternate candidate (tip_skel/tip_mid are only ever populated
                 % when tip_method='skeleton' natively runs), so they NaN with no rescue attempted.
                 % Adds a 'Tip_skeleton_fallback_used' column to the output CSV (1 if this row's
                 % tip came from the fallback, whether or not it ultimately passed the jump check,
                 % 0 otherwise) so recovered frames are auditable, not silently substituted.
