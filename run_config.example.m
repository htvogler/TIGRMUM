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
threshold_method = 'triangle'; % Per-frame background/foreground separation for single-channel
                 % and two-channel-without-ratio modes (ratio mode is unaffected -- its
                 % background is already handled upstream by FRET-IBRA). Pick based on the
                 % sensor's intensity distribution along the tube, not the imaging mode:
                 %   'triangle' - for sensors where a small, very bright region sits next to
                 %                much dimmer but still-real signal, e.g. a saturated GCaMP
                 %                tip next to a dim shank. Otsu's variance criterion gets
                 %                pulled toward isolating the rare bright outlier and throws
                 %                the dim-but-real shank away as "background"; Triangle finds
                 %                where the histogram departs from the background peak
                 %                instead, regardless of how far the bright tail extends.
                 %                Default, since most current work is GCaMP.
                 %   'otsu'     - for sensors with fairly uniform intensity along the tube's
                 %                length, e.g. yellow cameleon CFP/YFP (tip and shank
                 %                comparably bright). Triangle over-includes background noise
                 %                here (tested on YC11: kept ~4x more pixels than Otsu, mostly
                 %                noise speckle, not tube) because there's no sharp peak-to-
                 %                tail departure for it to key off.
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
                 %                get wrong. Experimental -- prototype-validated on synthetic
                 %                data this session, not yet run on a full real stack. Run both
                 %                side by side on the same data before trusting it over
                 %                'skeleton' for real measurements.
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
max_tip_jump_um = 15; % Only used when weak_signal=1: (a) as the reject threshold for
                 % frame_failed in the reverse pass, (b) as the forward repair pass's
                 % constructive lower bound on tip position (see weak_signal above). Max
                 % plausible frame-to-frame tip displacement in um before a frame is
                 % considered a tracking failure rather than real growth+jitter. Empirically
                 % calibrated (not growth-rate-derived): measured on 3 real datasets (~6500
                 % transitions) -- genuine growth+jitter never exceeded ~9.7um on two clean
                 % datasets, while a third (known segmentation failures) showed a sharp gap
                 % in the distribution with nothing between ~5um and ~41um. 15um sits in that
                 % gap; any value from 10-30um gives the identical result on all 3 datasets,
                 % so it's not a sensitive parameter -- re-check if working with a very
                 % different growth rate/frame rate regime.
