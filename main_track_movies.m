clear all
close all

run('run_config.m'); % Per-run parameters (gitignored) — copy from run_config.example.m

% max_tip_jump_um derivation: frame-rate/growth-rate coupled instead of a
% fixed constant, since real frame rates in use span a 6.7x range (0.15s to
% 1.0s across datasets characterized this session) and a single fixed-um
% threshold can't be right for all of them. Defensively defaulted here (not
% just in run_config.example.m) since existing per-user run_config.m files
% predate these parameters and won't define them at all. max_tip_jump_um
% left positive (old-style, e.g. = 15) skips the derivation entirely and is
% used verbatim everywhere below -- full backward compatibility.
if ~exist('jitter_margin_um', 'var'), jitter_margin_um = 10; end
if ~exist('max_growth_rate_um_per_min', 'var'), max_growth_rate_um_per_min = 5; end
if ~exist('growth_safety_factor', 'var'), growth_safety_factor = 3; end
if ~exist('max_tip_jump_um', 'var') || isempty(max_tip_jump_um), max_tip_jump_um = -1; end
if max_tip_jump_um <= 0
    max_tip_jump_um = jitter_margin_um + (max_growth_rate_um_per_min/60) * growth_safety_factor * frame_rate;
    if exist('debug_mode', 'var') && debug_mode
        fprintf('max_tip_jump_um: auto-derived = %.2fum (jitter=%.1f + growth=%.4fum/s * safety=%.1f * frame_rate=%.3fs)\n', ...
            max_tip_jump_um, jitter_margin_um, max_growth_rate_um_per_min/60, growth_safety_factor, frame_rate);
    end
elseif exist('debug_mode', 'var') && debug_mode
    fprintf('max_tip_jump_um: explicit override = %.2fum (frame-rate derivation skipped)\n', max_tip_jump_um);
end
% ellipse_data.m's own within-frame candidate sanity check (see its
% max_jump_px doc) needs a MUCH tighter bound than max_tip_jump_um above --
% that one is deliberately generous (real growth + jitter + safety factor,
% ~31px here) since it's rejecting genuinely implausible frame-to-frame
% displacement. This one is answering a different question: "is this
% ellipse candidate still the SAME local tip feature, or did the search
% window's point cloud spill onto an adjacent feature (a bend, a nascent
% outgrowth)?" -- confirmed on HV209_62 F3279 that a spilled-onto-the-bend
% candidate can be 15px off while still passing comfortably under the
% ~31px growth-based threshold. diamo itself (the tube's own width) is the
% right scale for "still plausibly the same local bulge" -- computed
% per-frame from diamo_est/diamo where each locate_tip call site already
% has it (diamo_est/diamo aren't known yet this early in the script, so
% this can't be hoisted up here the way max_tip_jump_um is).
% Default Inf = bound OFF: with the border-drift limit below active, the tip
% cannot teleport, and this bound was found to freeze the tip whenever it sits
% more than half a diameter from the true apex (HV200_4_5 F3552), because the
% ellipse could then never pull it back. 0.5 = the old bound (half a tube
% diameter); useful with tip_method='ringwalk' if the ellipse spills sideways.
if ~exist('ellipse_candidate_max_jump_factor', 'var'), ellipse_candidate_max_jump_factor = Inf; end

% Lateral-offset guard + stationary-lock guard (2026-09-16): max_tip_jump_um
% above is a pure Euclidean distance budget, which has to be scaled by
% frame_rate/growth_rate -- and that's exactly its blind spot. A real tip
% can legitimately move a lot per frame at a low frame rate or fast growth
% (that's what the budget is FOR), but how far it can move SIDEWAYS off the
% tube's own established axis does not depend on either -- it's bounded by
% the tube's physical diameter, a frame-rate-independent quantity. Confirmed
% needed on HV200_4_5 (manual-seed anchor at F5201): the very next frame
% (F5200) jumped only 11px/3.5um -- comfortably inside max_tip_jump_um's
% ~31px budget -- onto a static, non-growing feature next to the real tube,
% then tracked that same frozen point for ~1300 frames (diameter measured
% bit-identical across dozens of consecutive frames), never registering as
% a "jump" again because the frozen point doesn't move relative to ITSELF
% either. Two independent, additive checks below (both must be satisfied,
% alongside the existing max_tip_jump_um check, for a candidate to be
% accepted without triggering the recovery-candidate-pool path):
%  1. lateral_offset_max_factor: the component of (candidate - tip_final_last)
%     PERPENDICULAR to the recently-established travel direction (from
%     tip_final_last2 -> tip_final_last, i.e. real observed motion, not an
%     assumed shape) must not exceed this fraction of diamo_est. Only
%     evaluated when that direction is well-defined (the last two good
%     frames were more than a pixel or so apart) -- skipped otherwise (cold
%     start, or a stack that's itself been stationary so far), since with no
%     established axis there's nothing meaningful to decompose against.
%  2. stationary_lock_n_frames/stationary_pos_eps_px/stationary_diam_eps_px:
%     if the tip's position AND diameter both stay within noise-floor
%     tolerance for this many consecutive frames, treat the run as locked
%     onto a static feature -- even though no single frame in the streak
%     ever violated max_tip_jump_um or the lateral check on its own -- and
%     refuse to accept ANY further candidate that's still within
%     stationary_pos_eps_px of that same frozen point, forcing the recovery
%     pool to either find a genuinely different point or flag/NaN the frame.
%     Diameter bit-identical to many decimal places across consecutive
%     frames (not just similar) was the actual observed signature on
%     HV200_4_5 -- real per-frame segmentation noise doesn't reproduce that.
if ~exist('lateral_offset_max_factor', 'var'), lateral_offset_max_factor = Inf; end
if ~exist('stationary_lock_n_frames', 'var'), stationary_lock_n_frames = 5; end
if ~exist('stationary_pos_eps_px', 'var'), stationary_pos_eps_px = 1.5; end
if ~exist('stationary_diam_eps_px', 'var'), stationary_diam_eps_px = 0.05; end
% Bounded-step alternatives to "jump to a candidate" (2026-09-21; defaults
% below = the HV209_62 run-3 settings, see the commit message). Both walk along this frame's mask contour toward the
% target instead of jumping to it (see step_along_contour).
%  stationary_nudge_um: when the stationary lock is the ONLY reason a candidate
%    was refused, move this far along the contour toward the nearest passing
%    candidate instead of taking that candidate. Must exceed stationary_pos_eps_px
%    (in um) or the lock would not release. 0 = off (old behaviour).
%  max_step_um: hard cap on how far the accepted tip may move from the last good
%    tip in one frame (x frames_since_last_good), in ANY direction and on every
%    acceptance path, incl. first-choice tips. The lateral guard only bounds the
%    sideways part; max_tip_jump_um (dominated by jitter_margin_um) is the only
%    limit along the axis. Inf = off.
if ~exist('stationary_nudge_um', 'var'), stationary_nudge_um = 1.0; end
if ~exist('max_step_um', 'var'), max_step_um = Inf; end
% Border-drift limit derived like the jump budget, but from the REAL tracking
% noise instead of the 10um "teleport" floor: per-frame drift of the tip along
% the mask border <= border_jitter_um + growth term. Overrides max_step_um.
if ~exist('border_jitter_um', 'var'), border_jitter_um = 1.5; end
if isfinite(border_jitter_um)
    max_step_um = border_jitter_um + (max_growth_rate_um_per_min/60) * growth_safety_factor * frame_rate;
    fprintf('border drift limit: %.3fum per frame (border_jitter_um=%.2f + growth term)\n', max_step_um, border_jitter_um);
end
% Nudge target limit (2026-09-24, HV209_62 F1883): the freeze breaker refuses every
% candidate within stationary_pos_eps_px of the frozen tip, so the only candidate
% left can sit far away on ANOTHER part of the tube end (there: the corner, 7 px /
% 0.4 D off, while ellipse and skeleton both agreed with the frozen tip). Nudging
% toward it dragged the tip onto the wrong side. Now the freeze breaker only
% releases toward a candidate within nudge_max_cand_dist_factor * diamo_est of the
% frozen tip; if none is that close, the tip HOLDS (a genuine growth pause looks
% exactly like a freeze). Only used while stationary_nudge_um > 0. Inf = no limit.
if ~exist('nudge_max_cand_dist_factor', 'var'), nudge_max_cand_dist_factor = 0.25; end
% Side memory (2026-09-24): cumulative sideways drift of the tip relative to the
% tube's own local axis (local_tip_tangent, taken at the previous tip; oriented
% for continuity between frames) is remembered and limited to
% side_offset_max_factor * diamo_est. Per-frame limits (lateral guard, drift
% limit) cannot stop a slow slide from the tube-end middle onto a corner in a few
% small steps; this can. A step that pushes |accumulated offset| past the limit
% is refused like any other guard failure (recovery pool, else hold); steps that
% reduce the offset always pass, so the tip can come back. The offset leaks by
% side_memory_decay per accepted frame so a real turn is not blocked forever.
% Inf = off.
if ~exist('side_offset_max_factor', 'var'), side_offset_max_factor = 0.25; end
if ~exist('side_memory_decay', 'var'), side_memory_decay = 0.99; end
side_acc = 0; side_axis_prev = [];
% Ellipse-first vote (2026-09-24, experimental, default OFF = continuity-first vote): with a trusted
% previous tip, the vote normally picks whichever of ellipsef/skel/mid is nearest to it. On
% HV200_4_5 (F3680 onward) that lets the mid candidate, which drifts along with the tip, take over
% from the ellipse pole and walk the tip ~28 px base-ward. With vote_ellipse_first = 1 the ellipse
% candidate is the vote pick, and skel/mid only come in through the guard recovery pool when the
% ellipse candidate fails a guard.
if ~exist('vote_ellipse_first', 'var'), vote_ellipse_first = 0; end
stationary_streak = 0; % consecutive accepted frames within eps of tip_final_last (pos+diam)

% ringwalk tip-seeding defaults (see run_config.example.m for full docs) --
% defensively defaulted here for the same reason as above: existing
% run_config.m files predate these and won't define them.
if ~exist('ringwalk_seed_from_tip', 'var'), ringwalk_seed_from_tip = 0; end
if ~exist('ringwalk_seed_max_steps', 'var'), ringwalk_seed_max_steps = 30; end
if ~exist('ringwalk_reanchor_interval', 'var'), ringwalk_reanchor_interval = 50; end
if ~exist('ringwalk_seed_offset_factor', 'var'), ringwalk_seed_offset_factor = 2.5; end
if ~exist('ringwalk_fallback_to_skeleton', 'var'), ringwalk_fallback_to_skeleton = 0; end

% Manual tip seed for the anchor frame (count==smp, no prior history) --
% see run_config.example.m for full docs. Defensively defaulted here for
% the same reason as above.
if ~exist('manual_tip_seed_row', 'var'), manual_tip_seed_row = []; end
if ~exist('manual_tip_seed_col', 'var'), manual_tip_seed_col = []; end
if ~exist('manual_tip_seed_radius_factor', 'var'), manual_tip_seed_radius_factor = 0.25; end
if ~exist('manual_tip_seed_interactive', 'var'), manual_tip_seed_interactive = 0; end

% Which conic fit locate_tip.m/ellipse_data.m uses -- see ellipse_data.m's
% own doc. 'ransac' (default) is robust to a nearby branch contaminating
% the local point cloud; 'legacy' is the original single least-squares fit,
% which can suit a developing flattened/"club" tip shape better on some
% stacks by accident (confirmed needed on HV210_3 this session). Per-stack,
% not a global tuning knob -- no single method dominates on every stack.
if ~exist('ellipse_fit_method', 'var'), ellipse_fit_method = 'ransac'; end

% Widens the per-run diagnostic PNG dump (normally only count==smp and
% count==smp-1, see DIAGNOSTIC BLOCK 1/2's own comments) to every frame in
% [lo hi] inclusive, in addition to smp/smp-1. Empty (default) = unchanged
% behaviour. For diagnosing a real multi-frame drift (e.g. "why does the
% tip wander frame-by-frame downstream of a known-good anchor"), set lo/hi
% to the range of interest and smp to the TRUE stack end -- ringwalk's own
% seeding is history-dependent (ringwalk_seed_from_tip), so only a
% continuous run from the real anchor reproduces the actual per-frame
% seeding that produced the drift; re-anchoring smp at some frame N+1 to
% dump just frame N (the single-frame technique in DIAGNOSTIC BLOCK 1's own
% comment) does NOT reproduce this, since it fabricates a fresh cold start
% partway through instead of a continuation.
if ~exist('debug_frame_range', 'var'), debug_frame_range = []; end

% FWHM diameter calibration defaults (see fwhm_diameter_correction in
% run_config.example.m) -- defensively defaulted here for the same reason
% as above.
if ~exist('fwhm_diameter_correction', 'var'), fwhm_diameter_correction = 0; end
if ~exist('fwhm_calib_interval', 'var'), fwhm_calib_interval = 50; end
if ~exist('fwhm_calib_samples', 'var'), fwhm_calib_samples = 12; end
if ~exist('fwhm_calib_window', 'var'), fwhm_calib_window = 5; end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Detect input file and select analysis mode
pathf = path;
ratio_file = [pathf '/' fname '_ratio_back.h5'];
back_file  = [pathf '/' fname '_back.h5'];

% Build output path: {root}/TIGRMUM_results/{fname}/
% Assumes input is at {root}/FRET-IBRA_results/{fname}/
% Override via run_config.m's `outpath_override`, if set, to write directly
% to a specific directory instead -- e.g. for side-by-side method
% comparisons, so results never pass through (and risk mixing with
% whatever pre-existing content sits in) the default shared location.
[fribra_dir, ~, ~] = fileparts(pathf);
[root_dir,   ~, ~] = fileparts(fribra_dir);
if exist('outpath_override', 'var') && ~isempty(outpath_override)
    outpath = outpath_override;
else
    outpath = fullfile(root_dir, 'TIGRMUM_results', fname);
end
if ~exist(outpath, 'dir'), mkdir(outpath); end
figpath = fullfile(outpath, 'Figures');
if ~exist(figpath, 'dir'), mkdir(figpath); end

% Settings log: every run_config.m parameter as actually loaded/defaulted
% this run (not the file's own text/comments), grouped by what it governs,
% so a results folder stays self-describing even if run_config.m later
% changes or is gone.
cfg = struct('path',path,'fname',fname,'stp',stp,'smp',smp,'outpath',outpath, ...
    'tip_plot',tip_plot,'video_intensity',video_intensity,'frame_rate',frame_rate, ...
    'distributions',distributions,'workspace',workspace,'debug_mode',debug_mode, ...
    'roi_debug_video',roi_debug_video,'upsample',upsample, ...
    'weight',weight,'tip_method',tip_method,'weak_signal',weak_signal, ...
    'max_tip_jump_um',max_tip_jump_um,'jitter_margin_um',jitter_margin_um, ...
    'max_growth_rate_um_per_min',max_growth_rate_um_per_min,'growth_safety_factor',growth_safety_factor, ...
    'ringwalk_seed_from_tip',ringwalk_seed_from_tip,'ringwalk_seed_offset_factor',ringwalk_seed_offset_factor, ...
    'ringwalk_seed_max_steps',ringwalk_seed_max_steps,'ringwalk_reanchor_interval',ringwalk_reanchor_interval, ...
    'ringwalk_fallback_to_skeleton',ringwalk_fallback_to_skeleton, ...
    'ROItype',ROItype,'split',split,'circle',circle,'starti',starti,'stopi',stopi,'pixelsize',pixelsize, ...
    'threshold_method',threshold_method,'otsu_sensitivity',otsu_sensitivity,'bit_depth',bit_depth,'diamcutoff',diamcutoff, ...
    'fwhm_diameter_correction',fwhm_diameter_correction,'fwhm_calib_interval',fwhm_calib_interval,'fwhm_calib_samples',fwhm_calib_samples,'fwhm_calib_window',fwhm_calib_window, ...
    'Cmin',Cmin,'Cmax',Cmax,'nkymo',nkymo);
settings_groups = { ...
    'Input / Output',              {'path','fname','stp','smp','outpath'}; ...
    'Analysis Options',            {'tip_plot','video_intensity','frame_rate','distributions','workspace','debug_mode','roi_debug_video','upsample'}; ...
    'Tip Detection',                {'weight','tip_method','weak_signal','max_tip_jump_um','jitter_margin_um','max_growth_rate_um_per_min','growth_safety_factor'}; ...
    'Ringwalk Tip-Seeding',          {'ringwalk_seed_from_tip','ringwalk_seed_offset_factor','ringwalk_seed_max_steps','ringwalk_reanchor_interval','ringwalk_fallback_to_skeleton'}; ...
    'ROI Options',                   {'ROItype','split','circle','starti','stopi','pixelsize'}; ...
    'Segmentation / Thresholding',   {'threshold_method','otsu_sensitivity','bit_depth','diamcutoff','fwhm_diameter_correction','fwhm_calib_interval','fwhm_calib_samples','fwhm_calib_window'}; ...
    'Kymograph / Movie Output',      {'Cmin','Cmax','nkymo'}; ...
};
write_settings_log(cfg, settings_groups, fullfile(outpath, [fname '_settings.log']));

% Capture the full console output (incl. per-frame debug prints and
% warnings) to a file so failures/gate stats can be grep'd after the run
% instead of relying on the scrollback.
diary off;
diary(fullfile(outpath, [fname '_console.log']));

if exist(ratio_file, 'file')
    mode = 'ratio';
    M   = h5read(ratio_file, '/ratio_raw');
    BT1 = h5read(ratio_file, '/acceptor');
    BT2 = h5read(ratio_file, '/donor');
    disp('NOTE: Running analysis on ratio stack from _ratio_back.h5.');
    disp('      Ratio scaling for display and kymograph uses Cmin/Cmax as set in this script.');
    disp('      For custom registration, masking, or union parameters, run main_ratio_movies.m');
    disp('      first, then re-run main_track_movies.m.');
elseif exist(back_file, 'file')
    dnames = {h5info(back_file).Datasets.Name};
    if any(strcmp(dnames, 'donor'))
        mode = 'two_raw';
        BT1 = h5read(back_file, '/acceptor');
        BT2 = h5read(back_file, '/donor');
        disp('NOTE: Two-channel data found in _back.h5 but no ratio stack (_ratio_back.h5) available.');
        disp('      Tip tracking and diameter analysis will use the acceptor channel only.');
        disp('      For ratio analysis, run FRET-IBRA module 2 first, then re-run main_track_movies.m.');
    else
        mode = 'single';
        if any(strcmp(dnames, 'acceptor_bleach'))
            BT1 = h5read(back_file, '/acceptor_bleach');
            disp('NOTE: Using bleach-corrected/cropped stack (/acceptor_bleach) from _back.h5.');
        else
            BT1 = h5read(back_file, '/acceptor');
            warning('TIGRMUM: /acceptor_bleach not found in %s. Run FRET-IBRA Module 4 first.', back_file);
        end
        BT2 = [];
    end
    M = BT1;
else
    error('No suitable HDF5 input file found for %s', fname);
end

% Optional spatial upsampling (see run_config.m: `upsample`). Fixed 2x
% bicubic factor -- meant as a quick test of whether more pixels per tube
% (currently only ~10px wide) reduces segmentation/centerline bias, not a
% tunable resolution knob. Halves pixelsize automatically so
% starti/stopi/diamcutoff stay correct in real-world units -- the config
% should still hold the camera's true, native pixelsize either way.
if upsample, up_factor = 2; else, up_factor = 1; end
if up_factor > 1
    BT1 = upsample_stack(BT1, up_factor);
    if ~isempty(BT2), BT2 = upsample_stack(BT2, up_factor); end
    if strcmp(mode, 'ratio'), M = upsample_stack(M, up_factor); end
    if pixelsize > 0, pixelsize = pixelsize / up_factor; end
end

% Rescale data to full 16-bit range if the camera bit depth is less than 16.
% FRET-IBRA stores 12-bit (or other) camera data in uint16 containers without
% expanding the range, so raw values only occupy [0, 2^bit_depth-1].
% Rescaling here makes all downstream code — thresholds, display scaling,
% intensity CSV values — consistent and bit-depth-independent.
% NOTE: intensity values in the CSV will differ from pre-rescaling runs
%       (e.g. x16 higher for 12-bit data); ratios and relative values are unaffected.
bit_max = double(2^16 - 1); % always 65535 after rescaling
if bit_depth < 16 && ~strcmp(mode, 'ratio')
    scale = bit_max / double(2^bit_depth - 1);  % e.g. 65535/4095 ≈ 16 for 12-bit
    BT1 = uint16(double(BT1) .* scale);
    if ~isempty(BT2)
        BT2 = uint16(double(BT2) .* scale);
    end
end

% Zero background for non-ratio modes. Method controlled by threshold_method
% (see run_config.m for which to use for which signal distribution).
if ~exist('otsu_sensitivity', 'var'), otsu_sensitivity = []; end
if fwhm_diameter_correction && strcmp(mode, 'ratio')
    warning('TIGRMUM: fwhm_diameter_correction has no effect in ratio mode (background already handled upstream by FRET-IBRA, signal_threshold never runs) -- disabling for this run.');
    fwhm_diameter_correction = 0;
end
if ~strcmp(mode, 'ratio')
    % Unmasked copy, kept ONLY for the optional FWHM diameter calibration
    % below (see fwhm_diameter_correction) -- signal_threshold's own masking
    % just below zeroes out everything outside the segmented region, so
    % this is the last point where real background-level intensity (needed
    % for a true half-max crossing, not a threshold-dependent mask edge)
    % is still available. Same stack TIGRMUM itself tracks on (post-crop,
    % post-background-subtraction, post-bleach-correction) -- confirmed on
    % real data (HV208_100) that FRET-IBRA's own processing doesn't move
    % the FWHM measurement at all (differences <0.001um across three test
    % frames), so calibrating against this stack isolates just the
    % threshold-method bias, which is what this correction targets.
    if fwhm_diameter_correction, M_raw = BT1; end
    for fc = 1:size(BT1,3)
        frm = BT1(:,:,fc);
        BT1(:,:,fc) = frm .* cast(signal_threshold(frm, threshold_method, up_factor, weak_signal, otsu_sensitivity), class(BT1));
    end
    if ~isempty(BT2)
        for fc = 1:size(BT2,3)
            frm = BT2(:,:,fc);
            BT2(:,:,fc) = frm .* cast(signal_threshold(frm, threshold_method, up_factor, weak_signal, otsu_sensitivity), class(BT2));
        end
    end
    M = BT1;
end

% Orient image
type = find_orient(M(:,:,1));
        
% Scaled plot of the growing tube with tip and ROI
if (tip_plot == 1) && (video_intensity ~= 2)
    V = VideoWriter([outpath '/' fname '_growth.mp4'], 'MPEG-4');
    V.FrameRate = 100;
    V.Quality = 100; % default (75) visibly ringed/ghosted thin bright features
                      % on the mostly-black background of these small frames
    open(V);
    hdum = figure('visible','off');
    set(hdum, 'Units', 'pixels', 'Position', [100 100 1120 840]); % must match render_growth_frame's fixed size exactly
    imagesc(zeros(size(M,1), size(M,2)));
    fdum = getframe(gcf);
    V_frame_size = size(fdum.cdata);
    close(hdum);
end

% Debug video: real intensity (jet colormap, same orientation as U/F1/F2)
% with the traced centerline and ROI halves overlaid, so the ROI-split
% geometry can be checked directly against the real signal instead of
% inferred from the binary-mask growth video or the un-annotated intensity
% video. Separate from both -- does not touch growth.mp4 or _intensity.avi.
if roi_debug_video && (video_intensity ~= 2)
    % Uncompressed AVI, not MPEG-4: same reasoning as video_processing.m's
    % intensity video -- H.264's chroma subsampling breaks up the thin
    % centerline/ROI-tint overlay into scattered artifacts regardless of
    % Quality setting. This is a debug tool, so fidelity over file size.
    Vroi = VideoWriter([outpath '/' fname '_roi_debug.avi'], 'Uncompressed AVI');
    Vroi.FrameRate = 20;
    open(Vroi);
end

if (nkymo > 0 || video_intensity > 0)
    if strcmp(mode, 'ratio')
        K = M(:,:,:)./Cmax;
        K(isnan(K)) = 0;
        Cmin_tmp = Cmin;
        Cmin = Cmin/Cmax;
        L = bsxfun(@rdivide, bsxfun(@minus, K, Cmin), bsxfun(@minus, 1, Cmin));
        L(L<0) = 0;
        L = uint8(L.*255);
    else
        nz = double(M(M > 0));
        [hc, he] = histcounts(nz, 1024);
        cdf = cumsum(hc) / numel(nz);
        Mmax = he(find(cdf >= 0.999, 1));
        L = uint8(double(M)./Mmax.*255);
        Cmin_tmp = 0; Cmin = 0; Cmax = Mmax;
    end
end

% Make a movie and output min and max intensities of the whole stack
if (video_intensity > 0) && ~strcmp(mode, 'two_raw')
    if strcmp(mode, 'single')
        video_processing(outpath,fname,stp,smp,frame_rate,L(:,:,stp:smp),Cmin,Cmin_tmp,Cmax,'_intensity');
    else
        video_processing(outpath,fname,stp,smp,frame_rate,L(:,:,stp:smp),Cmin,Cmin_tmp,Cmax);
    end
end
if (video_intensity == 2), return; end

% Reference-frame sanity check: diamo/U_smp/the whole tip_final_last chain
% get calibrated off whichever frame is processed first (count==smp), on
% the assumption that it's the stack's best, most fully-grown frame. If
% THAT frame's own mask doesn't reach the tracking border, everything
% calibrated from it is unreliable -- confirmed on HV198_1_16 3050-3349:
% frame 3349 (the configured smp) measured only 4px wide right at the
% border-crossing column against a 15px true tube width, and its own tip
% ended up on the opposite end of the tube from every neighbouring frame,
% poisoning the tip_final_last chain for the whole surrounding stretch
% (every later frame's genuinely-correct tip looked like an implausible
% jump relative to this bad reference and got rejected). Walk backward
% from the configured smp (same direction and mask-building steps the
% main loop itself uses, just without the full per-frame pipeline) until
% a frame's mask actually reaches the border, and use THAT as the real
% reference -- frames between the original smp and this one are skipped
% entirely rather than analysed against a reference that was never valid.
smp_orig = smp;
smp_found = false;
for probe = smp:-1:stp
    Op = M(:,:,probe);
    if (type == 1) Op = imrotate(Op,-90);
    elseif (type == 3) Op = imrotate(Op,90);
    elseif (type == 4) Op = imrotate(Op,180);
    end
    if strcmp(mode, 'ratio')
        Pp = imbinarize(Op, 0.2);
    else
        Pp = Op > 0;
    end
    Up = bwareafilt(bwareaopen(Pp, round(100 * up_factor^2)), 1);
    Up = bwmorph(Up, 'clean');
    Up = medfilt2(Up);
    rp_probe = regionprops(Up, 'Area', 'MajorAxisLength');
    if ~isempty(rp_probe) && rp_probe(1).MajorAxisLength > 0
        close_r_probe = max(1, round((rp_probe(1).Area / rp_probe(1).MajorAxisLength) * 0.15));
    else
        close_r_probe = round(2 * up_factor);
    end
    Up = imclose(Up, strel('disk', close_r_probe));
    Up = bwareafilt(Up, 1);
    % Border-touch alone isn't sufficient: weak_signal's own edge-fragment
    % reconnect (signal_threshold.m) can patch a thin sliver onto the
    % border even when the frame's real cross-section there is nowhere
    % near the tube's actual width -- confirmed on HV198_1_16 3349 itself,
    % which technically touches the border under weak_signal=1 but only at
    % 4px wide against a 15px true width. Cross-check the border-column
    % width against the whole-mask Area/MajorAxisLength estimate (same
    % width proxy used for diamo's own cross-check) and require rough
    % agreement, not just binary contact.
    border_ok = any(Up(:,end));
    if border_ok
        border_rows = find(Up(:, size(Up,2)-1));
        if ~isempty(border_rows)
            gaps_p = find(diff(border_rows) > 1);
            run_starts_p = [border_rows(1); border_rows(gaps_p+1)];
            run_ends_p = [border_rows(gaps_p); border_rows(end)];
            border_width = max(run_ends_p - run_starts_p) + 1;
        else
            border_width = 0;
        end
        axis_width = 0;
        if ~isempty(rp_probe) && rp_probe(1).MajorAxisLength > 0
            axis_width = rp_probe(1).Area / rp_probe(1).MajorAxisLength;
        end
        if axis_width > 0 && border_width < 0.5 * axis_width
            border_ok = false;
        end
    end
    if border_ok
        smp = probe;
        smp_found = true;
        break;
    end
end
if ~smp_found
    error('TIGRMUM: no frame between smp=%d and stp=%d has a mask reaching the tracking border -- cannot calibrate a reference.', smp_orig, stp);
end
if smp ~= smp_orig
    fprintf('NOTE: configured smp=%d does not touch the tracking border -- using smp=%d as the reference instead (frames %d-%d skipped).\n', ...
        smp_orig, smp, smp+1, smp_orig);
end

% Loop backwards over stack
if (distributions), d = 1; end
U_prev = [];
right_anchor_row_last = []; % weak_signal border-extension continuity, see below
frames_since_base_walk = 0; % ringwalk_seed_from_tip only: forces a full base-anchored
                            % ring_walk_tip walk every ringwalk_reanchor_interval frames
last_iter_failed = false; % ringwalk_seed_from_tip only, belt-and-suspenders: tip_final_last
                            % itself is now only ever updated on a GOOD frame (see
                            % frames_since_last_good below), so this shouldn't be load-bearing
                            % any more, but costs nothing to keep as an extra guard against a
                            % seeded walk trusting a just-failed frame's neighborhood.
frames_since_last_good = 1; % tip_final_last holds the LAST GOOD (non-frame_failed) tip, not
                            % just the previous frame's -- a failed frame still needs SOME
                            % numeric tip_final(count,:) for downstream ROI/video code, but
                            % that value must never become the comparison baseline for the
                            % NEXT frame's own jump check. Confirmed needed: without this, one
                            % genuinely bad frame (11, ring_walk_tip teleporting to ~[174 389])
                            % got its bad position propagated forward as tip_final_last, which
                            % then made the FOLLOWING frame's own perfectly correct tip
                            % (~[70 67], matching its real neighbors) look like a huge jump
                            % relative to that contaminated reference -- a real, correctly-
                            % tracked frame flagged as collateral damage from a different
                            % frame's failure. The jump-check threshold scales by this counter
                            % (max_tip_jump_um * frames_since_last_good) so comparing against
                            % an N-frames-stale reference allows roughly N frames' worth of
                            % real growth, not a single frame's budget.
frame_failed = false(smp, 1);
% ringwalk_fallback_to_skeleton only: records whether this frame's tip
% jump-check recovery used the skeleton_tip_fallback candidate (whether or
% not that candidate ultimately passed the jump check) -- lets the CSV
% distinguish "fallback tried and failed" from "fallback never applicable"
% (e.g. tip_method='skeleton', or the frame never failed the jump check).
tip_recovered_via_skeleton = false(smp, 1);
% Per-frame triage flag (weak_signal only): does THIS frame's own plain
% segmentation look severed/noisy/border-touch-failed, reusing the same
% severed/noisy/border-touch-rate criteria used all session to triage
% whole stacks, now applied per-frame. Frames flagged here get a shot at
% the forward repair pass below (see after the main loop); everything
% else is left exactly as the plain reverse pass produced it.
needs_repair = false(smp, 1);
% Cache the plain mask for any frame flagged below, so the forward repair
% pass (after this loop) can repair it without re-deriving it from scratch.
% Only populated for flagged frames -- cheap even on long stacks, since
% most frames aren't flagged.
U_cache = cell(smp, 1);
if ~exist('V_frame_size','var'), V_frame_size = []; end
Vroi_frame_size = [];
% Buffered (not streamed) video frames: growth.mp4/roi_debug.avi content is
% held here per-frame and only actually written to disk in one final pass,
% after the forward repair pass, so a repaired frame's video content can be
% re-rendered from its corrected data first. See the render_growth_frame/
% render_roi_debug_frame local functions and the flush loop after the main
% loop below.
growth_buf = cell(smp, 1);
roi_buf = cell(smp, 1);
tip_final    = NaN(smp, 2);
diamf_avg    = NaN(1, smp);
fwhm_calib_mask_px = []; fwhm_calib_fwhm_px = []; % see fwhm_diameter_correction
fwhm_calib_pass_frame = []; fwhm_calib_pass_n = []; % per-pass log, one row per
fwhm_calib_pass_mask_med = []; fwhm_calib_pass_fwhm_med = []; fwhm_calib_pass_ratio = []; % calibration pass -- see fwhm_diameter_correction
Ucount       = NaN(1, smp);
intensityM   = NaN(1, smp);
intensityM_F = NaN(1, smp);
Fpixelnum    = NaN(1, smp);
intensityB1_F  = NaN(1, smp);
intensityB2_F  = NaN(1, smp);
intensityM_F1  = NaN(1, smp);
intensityM_F2  = NaN(1, smp);
F1pixelnum     = NaN(1, smp);
F2pixelnum     = NaN(1, smp);
intensityB1_F1 = NaN(1, smp);
intensityB2_F1 = NaN(1, smp);
intensityB1_F2 = NaN(1, smp);
intensityB2_F2 = NaN(1, smp);
warning('off', 'MATLAB:nearlySingularMatrix');
for count = smp:-1:stp
    disp(['Image Analysis:' num2str(count)]);
    % Widens all three DIAGNOSTIC BLOCKs below beyond just smp/smp-1 -- see
    % debug_frame_range's own doc near the top of this file.
    dump_diag = debug_mode && (count == smp || count == smp - 1 || ...
        (~isempty(debug_frame_range) && count >= debug_frame_range(1) && count <= debug_frame_range(2)));
    try
    O = M(:,:,count);

    if (type == 1) O = imrotate(O,-90);
    elseif (type == 3) O = imrotate(O,90);
    elseif (type == 4) O = imrotate(O,180);
    end

    if fwhm_diameter_correction && exist('M_raw', 'var')
        O_raw = double(M_raw(:,:,count));
        if (type == 1) O_raw = imrotate(O_raw,-90);
        elseif (type == 3) O_raw = imrotate(O_raw,90);
        elseif (type == 4) O_raw = imrotate(O_raw,180);
        end
    end

    if strcmp(mode, 'ratio')
        P = imbinarize(O, 0.2);
    else
        P = O > 0;  % background already zeroed in pre-loop via signal_threshold; no second threshold needed
    end
    se = strel('disk',10);
    se2 = strel('disk',1);
    % Strip small disconnected noise specks before anything downstream can
    % bridge them into the tube. This used to be dead code -- U was
    % immediately overwritten from raw P, discarding both the imopen and
    % bwareaopen results -- so isolated stray pixels near the tube (e.g. a
    % single noise pixel a few rows from the true edge) survived into the
    % gap-repair/imclose stage, where imclose's dilate step could fuse them
    % into the tube's connected component before bwareafilt ever got a
    % chance to tell them apart (verified on HV197_4_19 frame 2015: a lone
    % stray pixel 4 rows from the tube edge at column 117 got bridged in by
    % imclose, thickening the tube's border by ~2px over the last 4 columns
    % approaching the crop edge).
    U_open = bwareaopen(P, round(100 * up_factor^2));

    % diamo_est: computed here (moved up from where close_r used to derive
    % it) because the blob-keep-and-bridge step just below needs it too --
    % it has to run at THIS point (right after bwareaopen), not only after
    % imclose, because bwareafilt(U_open,1) would otherwise already have
    % discarded a genuine tube fragment before the later imclose-stage
    % check ever got a chance to see it.
    if exist('diamo','var')
        diamo_est = diamo;
    else
        rp_close = regionprops(U_open, 'Area', 'MajorAxisLength');
        if ~isempty(rp_close) && rp_close(1).MajorAxisLength > 0
            diamo_est = rp_close(1).Area / rp_close(1).MajorAxisLength;
        else
            diamo_est = 2 * up_factor;
        end
    end

    if weak_signal
        U_smp_for_check = [];
        if exist('U_smp', 'var'), U_smp_for_check = U_smp; end
        U = keep_and_bridge_blobs(U_open, diamo_est, U_smp_for_check, debug_mode, count);
    else
        U = bwareafilt(U_open,1);
    end

    % Per-frame repair triage (weak_signal only): reuse the severed/noisy/
    % border-touch-fail criteria used all session to triage whole stacks,
    % now applied per-frame. This pass stays fully plain regardless of the
    % result -- flagged frames get a shot at the forward repair pass after
    % this loop (see below); nothing here changes what THIS pass computes.
    if weak_signal
        cc_open = bwconncomp(U_open);
        comp_areas = cellfun(@numel, cc_open.PixelIdxList);
        severed = false; noisy = false;
        if numel(comp_areas) >= 3
            noisy = true;
        elseif numel(comp_areas) == 2
            sorted_areas = sort(comp_areas, 'descend');
            if sorted_areas(2) >= 0.2 * sorted_areas(1)
                severed = true;
            end
        end
        border_fail = ~any(U(:,end)) && ~isempty(U_prev) && any(U_prev(:,end));
        needs_repair(count) = severed || noisy || border_fail;
        if debug_mode && needs_repair(count)
            fprintf('  needs_repair F%d: severed=%d noisy=%d(n=%d) border_fail=%d\n', ...
                count, severed, noisy, numel(comp_areas), border_fail);
        end
    end

    U = bwmorph(U,'clean');
    U = medfilt2(U);
    % Closing radius scaled to the tube's own measured width (diamo) rather
    % than a fixed pixel count: a fixed radius (originally disk(10), unchanged
    % since the very first commit) is only appropriate for whatever
    % magnification/binning produced that many pixels per tube-diameter --
    % on a narrower image (e.g. 40x + 1.6x vs 20x) the same radius is
    % disproportionately large relative to the tube and permanently fills in
    % concave bends during the dilate step (verified on HV197_4_19 frame
    % 2042: disk(10) added 81px at the tube's elbows vs 2px for disk(1)).
    % diamo isn't calibrated yet on the very first (smp) frame -- estimate a
    % rough width directly from this frame's own current mask instead of a
    % blind small constant. Area/MajorAxisLength (same width proxy already
    % used for signal_threshold.m's corridor sizing and diamo's own
    % cross-check fallback) is whole-shape-based, so it holds up reasonably
    % well even on the not-yet-closed mask, unlike a local column scan.
    % Without this, frame smp got a much smaller close_r than every other
    % frame (which uses the real diamo once known), leaving its boundary
    % under-smoothed relative to its neighbours -- confirmed on 20260327_2:
    % this alone was enough to make bwmorph('thin') throw off many spurious
    % branches on frame smp that branch_removal.m then pruned incorrectly,
    % picking a mid-tube kink instead of the true tip.
    close_r = max(1, round(diamo_est * 0.15));
    U = imclose(U, strel('disk', close_r));
    % weak_signal only: a genuine tube fragment can survive imclose as a
    % SEPARATE component from the main piece rather than actually merging
    % with it -- the two can look connected at low zoom without truly
    % being one component. Plain bwareafilt(U,1) then keeps only whichever
    % piece has more total pixels and silently discards the other,
    % regardless of size -- confirmed on HV198_1_16 frame 3321: a bright,
    % well-formed GCaMP tip blob (1121px, comparable width to the rest of
    % the tube) got discarded outright because the dimmer shank piece
    % happened to have slightly more pixels. Instead of keeping only the
    % single largest piece, keep every component that looks like a real
    % tube fragment -- width comparable to diamo (not a thin noise sliver,
    % not a blob much wider than the tube), elongated along its own axis
    % (not round/blobby noise), and overlapping the reference mask (so it
    % sits where the tube is actually expected to be) -- then bridge the
    % survivors into one connected mask, corridor width scaled to diamo
    % (same 0.15 factor close_r uses) so filling the gap can't balloon
    % past the tube's own real width.
    if weak_signal
        U_smp_for_check = [];
        if exist('U_smp', 'var'), U_smp_for_check = U_smp; end
        U = keep_and_bridge_blobs(U, diamo_est, U_smp_for_check, debug_mode, count);
    else
        U = bwareafilt(U, 1);
    end
    U_prev = U;
    if weak_signal && count == smp
        U_smp_raw = U;
        U_smp_border_rows = find(U(:,end));
    end

    if (count == smp) Ub = logical(ones(size(P)));
    else Ub = U;
    end
        
    Urat = and(U,Ub);
    Ucount(count) = nnz(Urat)/nnz(U);
    if (Ucount(count) < 0.95 || count == smp) last_flag = 0;
    else last_flag = 1;
    end
    
    if weak_signal && ~any(U(:,end))
        % No signal reaches the tracking border at all this frame --
        % signal_threshold.m's edge-fragment preservation can't help here,
        % since there's genuinely nothing there to preserve (verified on
        % HV198_1_16 3185-3301: 30 of 48 border-touching failures had zero
        % raw signal near the border, not just a discarded small fragment).
        % Extend U so the border-closing step just below (which assumes
        % U(:,end) has at least one true pixel, and otherwise silently does
        % nothing -- Umax/Umin come back empty and drawline is a no-op) has
        % something to work with.
        %
        % Anchor to the LAST frame's actual border row (right_anchor_row_last),
        % not whichever row this frame's own already-degraded mask happens to
        % end nearest to. The latter is essentially arbitrary and has no
        % memory of the previous frame, which made right_anchor (and the
        % whole per-frame traced centerline anchored on it) visibly jump
        % around frame to frame on these frames specifically, instead of
        % staying as stable as it does whenever the border signal is real.
        [Ur, Uc] = find(U);
        [~, mi] = max(Uc);
        if ~isempty(right_anchor_row_last)
            target_row = min(max(right_anchor_row_last, 1), size(U,1));
            U = drawline(U, Ur(mi), Uc(mi), target_row, size(U,2), true);
        else
            U(Ur(mi), Uc(mi):size(U,2)) = true;
        end
    end
    Umax = max(find(U(:,end)==1)); Umin = min(find(U(:,end)==1));
    U = imfill(drawline(U,Umin,size(U,2),Umax,size(U,2),1),'holes');

    % ---- DIAGNOSTIC BLOCK 1: binarisation pipeline (frames smp and smp-1) ----
    % smp-1 is the SECOND frame processed (loop runs smp:-1:stp), and
    % inherits U_prev/diamo/tip_final_last correctly primed by frame smp --
    % useful for "normal" per-frame debugging. smp itself always starts
    % cold (no U_prev/tip_final_last yet) -- dumped too since the cold-start
    % case has its own failure modes (no continuity to disambiguate a branch
    % choice) that smp-1 can't show. To debug some other frame N, set
    % smp = N+1 (dumps N via the smp-1 branch).
    if dump_diag
        dp = fullfile(outpath, sprintf('diag_%d', count));
        imwrite(mat2gray(double(O)),            [dp '_01_O_raw.png']);
        imwrite(mat2gray(double(L(:,:,count))), [dp '_02_L_display.png']);
        imwrite(P,                              [dp '_03_P_thres.png']);
        Ud1 = bwareaopen(P, round(100 * up_factor^2));
        imwrite(Ud1,                            [dp '_04_U_bwareaopen.png']);
        Ud2 = bwareafilt(Ud1, 1);
        imwrite(Ud2,                            [dp '_05_U_bwareafilt.png']);
        Ud3 = bwmorph(Ud2, 'clean');
        imwrite(Ud3,                            [dp '_06_U_clean.png']);
        Ud4 = medfilt2(Ud3);
        imwrite(Ud4,                            [dp '_07_U_medfilt.png']);
        Ud5 = imclose(Ud4, strel('disk', close_r));
        imwrite(Ud5,                            [dp '_08_U_imclose.png']);
        imwrite(U,                              [dp '_09_U_final.png']);
        disp(['DIAG block 1 saved to ' dp]);
    end
    % ---- END DIAGNOSTIC BLOCK 1 ----

    % Finding the tip-ward reference point (Qef): either via the skeleton +
    % branch-removal (default, unchanged), or via ring_walk_tip.m -- a
    % skeleton-free alternative that never builds a branch-point graph, so
    % it can't inherit branch_removal.m's specific failure mode (a single
    % stray pixel flipping which endpoint survives pruning at a sharp bend
    % -- see ring_walk_tip.m and session notes on HV200_2_24_cropped
    % frames 1482/1500 for the confirmed evidence). Both branches feed the
    % SAME `Qef`, so everything downstream (the ellipse-fit radius search,
    % locate_tip) is unconditional and unaware of which method ran.
    if strcmp(tip_method, 'ringwalk')
        rw_col = size(U,2) - 1;
        rw_pix = find(U(:, rw_col));
        while isempty(rw_pix) && rw_col > 1
            rw_col = rw_col - 1;
            rw_pix = find(U(:, rw_col));
        end
        rw_row = round(mean(rw_pix));
        if ~U(rw_row, rw_col)
            [~, snap] = min(abs(rw_pix - rw_row));
            rw_row = rw_pix(snap);
        end

        % Tip-seeded walk (opt-in, ringwalk_seed_from_tip): start from the
        % PREVIOUS frame's tip instead of always walking the whole tube from
        % the base. Shortens the walk, which reduces exposure to
        % ring_walk_tip's own known failure modes (T-junction misjudgment,
        % false width-collapse stops) -- both scale with walk length, and a
        % full base-to-tip walk exposes every frame to them over the WHOLE
        % tube even though only the last bit actually changed. Confirmed
        % needed: on 20260327_3_cropped frame 11, a full base walk produced
        % a catastrophic tip jump (~100+px row, ~320+px col vs. neighbors)
        % on a frame whose raw image was visually identical to its
        % neighbors -- a pure algorithmic failure exposed by walking the
        % entire tube, not a data problem.
        % Reuses last_flag (Ucount(count)>=0.95, i.e. this frame's mask
        % overlaps the previous one enough to trust it) as the outer gate --
        % same signal the codebase already uses to decide tip_final_last is
        % trustworthy, not a new parallel condition. force_base_walk
        % periodically forces a full walk regardless, to bound slow
        % systematic drift that per-frame jump-checking alone can't catch
        % (each seeded step can look individually fine while still
        % accumulating error over many consecutive seeded frames).
        % last_iter_failed additionally blocks seeding right after a
        % frame_failed frame -- tip_final_last is updated unconditionally
        % (see its assignment below), so without this a single bad seeded
        % result cascades into every subsequent frame instead of being
        % caught and recovered from.
        force_base_walk = (ringwalk_reanchor_interval > 0) && ...
                          (frames_since_base_walk >= ringwalk_reanchor_interval);
        seed_ok = false;
        if last_flag && ringwalk_seed_from_tip && ~force_base_walk && ~last_iter_failed
            % Seed point is NOT tip_final_last itself -- it's offset back
            % (base-ward) from it by ringwalk_seed_offset_factor*diamo along
            % the tube's own local tangent, then snapped to the nearest real
            % mask pixel. This fixes a failure the previous approach (seed
            % exactly at tip_final_last, bias the walk with an estimated
            % direction) never could: seeded exactly at tip_final_last, real
            % per-frame growth (~1px on 20260327_3_cropped) leaves almost no
            % genuine mask beyond it, far short of the ring's own radius
            % (~0.65*diamo) -- so the ring can't even DETECT a tip-ward
            % crossing, finds only the base-ward one, and takes it
            % unconditionally (ring_walk_tip.m: ncomp==1 skips scoring
            % entirely). No direction estimate, however accurate, can fix a
            % choice that never gets made. Seeding further back guarantees
            % real mask on BOTH sides of the first ring, so a genuine
            % tip-ward candidate actually exists to be selected.
            dir_vec = local_tip_tangent(U, tip_final_last, diamo);
            if ~isempty(dir_vec)
                offset_px = ringwalk_seed_offset_factor * diamo;
                seed_float = tip_final_last - offset_px * dir_vec; % step base-ward
                [snap_r, snap_c, snapped] = snap_to_mask(U, seed_float, diamo);
                if snapped
                    sw = max(1, round(diamo));
                    sr0 = max(1, snap_r-sw); sr1 = min(size(U,1), snap_r+sw);
                    sc0 = max(1, snap_c-sw); sc1 = min(size(U,2), snap_c+sw);
                    seed_ok = nnz(U(sr0:sr1, sc0:sc1)) >= 3;
                    if seed_ok, seed_pt = [snap_r, snap_c]; end
                end
            end
        end

        if seed_ok
            % Disambiguate step 1 with a hard rule instead of an estimated
            % direction: this pipeline's own crop convention already
            % guarantees tip-ward = smaller column (every tube enters the
            % crop from the right border -- see the base-anchor scan just
            % above), so directly preferring the smaller-column candidate is
            % both simpler and more robust than scoring against a tangent
            % estimate that can be thrown off by local curvature right at
            % the seed. From step 2 on, ring_walk_tip's own
            % direction-continuity scoring takes over automatically (it
            % always sets prev_dir from the actual observed move after step
            % 1), so this only ever affects the single first-step choice.
            [Qef, rw_walk_path] = ring_walk_tip(U, seed_pt, 'prev_tip', tip_final_last, ...
                'prefer_smaller_col', true, 'max_steps', ringwalk_seed_max_steps);
            if size(rw_walk_path,1) <= 1
                % Seeded walk took zero steps (first ring found nothing) --
                % don't trust it, fall through to a full base-anchored walk
                % for this frame instead.
                seed_ok = false;
                if debug_mode
                    fprintf('  ringwalk F%d: seeded walk took 0 steps -- falling back to base walk\n', count);
                end
            end
        end

        if ~seed_ok
            % Cross-frame continuity, mirroring the skeleton method's own use
            % of tip_final_last/last_flag: gated behind last_flag so it's
            % never referenced before it's actually assigned (count==smp, the
            % cold-start reference frame, always has last_flag==0).
            if last_flag
                Qef = ring_walk_tip(U, [rw_row, rw_col], 'prev_tip', tip_final_last);
            else
                Qef = ring_walk_tip(U, [rw_row, rw_col]);
            end
        end

        % Any base walk (forced, or a seed attempt that fell through) resets
        % the re-anchor counter; a successful seeded walk advances it.
        if seed_ok, frames_since_base_walk = frames_since_base_walk + 1;
        else frames_since_base_walk = 0;
        end
        if debug_mode
            walk_label = 'base'; if seed_ok, walk_label = 'seeded'; end
            fprintf('  ringwalk F%d: %s (frames_since_base_walk=%d)\n', count, ...
                walk_label, frames_since_base_walk);
        end
    else
        % Removing branches from thinned image
        Q = bwmorph(U,'thin',Inf);

        Qe = bwmorph(Q,'endpoints');
        [Qer,Qec] = find(Qe > 0);
        Qel = [Qer Qec];

        Qb = bwmorph(Q,'branchpoints');
        [Qbr,Qbc] = find(Qb > 0);
        if (Qbr > 0)
            Qbf = [Qbr Qbc];
            [Q2, Qef, tmp] = branch_removal(Q,Qbf,Qel,0,1);
        else
            Q2 = Q;
            [tmp,Qepos] = max(Qec);
            Qef = Qel;
            Qef(Qepos,:) = [];
        end
        if isempty(Qef) && ~isempty(Qel)
            % branch_removal iterates over EVERY branch point when
            % angdiff==0 (unlike the S/S2 single-point case below), and on
            % a heavily-branched skeleton can over-prune all the way down
            % to zero endpoints -- its own final "drop the max-column
            % endpoint" step then empties Qef entirely, which crashes
            % locate_tip.m (`major(1,:)` on a 0-row array). Confirmed on
            % HV198_1_16 frame 3271's repaired mask (Q had 3 endpoints,
            % branch_removal still emptied Qef). Qef is only ever used as
            % an approximate seed for locate_tip's own tolerance-growing
            % ellipse search, so falling back to one of the ORIGINAL
            % (pre-debranch) endpoints is a reasonable, safe recovery --
            % better than crashing on an empty seed.
            [~, Qepos] = max(Qel(:,2));
            Qef = Qel(Qepos,:);
        end
    end

    % Manual tip seed override (anchor frame only, count==smp): optional
    % escape hatch for exactly the failure this whole mechanism exists to
    % catch -- the cold-start frame has no prior history to disambiguate a
    % wrong branch/candidate, and since everything downstream (the whole
    % backward walk, ringwalk_seed_from_tip's own seeding) is seeded from
    % here, a bad automated pick on THIS one frame can misdirect the entire
    % stack. Two ways to supply the human-confirmed coordinate:
    %  (a) manual_tip_seed_interactive=1: pop up THIS frame's own raw display
    %      image (straight from L, i.e. the h5 TIGRMUM already has open --
    %      always present, unlike FRET-IBRA's optional *_back_bleach.tif) with
    %      the current mask boundary overlaid for context, and capture a
    %      click via ginput. Needs a live interactive MATLAB session -- ginput
    %      cannot work under `matlab -batch`, so a stack using this must be
    %      run normally (desktop/Command Window), not via the usual batch
    %      invocation.
    %  (b) manual_tip_seed_row/col: pre-supplied coordinates (e.g. read off a
    %      pixel position some other way) -- MUST be in the CROPPED stack's
    %      own coordinate space, i.e. the same [row, col] convention as
    %      Tip_row_px/Tip_col_px in the output CSV (matching diag_<N>_01_O_raw.png,
    %      not the original uncropped acquisition frame or any external
    %      viewer's own crop).
    % Either way, only step in when the algorithm's own Qef disagrees by more
    % than manual_tip_seed_radius_factor*diamo_est -- if it already agrees,
    % leave Qef untouched (both methods' own internal candidate scoring still
    % ran normally either way). When overriding, trust the human coordinate
    % directly rather than anything ring_walk_tip/branch_removal picked,
    % snapped onto the nearest real mask pixel (same snap_to_mask helper the
    % ringwalk seeding path already uses) so Qef always lands on real signal
    % even if the click/coordinate is a pixel or two off the mask.
    manual_pt = [];
    manual_tip_seed_applied = false;
    manual_tip_seed_final_pt = [];
    if count == smp && manual_tip_seed_interactive
        % L (raw display stack) is never rotated in the main loop, unlike
        % O/U (and everything derived from them, including this frame's mask
        % boundary below) -- those go through the same type-conditional
        % imrotate right after find_orient (see O's own rotation a few
        % hundred lines up) so the tube consistently enters from the right,
        % TIGRMUM's internal crop convention. Showing L as-is would display
        % the tube entering from whatever direction it actually was acquired
        % in while overlaying a mask boundary computed in the ROTATED frame
        % -- two different orientations superimposed, useless for clicking.
        % Apply the identical rotation to a local copy before displaying so
        % the raw image and the mask agree, matching what Qef/manual_pt/
        % Tip_row_px all mean.
        Lclick = L(:,:,count);
        if (type == 1) Lclick = imrotate(Lclick,-90);
        elseif (type == 3) Lclick = imrotate(Lclick,90);
        elseif (type == 4) Lclick = imrotate(Lclick,180);
        end

        % Pre-size the figure/axes to the target zoom directly, rather than
        % asking imshow for a magnification and hoping it honors it --
        % imshow's 'InitialMagnification' silently falls back to whatever
        % fits the current figure/screen whenever its own fit logic decides
        % to (confirmed not reliably giving 300% in practice). Building a
        % figure whose pixel size already IS image_size*zoom, with no
        % menu/toolbar stealing pixels, and filling it edge-to-edge with the
        % axes, makes the zoom exact by construction instead of a request
        % imshow is free to override. Clamped to the screen so an unusually
        % large frame can't ask for an off-screen window.
        seed_zoom = 3;
        [img_h, img_w] = size(Lclick);
        screen_sz = get(0, 'ScreenSize'); % [x y width height], px
        max_fig_w = screen_sz(3) - 100; max_fig_h = screen_sz(4) - 150;
        fig_w = img_w * seed_zoom; fig_h = img_h * seed_zoom;
        if fig_w > max_fig_w || fig_h > max_fig_h
            seed_zoom = min(max_fig_w/img_w, max_fig_h/img_h);
            fig_w = img_w * seed_zoom; fig_h = img_h * seed_zoom;
            if debug_mode
                fprintf('  manual_tip_seed F%d: 300%% does not fit on screen -- using %.0f%% instead\n', count, seed_zoom*100);
            end
        end
        fig_seed = figure('Name', sprintf('Click the true tip -- Frame %d', count), ...
            'Units', 'pixels', 'Position', [100 100 fig_w fig_h], ...
            'MenuBar', 'none', 'ToolBar', 'none', 'NumberTitle', 'off', ...
            'CloseRequestFcn', @seed_close_cb);
        movegui(fig_seed, 'center');
        ax_seed = axes('Parent', fig_seed, 'Units', 'normalized', 'Position', [0 0 1 1]);
        imshow(mat2gray(double(Lclick)), 'Parent', ax_seed, 'Border', 'tight');
        hold(ax_seed, 'on');
        Ub_contour = bwboundaries(U);
        for kb = 1:numel(Ub_contour)
            plot(ax_seed, Ub_contour{kb}(:,2), Ub_contour{kb}(:,1), 'y-', 'LineWidth', 1, 'HitTest', 'off');
        end
        title(ax_seed, sprintf('Frame %d (yellow = current mask)', count), 'Color', 'w');
        text(ax_seed, 0.02, 0.05, 'Click to select tip -- press Enter to confirm', ...
            'Units', 'normalized', 'Color', 'w', 'FontSize', 11, 'FontWeight', 'bold', ...
            'BackgroundColor', [0 0 0 0.5], 'VerticalAlignment', 'top', 'HitTest', 'off');

        % The OS 'crosshair'/custom pointer shape renders black on this
        % platform regardless of the PointerShapeCData values passed (a
        % known MATLAB/macOS figure-rendering limitation, not something
        % fixable by tweaking the CData -- confirmed after the white-value
        % (2) CData approach still rendered black). Side-step it entirely:
        % hide the system cursor with a fully transparent bitmap and draw
        % our OWN white crosshair as two line objects that we control
        % directly, updated on every mouse move.
        blank_cdata = NaN(16, 16);
        set(fig_seed, 'Pointer', 'custom', 'PointerShapeCData', blank_cdata, 'PointerShapeHotSpot', [8 8]);
        axis(ax_seed, 'manual'); % lock limits so the crosshair lines don't rescale the view
        xl = xlim(ax_seed); yl = ylim(ax_seed);
        hline = line(ax_seed, xl, [mean(yl) mean(yl)], 'Color', 'w', 'LineWidth', 1, 'HitTest', 'off');
        vline = line(ax_seed, [mean(xl) mean(xl)], yl, 'Color', 'w', 'LineWidth', 1, 'HitTest', 'off');

        % Custom click/confirm loop replaces ginput entirely -- ginput owns
        % the figure's WindowButtonMotionFcn internally while it blocks, so
        % a crosshair driven by our own WindowButtonMotionFcn (needed for
        % the line-based crosshair above) can't coexist with it. State lives
        % in the figure's appdata so the callbacks (plain function handles,
        % not closures) can read/write it across separate invocations.
        % Repeated clicking allowed (each replaces the marker/candidate, not
        % yet committed); Enter confirms whatever was last clicked; closing
        % the window falls back to automatic (see seed_close_cb).
        setappdata(fig_seed, 'manual_pt', []);
        setappdata(fig_seed, 'marker_h', []);
        setappdata(fig_seed, 'confirmed', false);
        set(fig_seed, 'WindowButtonMotionFcn', {@seed_motion_cb, ax_seed, hline, vline});
        set(fig_seed, 'WindowButtonDownFcn', {@seed_click_cb, ax_seed});
        set(fig_seed, 'KeyPressFcn', @seed_key_cb);
        uiwait(fig_seed);

        if ishghandle(fig_seed)
            manual_pt = getappdata(fig_seed, 'manual_pt');
            if ~getappdata(fig_seed, 'confirmed'), manual_pt = []; end
            delete(fig_seed);
        end
        if debug_mode
            if isempty(manual_pt)
                fprintf('  manual_tip_seed F%d: interactive window closed with no confirmed click -- falling back to automatic\n', count);
            else
                fprintf('  manual_tip_seed F%d: interactive click confirmed at [%d,%d]\n', count, manual_pt(1), manual_pt(2));
            end
        end
    elseif count == smp && ~isempty(manual_tip_seed_row) && ~isempty(manual_tip_seed_col)
        manual_pt = [manual_tip_seed_row, manual_tip_seed_col];
    end

    if ~isempty(manual_pt)
        % Always trust the human-confirmed point outright -- this is a
        % deliberate correction, not a suggestion to weigh against the
        % algorithm's own judgment. manual_tip_seed_radius_factor bounds how
        % far the SNAP may search from the raw point, not whether the
        % override happens at all -- an earlier version incorrectly gated
        % the whole override behind "is the algorithm's own Qef already
        % close enough," which silently discarded the human's click whenever
        % the algorithm's own (possibly still wrong) pick happened to land
        % within that radius purely by chance.
        %
        % Snap to the nearest BOUNDARY pixel, not the nearest interior mask
        % pixel: tip_final is a point on boundb (the traced mask contour,
        % same object locate_tip's tip_ellipsef is drawn from) on every
        % other frame, so a manually-set tip must land on that same contour
        % to stay consistent with everything downstream that treats "the
        % tip" as a border point (dsearchn against boundb, arc-length
        % centerline anchoring, ROI/cap construction). A plain find(U) hit
        % is a real mask pixel but very likely interior, not on the PT
        % border -- confirmed wrong by inspection, not just in theory.
        radius_px = manual_tip_seed_radius_factor * diamo_est;
        Ub_bounds = bwboundaries(U);
        if ~isempty(Ub_bounds)
            Ub_pts = cell2mat(Ub_bounds); % vertcat all boundary points, [row col]
            d = hypot(double(Ub_pts(:,1))-manual_pt(1), double(Ub_pts(:,2))-manual_pt(2));
            [dmin, k] = min(d);
        else
            dmin = Inf;
        end
        if isfinite(dmin) && dmin <= radius_px
            snap_r = Ub_pts(k,1); snap_c = Ub_pts(k,2);
            if debug_mode
                fprintf('  manual_tip_seed F%d: overriding algorithm Qef=[%d,%d] with human point [%d,%d] -> border pt [%d,%d] (%.1fpx away)\n', ...
                    count, Qef(1), Qef(2), manual_pt(1), manual_pt(2), snap_r, snap_c, dmin);
            end
            Qef = [snap_r, snap_c];
            manual_tip_seed_applied = true;
            manual_tip_seed_final_pt = [snap_r, snap_c];
        elseif debug_mode
            fprintf('  manual_tip_seed F%d: no mask border found within %.1fpx of manual point [%d,%d] (nearest was %.1fpx) -- keeping algorithm Qef=[%d,%d]\n', ...
                count, radius_px, manual_pt(1), manual_pt(2), dmin, Qef(1), Qef(2));
        end
    end

    if dump_diag
        prev_tip_str = 'none';
        if exist('tip_final_last', 'var'), prev_tip_str = mat2str(tip_final_last); end
        fprintf('  Qef F%d: [%d,%d] (seed for locate_tip; tip_final_last=%s)\n', count, Qef(1), Qef(2), prev_tip_str);
    end

    % Finding the radius for ellipse fitting
    tols = 0; rad=1;
    while (tols == 0)
        sides = false; connect = false;
        try
            K = U(Qef(1)-rad:Qef(1)+rad,Qef(2)-rad:Qef(2)+rad);
        catch
            rad = 100;
            tols = 40;
            break;
        end
        Ke = [K(:,1)' K(end,2:end) K(end-1:-1:1,end)' K(1,end-1:-1:2)];
        Kd = diff(Ke);
        Kd(end+1) = Ke(1) - Ke(end);
        if (nnz(Kd) == 2) connect = true; end
        Ks = [sum(K(:,1)) sum(K(1,:)) sum(K(:,end)) sum(K(end,:))];
        if (nnz(Ks) <= 2)
            bou = bwboundaries(K);
            if ~isempty(bou)
                Kb = bou{1};
                Kbl = [find(Kb(:,1) == 1); find(Kb(:,2) == 1); find(Kb(:,1) == size(K,1)); find(Kb(:,2) == size(K,1))];
                if (size(Kbl,1) < size(K,1)) sides = true; end
            end
        end
        if(connect == true && sides == true) tols = rad; end
        rad = rad + 1;
    end

    % Cap the ellipse-fit search radius at 2*diamo (roughly two tube-widths)
    % instead of letting it silently grow to the whole image diagonal: a
    % flattened tip (e.g. pressed against a PDMS wall) gives ellipse_data a
    % near-collinear point cloud that fails the isreal(axes) check, so the
    % old unbounded loop kept expanding until it happened to reach whatever
    % curved feature was fittable next -- often a nascent side outgrowth
    % well past the actual tip, which is why tip_final was seen wiggling
    % between the flat wall-contact region and that outgrowth frame to
    % frame. Falls back to last frame's tip (more trustworthy than the raw
    % seed, which is what triggered the failed fit in the first place) when
    % available; diamo_est covers the very first frame, before diamo itself
    % is frozen.
    fb_pt = [];
    if exist('tip_final_last', 'var'), fb_pt = tip_final_last; end
    max_jump_px = ellipse_candidate_max_jump_factor * diamo_est; % see its own doc near the top of this file
    [boundb, tip_ellipse, tip_new, tip_check, diam, maxy, center, phin, axes, stats, edges] = locate_tip(U, tols, Qef, 2*diamo_est, fb_pt, max_jump_px, ellipse_fit_method);
    % locate_tip/edge_quant measures diam at a single column (maxy-1, the
    % tube's crossing into the crop) -- that one column can read
    % artificially low on a frame-specific segmentation quirk (a marginal
    % pixel dropout, a slightly different crossing angle) even when the
    % tube itself looks completely normal, since nothing else about the
    % frame feeds into it. Overwrite with the same robust multi-column
    % estimate used for the frozen diamo reference below (see
    % robust_diam), so the diam_tol check compares like-for-like instead
    % of a robust reference against one noisy per-frame sample. Confirmed
    % false-positive on 20260327_3_cropped frames 53/57: diam=19px vs
    % diamo=45px flagged both as failures, but growth.mp4 shows nothing
    % unusual at either frame.
    diam = robust_diam(U, size(U,2) - 1, diam, count, debug_mode);
    tip_ellipsepos = dsearchn(boundb,tip_ellipse);
    tip_ellipsef = boundb(tip_ellipsepos,:);
    % Reset every iteration (not auto-cleared by the loop) so the
    % tip-jump-recovery check below can reliably tell whether tip_skel/
    % tip_mid were actually computed THIS frame via isempty(), rather than
    % reading stale values left over from an earlier iteration that didn't
    % take the same code path.
    tip_skel = []; tip_mid = [];

    if strcmp(tip_method, 'skeleton')
        % Skeletonizing and finding endpoints
        S = bwmorph(U,'skel',Inf);
        Se = bwmorph(S,'endpoints');
        [Ser,Sec] = find(Se > 0);
        Sel = [Ser Sec];

        % Skeltonizing and finding branchpoints
        Sb = bwmorph(S,'branchpoints');
        [Sbr,Sbc] = find(Sb > 0);
        Sbl = [Sbr Sbc];
    end

    if (count == smp)
        % diam is already the robust multi-column estimate by this point
        % (see robust_diam, applied right after locate_tip above) -- the
        % frozen reference is just that same value, no separate column-scan
        % needed here anymore.
        diamo = diam;
        if debug_mode
            fprintf('  diamo F%d: using robust diam=%.1fpx as frozen reference\n', count, diamo);
        end
        % weak_signal only: finalize the reference mask now that diamo is
        % known -- heavily smoothed (despike+debay, same operation as every
        % other frame gets, just using this frame's own newly-measured
        % diamo since close_r/ws_smooth_r aren't set yet this early in the
        % very first iteration) so it's a clean template for every other
        % frame to crop against, not a noisy one. "The reference frame
        % needs to be touching the right border" -- checked explicitly and
        % restored via a corridor to its own pre-smoothing border row if
        % smoothing ever strips it (verified this happens in practice: an
        % opening large enough to despike can erode away a thin
        % border-touching strip).
        if weak_signal && exist('U_smp_raw', 'var')
            ws_smooth_r = max(1, round(diamo * 0.3));
            U_smp = imclose(U_smp_raw, strel('disk', ws_smooth_r));
            U_smp = imopen(U_smp, strel('disk', ws_smooth_r));
            U_smp = bwareafilt(U_smp, 1);
            if ~any(U_smp(:,end)) && ~isempty(U_smp_border_rows)
                anchor_row = round(median(U_smp_border_rows));
                [Ur, Uc] = find(U_smp);
                [~, mi] = max(Uc);
                corridor = false(size(U_smp));
                corridor = drawline(corridor, Ur(mi), Uc(mi), anchor_row, size(U_smp,2), true);
                corridor = imdilate(corridor, strel('disk', up_factor));
                U_smp = U_smp | corridor;
            end
            if debug_mode
                fprintf('  U_smp: raw_px=%d smoothed_px=%d touches_border=%d ws_smooth_r=%d\n', ...
                    nnz(U_smp_raw), nnz(U_smp), any(U_smp(:,end)), ws_smooth_r);
                % Dedicated dump for the reference frame itself (count==smp)
                % -- everything else derives from this, so it needs to be
                % checkable directly rather than only via the smp-1
                % diagnostic block below (which is frame smp-1, not smp).
                dp_ref = fullfile(outpath, sprintf('diag_%d_refmask', count));
                imwrite(U_smp_raw, [dp_ref '_00_U_smp_raw.png']);
                imwrite(U_smp,     [dp_ref '_01_U_smp_smoothed.png']);
            end
        end
    end

    % Sanity-check this frame's own diameter against the frozen reference.
    % If this frame's diam deviates too far from diamo, either this frame's
    % segmentation is anomalous, or diamo itself (frozen from a single
    % frame) was a bad reference to begin with -- either way, downstream
    % thresholds built on diamo are unreliable for this frame.
    diam_tol = 2; % flag if diam is more than 2x larger or smaller than diamo
    if (diam < diamo/diam_tol) || (diam > diamo*diam_tol)
        frame_failed(count) = true;
        if debug_mode
            fprintf('  diam F%d: diam=%.1fpx vs diamo=%.1fpx -- flagged, results NaN''d\n', count, diam, diamo);
        end
    end

    if strcmp(tip_method, 'ringwalk')
        % ring_walk_tip.m already produced a single, safeguarded candidate
        % (Qef) -- no branch ambiguity to vote between, so just take
        % locate_tip's local ellipse-fit refinement of it directly.
        tip_final(count,:) = tip_ellipsef;
        if debug_mode
            fprintf('  tip F%d: ringwalk -> ellipsef\n', count);
        end
    else
    if isempty(Sbl)
        % Skeleton is a simple unbranched path — select tip endpoint directly
        S2 = S; S2area = 1;
        [~, base_pos] = max(Sel(:,2));
        Sef = Sel; Sef(base_pos,:) = [];
    else
        % Find branch point closest to thin edge
        if (last_flag == 0) Sbf = Sbl(dsearchn(Sbl,Qef),:);
        else [tmp, Sbmin] = min(pdist2(Sbl,tip_final_last) + pdist2(Sbl,Qef));
            Sbf = Sbl(Sbmin,:);
        end

        % Try and remove branches within some parameters
        close_dist = 0;
        if (pdist2(Qef,Sbf) > weight*diamo) close_dist = 1; end
        if (weight == 0) kill_angle = 0;
        else kill_angle = 75;
        end
        if debug_mode
            fprintf('  weight F%d: seed-to-branchpt=%.1fpx vs weight*diamo=%.1fpx (weight=%.2f) -> close_dist=%d\n', ...
                count, pdist2(Qef,Sbf), weight*diamo, weight, close_dist);
        end
        [S2,Sef,S2area] = branch_removal(S,Sbf,Sel,kill_angle,close_dist);
    end

    % If more than 2 branches, further evaluation is needed
    if (size(Sef,1) > 1)
        % branch_removal.m's single Sbf-targeted prune can occasionally
        % leave 3+ candidates instead of 2 -- the voting/tip_mid logic
        % below is built around exactly 2 (tip_choice is always a
        % 2-element vector from Sef(1,:)/Sef(2,:)). Narrow to the two
        % closest to the ellipse fit first so choice always stays in
        % bounds. Confirmed crash otherwise: HV203_1_11 frame 613,
        % "Index exceeds the number of array elements. Index must not
        % exceed 2." -- Sef had 3 rows, skel_ellipsepos (an index into
        % all of Sef) came back as 3, and tip_choice(3) doesn't exist.
        if size(Sef,1) > 2
            d_to_ellipse = pdist2(Sef, tip_ellipsef);
            [~, order] = sort(d_to_ellipse);
            Sef = Sef(order(1:2),:);
        end
        % Voting to decide which branch to be chosen as closer to the tip.
        % When a continuity reference exists, trust it directly rather than
        % blending in skel_ellipsepos -- the old (skel_lastpos+skel_ellipsepos+1)>4
        % formula only returns 2 when BOTH signals agree on candidate 2; every
        % other combination, including skel_lastpos=2/skel_ellipsepos=1,
        % silently collapses to 1, discarding a correct continuity match
        % whenever tip_ellipsef (unreliable right where a branch sits closer
        % to Qef than half the tube's own width -- see F5200) disagrees.
        [tmp, skel_ellipsepos] = min(pdist2(Sef,tip_ellipsef));
        if (last_flag == 1)
            [tmp, skel_lastpos] = min(pdist2(Sef,tip_final_last));
            choice = skel_lastpos;
        else
            choice = skel_ellipsepos;
        end

        tip_choice = [dsearchn(boundb,Sef(1,:));dsearchn(boundb,Sef(2,:))];
        if (min(tip_choice) == tip_choice(2)) S2area = 1/S2area; end
        tip_skelpos = tip_choice(choice);
        tip_skel = boundb(tip_skelpos,:);

        % Finding the middle of both branches if they exist
        cn = 0; tip_angle = [];
        for i = min(tip_choice):max(tip_choice)
            cn = cn+1;
            tip_angle(cn) = atan2((boundb(i,2) - Sbf(2)),(boundb(i,1) - Sbf(1)));
            if (pi - abs(max(tip_angle)) < abs(min(tip_angle)))
                if (tip_angle(cn) < 0) tip_angle(cn) = 2*pi + tip_angle(cn); end
            end
        end
        target_angle = (tip_angle(1) + tip_angle(end)*S2area)/(S2area+1);

        tip_anglediff = abs(tip_angle - target_angle);
        [tmp, tip_anglepos] = min(tip_anglediff);
        tip_midpos = tip_anglepos+min(tip_choice)-1;
        tip_mid = boundb(tip_midpos,:);

        if last_flag
            % Continuity-first branch choice (2026-09-16): with a trusted
            % previous tip available, simply pick whichever of this frame's
            % three candidates (ellipsef/skel/mid) is closest to it -- a
            % direct, physically-grounded criterion. Replaces the previous
            % topology-range-first logic (a tip_ellipsepos-in-range check,
            % falling back to a distance vote only between skel/mid, with
            % ellipsef only ever compared against skel, never against mid).
            % That logic could still pick the wrong side of a PERSISTENT
            % fork: confirmed on HV200_4_5 F5150-5162, a stretch where
            % branchpt=1 held true for many consecutive frames (a real,
            % sustained branch/bulge next to the tip, not per-frame noise)
            % -- the topology range self-consistently "passed" most frames
            % regardless of which branch it was actually tracking, so the
            % accepted point flip-flopped between the true tip and the
            % neighboring branch frame to frame, each individual flip small
            % enough to look locally plausible. Comparing all three
            % candidates against tip_final_last on equal footing, unweighted,
            % is what topo_ok/continuity_ok's own doc already identified as
            % the fix needed for the narrower HV209_62 F3214 case (skel vs
            % ellipsef only); this generalizes it to all three candidates.
            cand_branch = tip_ellipsef; cand_branch_label = {'ellipsef'};
            if ~isempty(tip_skel), cand_branch = [cand_branch; tip_skel]; cand_branch_label{end+1} = 'skel'; end
            if ~isempty(tip_mid),  cand_branch = [cand_branch; tip_mid];  cand_branch_label{end+1} = 'mid';  end
            cand_branch_dist = pdist2(cand_branch, tip_final_last);
            [~, branch_best_idx] = min(cand_branch_dist);
            if vote_ellipse_first, branch_best_idx = 1; end % cand_branch(1,:) is ellipsef -- see vote_ellipse_first's doc
            tip_final(count,:) = cand_branch(branch_best_idx,:);
            if debug_mode
                fprintf('  tip F%d: branchpt=%d branched choice=%d ellipsepos=%d -> %s (closest to tip_final_last=[%d %d]; dist ellipsef=%.1f skel=%.1f mid=%.1f)\n', ...
                    count, ~isempty(Sbl), choice, tip_ellipsepos, cand_branch_label{branch_best_idx}, ...
                    tip_final_last(1), tip_final_last(2), pdist2(tip_ellipsef,tip_final_last), ...
                    pdist2(tip_skel,tip_final_last), pdist2(tip_mid,tip_final_last));
            end
        else
            % Cold start (no previous tip to lean on, e.g. the very anchor
            % frame) -- continuity has nothing to compare against, so fall
            % back to the topology-range check as the only available signal.
            % Tolerance absorbs per-frame boundary-tracing noise: boundb is
            % rebuilt from scratch each frame via bwboundaries, so the same
            % index can land a few units off between frames even when the
            % ellipse-fit tip itself hasn't moved.
            tip_range_tol = 2;
            topo_ok = (tip_ellipsepos>min(tip_choice)-tip_range_tol && tip_ellipsepos<max(tip_choice)+tip_range_tol);
            if topo_ok
                tip_final(count,:) = tip_ellipsef;
                if debug_mode
                    fprintf('  tip F%d: branchpt=%d branched choice=%d ellipsepos=%d in [%d,%d] margin=%d -> ellipsef\n', ...
                        count, ~isempty(Sbl), choice, tip_ellipsepos, min(tip_choice), max(tip_choice), ...
                        min(tip_ellipsepos-min(tip_choice), max(tip_choice)-tip_ellipsepos));
                end
            else
                tip_ellipsedist = [pdist2(tip_ellipsef,tip_mid) pdist2(tip_ellipsef,tip_skel)];
                [~, tip_finalpos] = min(tip_ellipsedist);
                if (tip_finalpos == 1) tip_final(count,:) = tip_mid; else tip_final(count,:) = tip_skel; end
                if debug_mode
                    srclabel = 'skel'; if (tip_finalpos==1), srclabel = 'mid'; end
                    overshoot = min(tip_ellipsepos-min(tip_choice), max(tip_choice)-tip_ellipsepos);
                    fprintf('  tip F%d: branchpt=%d branched choice=%d ellipsepos=%d [%d,%d] overshoot=%d reason=topo last_flag=0 -> %s (ellipsedist=[%.1f %.1f])\n', ...
                        count, ~isempty(Sbl), choice, tip_ellipsepos, min(tip_choice), max(tip_choice), overshoot, srclabel, tip_ellipsedist(1), tip_ellipsedist(2));
                end
            end
        end
    else
        tip_skel = boundb(dsearchn(boundb,Sef(1,:)),:);
        if (last_flag) [tmp, tip_finaldistpos] = min([pdist2(tip_final_last,tip_ellipsef) pdist2(tip_final_last,tip_skel)]);
        else tip_finaldistpos = 2;
        end
        if (tip_finaldistpos == 1) tip_final(count,:) = tip_ellipsef; else tip_final(count,:) = tip_skel; end
        if debug_mode
            srclabel = 'skel'; if (tip_finaldistpos==1), srclabel = 'ellipsef'; end
            fprintf('  tip F%d: branchpt=%d unbranched last_flag=%d -> %s\n', ...
                count, ~isempty(Sbl), last_flag, srclabel);
        end
    end
    end

    if manual_tip_seed_applied
        % locate_tip's ellipse-fit refinement (tip_ellipsef, above) treats
        % Qef as only a SEED -- it searches the local boundary within a
        % toln-growing radius (up to 2*diamo_est) and returns whatever point
        % its own ellipse fit converges on, which is free to land well away
        % from the seed itself. Overriding Qef alone is therefore not enough
        % to make the human's click stick: confirmed on HV209_62 F3282,
        % where overriding Qef to the clicked [111,28] still let ellipse-fit
        % walk the final tip to [103,14], ~16px (most of a tube diameter)
        % away, silently discarding the correction. Force the final tip
        % position directly instead -- this is the one frame this whole
        % mechanism exists to fix, so the human's identification of the tip
        % should be authoritative, not merely a suggestion to a local search.
        if debug_mode
            fprintf('  manual_tip_seed F%d: final tip forced to human point [%d,%d] (automatic tip-finding had produced [%d,%d])\n', ...
                count, manual_tip_seed_final_pt(1), manual_tip_seed_final_pt(2), tip_final(count,1), tip_final(count,2));
        end
        tip_final(count,:) = manual_tip_seed_final_pt;
    end

    % Tip-position sanity check: a real tube tip cannot jump implausibly far
    % between adjacent frames. Unconditional -- applies regardless of
    % weak_signal (this is a "did the tip physically teleport" check, a
    % different concern from weak_signal's "is the mask fragmented") and
    % identically to both tip_method values (this check sits after both the
    % ringwalk and skeleton branches have already converged on
    % tip_final(count,:), so no method-specific handling is needed here).
    % Confirmed needed with weak_signal=0: ring_walk_tip produced a
    % catastrophic single-frame tip jump on 20260327_3_cropped frame 11
    % (~100+px row, ~320+px col vs. neighbors) that went completely
    % unflagged while this check was gated behind weak_signal, even though
    % the raw image data for that frame was visually identical to its
    % neighbors -- a pure tracking-algorithm failure, exactly what this
    % check exists to catch.
    % max_tip_jump_um itself is frame-rate/growth-rate derived when left at
    % its default -- see the derivation block near the top of this script.
    % Threshold empirically calibrated (jitter_margin_um component): frame-
    % to-frame tip displacement was measured on 3 real datasets (~6500
    % transitions total) -- genuine growth+jitter never exceeded ~9.7um on
    % two clean datasets, while a third (known segmentation failures, e.g.
    % the mask splitting the tube in two) showed a sharp gap in the
    % distribution: nothing between ~5um and ~41um, with ~2% of frames
    % landing at 65-69um. 15um sits in the middle of that gap -- same
    % flagging result (0 false positives on the clean datasets, ~68 frames
    % flagged on the bad one) at any threshold from 10 to 30um, so the
    % exact value isn't sensitive. See session notes for the analysis.
    if last_flag && pixelsize > 0
        tip_jump_um = pdist2(tip_final(count,:), tip_final_last) * pixelsize;
        % Threshold scales by frames_since_last_good: tip_final_last is the
        % LAST GOOD tip, which may be several frames stale if recent frames
        % failed -- comparing against a stale reference must allow roughly
        % that many frames' worth of real growth, not a single frame's
        % budget (see frames_since_last_good's declaration comment).
        jump_fail = tip_jump_um > max_tip_jump_um * frames_since_last_good;

        % Lateral-offset + stationary-lock guards -- see their shared doc
        % block near the top of this script (next to lateral_offset_max_factor's
        % own default). Computed here (not just inside the shared predicate
        % below) so a failure specifically attributable to one of these two,
        % as opposed to the plain jump check, is visible in debug output.
        %
        % axis_unit: prefer the 2-point displacement history
        % (tip_final_last2 -> tip_final_last, real observed motion) when
        % it's available and non-degenerate. Falls back to a purely
        % single-frame geometric axis -- the tube's own local skeleton
        % direction at tip_final_last, read straight from THIS frame's mask
        % -- when it isn't. Needed specifically for the first frame after a
        % fresh manual/anchor seed: only one good frame exists yet, so no
        % displacement vector is even DEFINED (not just low-confidence) --
        % confirmed this is exactly the failure point on HV200_4_5 (F5201
        % manual seed -> F5200 wrong lock): with only the 2-point-history
        % source, this guard was structurally unable to evaluate anything on
        % that one critical transition, the only one that actually mattered.
        axis_unit = [];
        if exist('tip_final_last2', 'var') && ~isempty(tip_final_last2)
            axis_vec = tip_final_last - tip_final_last2;
            axis_norm = norm(axis_vec);
            if axis_norm > 1.0 % px -- degenerate/near-stationary history, fall through below instead
                axis_unit = axis_vec / axis_norm;
            end
        end
        if isempty(axis_unit)
            axis_unit = local_tip_tangent(U, tip_final_last, diamo_est);
        end
        lateral_axis_ok = ~isempty(axis_unit);
        lateral_px = NaN;
        if lateral_axis_ok
            d_vec = tip_final(count,:) - tip_final_last;
            long_comp = dot(d_vec, axis_unit);
            lateral_px = norm(d_vec - long_comp * axis_unit);
        end
        lateral_fail = lateral_axis_ok && (lateral_px > lateral_offset_max_factor * diamo_est);
        if debug_mode
            if lateral_axis_ok
                fprintf('  DIAG F%d: axis_ok=1 axis=[%.2f %.2f] lateral_px=%.2f lateral_max=%.2f diamo_est=%.2f\n', ...
                    count, axis_unit(1), axis_unit(2), lateral_px, lateral_offset_max_factor*diamo_est, diamo_est);
            else
                fprintf('  DIAG F%d: axis_ok=0 (local_tip_tangent returned empty)\n', count);
            end
        end

        stationary_lock_active = stationary_streak >= stationary_lock_n_frames;
        pos_delta_px = pdist2(tip_final(count,:), tip_final_last);
        stationary_fail = stationary_lock_active && (pos_delta_px < stationary_pos_eps_px);

        % Side memory -- see side_offset_max_factor's doc near the top of this script.
        side_n = [];
        if isfinite(side_offset_max_factor)
            side_axis = local_tip_tangent(U, tip_final_last, diamo_est);
            if ~isempty(side_axis)
                if ~isempty(side_axis_prev) && dot(side_axis, side_axis_prev) < 0, side_axis = -side_axis; end
                side_n = [-side_axis(2), side_axis(1)];
                side_axis_prev = side_axis;
            end
        end
        side_limit_px = side_offset_max_factor * diamo_est;
        side_fail = false;
        if ~isempty(side_n)
            side_new = side_acc + dot(tip_final(count,:) - tip_final_last, side_n);
            side_fail = abs(side_new) > side_limit_px && abs(side_new) > abs(side_acc);
            if debug_mode
                fprintf('  DIAG F%d: side_acc=%.2f side_new=%.2f limit=%.2f side_fail=%d\n', count, side_acc, side_new, side_limit_px, side_fail);
            end
        end

        if jump_fail || lateral_fail || stationary_fail || side_fail
            % The chosen candidate fails at least one guard -- before giving
            % up, check whether one of the OTHER candidates this same frame
            % already produced (ellipsef/skel/mid, whichever this code path
            % computed) passes ALL of them. This was previously a pure
            % reject-after-the-fact test on the jump check alone: it flagged
            % the frame but left whatever far-off point the voting logic
            % picked in tip_final, which then got drawn into the growth/
            % roi_debug videos as if it were a real position (confirmed on
            % HV198_1_16 frame 3314: a near-empty mask (diam~0px) produced a
            % spurious ellipsef far from frame 3313's tip; the jump check
            % correctly NaN'd the CSV but the video still showed the bad
            % point, since video drawing was never gated on frame_failed --
            % see Tip plot section below, now fixed there too). Recovering a
            % nearby alternate candidate when one exists directly reduces
            % how often this situation can happen at all, rather than only
            % cleaning up after it.
            cand = tip_ellipsef; cand_label = {'ellipsef'};
            if ~isempty(tip_skel), cand = [cand; tip_skel]; cand_label{end+1} = 'skel'; end
            if ~isempty(tip_mid),  cand = [cand; tip_mid];  cand_label{end+1} = 'mid';  end
            % Cross-method fallback (ringwalk only): tip_skel/tip_mid above
            % are only ever populated when tip_method='skeleton' natively
            % runs, so a failing ringwalk frame otherwise has just ONE
            % candidate (ellipsef) to recover from. Retry this SAME frame
            % with the skeleton method's own logic and add its result to
            % the pool -- see skeleton_tip_fallback's doc comment for why
            % this is a self-contained duplicate, not a refactor.
            fb_ok = false;
            if strcmp(tip_method, 'ringwalk') && ringwalk_fallback_to_skeleton
                [fb_tip, fb_diam, fb_maxy, fb_boundb, fb_Qef, fb_Qel, fb_Qec, ...
                 fb_tip_ellipse, fb_center, fb_phin, fb_axes, fb_stats, fb_edges, fb_ok] = ...
                    skeleton_tip_fallback(U, weight, diamo, tip_final_last, last_flag, count, debug_mode, ellipse_fit_method, ellipse_candidate_max_jump_factor);
                if fb_ok && ~isempty(fb_tip)
                    cand = [cand; fb_tip]; cand_label{end+1} = 'skeleton_fallback';
                end
            end
            n_cand = size(cand, 1);
            cand_ok = false(n_cand, 1);
            for cand_i = 1:n_cand
                cand_ok(cand_i) = candidate_passes_tip_guard(cand(cand_i,:), tip_final_last, ...
                    axis_unit, max_tip_jump_um, frames_since_last_good, pixelsize, ...
                    lateral_offset_max_factor, diamo_est, stationary_lock_active, stationary_pos_eps_px, ...
                    side_n, side_acc, side_limit_px);
            end
            % Nudge target limit -- see nudge_max_cand_dist_factor's doc near the top.
            if stationary_nudge_um > 0 && stationary_fail && ~jump_fail && ~lateral_fail && ~side_fail
                cand_ok(pdist2(cand, tip_final_last) > nudge_max_cand_dist_factor * diamo_est) = false;
            end
            if debug_mode
                for cand_i = 1:n_cand
                    fprintf('  DIAG F%d cand %s: [%.1f,%.1f] dist=%.2fpx ok=%d\n', ...
                        count, cand_label{cand_i}, cand(cand_i,1), cand(cand_i,2), ...
                        pdist2(cand(cand_i,:), tip_final_last), cand_ok(cand_i));
                end
            end
            cand_dist_px = pdist2(cand, tip_final_last);
            if any(cand_ok)
                cand_dist_px(~cand_ok) = Inf; % only pick among candidates that actually pass every guard
            end
            [best_dist_px, best_idx] = min(cand_dist_px);
            if strcmp(cand_label{best_idx}, 'skeleton_fallback')
                diam = fb_diam; maxy = fb_maxy; boundb = fb_boundb; Qef = fb_Qef;
                Qel = fb_Qel; Qec = fb_Qec; tip_ellipse = fb_tip_ellipse;
                center = fb_center; phin = fb_phin; axes = fb_axes; stats = fb_stats; edges = fb_edges;
                tip_recovered_via_skeleton(count) = true;
            end
            fail_reason = {};
            if jump_fail, fail_reason{end+1} = 'jump'; end
            if lateral_fail, fail_reason{end+1} = 'lateral'; end
            if stationary_fail, fail_reason{end+1} = 'stationary_lock'; end
            if side_fail, fail_reason{end+1} = 'side'; end
            fail_reason_str = strjoin(fail_reason, '+');
            if cand_ok(best_idx)
                nudged = false;
                if stationary_nudge_um > 0 && stationary_fail && ~jump_fail && ~lateral_fail && ~side_fail
                    [tip_nudged, nudged_px] = step_along_contour(boundb, tip_final_last, cand(best_idx,:), ...
                        stationary_nudge_um / pixelsize, stationary_pos_eps_px + 0.5);
                    if nudged_px > 0
                        tip_final(count,:) = tip_nudged;
                        nudged = true;
                        if debug_mode
                            fprintf('  tip F%d: stationary lock released by a NUDGE of %.1fpx along the boundary toward %s (candidate %.1fpx away, not taken)\n', ...
                                count, nudged_px, cand_label{best_idx}, best_dist_px);
                        end
                    end
                end
                if ~nudged
                    tip_final(count,:) = cand(best_idx,:);
                    if debug_mode
                        fprintf('  tip F%d: primary failed [%s] (jump=%.2fum, lateral=%.2fpx, stationary_lock=%d) -- recovered via %s (jump=%.2fum)\n', ...
                            count, fail_reason_str, tip_jump_um, lateral_px, stationary_lock_active, cand_label{best_idx}, best_dist_px*pixelsize);
                    end
                end
            else
                % No candidate this frame produced passes every guard.
                % Hold at the previous good position instead of accepting a
                % point we've just determined isn't trustworthy, or leaving
                % a gap -- snap tip_final_last onto THIS frame's own mask
                % boundary (same nearest-boundary-pixel snap manual_tip_seed
                % already uses) so downstream code that expects tip_final to
                % sit on boundb still gets a consistent point. Confirmed
                % directly useful on HV200_4_5 F5200: the very NEXT frame
                % (F5199) independently recovers the true position by
                % comparing against this same held reference -- meaning the
                % true tip itself is almost certainly also right there, so a
                % held point is a better estimate than either a
                % known-untrustworthy candidate or an outright gap. Treated
                % as a normal good frame afterward (frame_failed stays
                % false): it becomes the new tip_final_last so continuity
                % for later frames is preserved through the hold, not reset.
                Ub_bounds_hold = bwboundaries(U);
                held_ok = false;
                if ~isempty(Ub_bounds_hold)
                    Ub_pts_hold = cell2mat(Ub_bounds_hold);
                    d_hold = hypot(double(Ub_pts_hold(:,1))-tip_final_last(1), double(Ub_pts_hold(:,2))-tip_final_last(2));
                    [dmin_hold, k_hold] = min(d_hold);
                    % Generous radius (2 diameters) -- this only needs to
                    % confirm the SAME local tube feature is still there
                    % this frame, not a tight seed-click-accuracy bound like
                    % manual_tip_seed_radius_factor uses.
                    held_ok = dmin_hold <= 2 * diamo_est;
                end
                if held_ok
                    tip_final(count,:) = [Ub_pts_hold(k_hold,1), Ub_pts_hold(k_hold,2)];
                    if debug_mode
                        fprintf('  tip F%d: failed [%s] (jump=%.2fum, lateral=%.2fpx, frames_since_last_good=%d, stationary_lock=%d), no candidate passes -- HELD at previous position, snapped to this frame''s boundary [%.0f,%.0f] (%.2fpx from tip_final_last)\n', ...
                            count, fail_reason_str, tip_jump_um, lateral_px, frames_since_last_good, stationary_lock_active, tip_final(count,1), tip_final(count,2), dmin_hold);
                    end
                else
                    % Even holding position isn't possible -- this frame's
                    % mask doesn't reach anywhere near the last good tip at
                    % all. Genuinely nothing trustworthy to report; fall
                    % back to the old behavior (closest candidate, flagged).
                    tip_final(count,:) = cand(best_idx,:);
                    frame_failed(count) = true;
                    if debug_mode
                        fprintf('  tip F%d: failed [%s] (jump=%.2fum, lateral=%.2fpx, frames_since_last_good=%d, stationary_lock=%d), no candidate passes AND no boundary point near previous position either (best=%.2fum via %s) -- flagged, results NaN''d\n', ...
                            count, fail_reason_str, tip_jump_um, lateral_px, frames_since_last_good, stationary_lock_active, best_dist_px*pixelsize, cand_label{best_idx});
                    end
                end
            end
        end

        % Per-frame step cap (see max_step_um's doc near the top). Applied to
        % whatever tip_final ended up being, whichever path produced it.
        if isfinite(max_step_um) && ~frame_failed(count)
            cap_px = max_step_um / pixelsize * frames_since_last_good;
            step_px_now = pdist2(tip_final(count,:), tip_final_last);
            if step_px_now > cap_px
                [tip_capped, capped_px] = step_along_contour(boundb, tip_final_last, tip_final(count,:), cap_px);
                if capped_px > 0
                    if debug_mode
                        fprintf('  tip F%d: BORDER DRIFT LIMIT -- accepted tip was %.1fpx (%.2fum) from tip_final_last, limited to %.1fpx along the boundary\n', ...
                            count, step_px_now, step_px_now*pixelsize, capped_px);
                    end
                    tip_final(count,:) = tip_capped;
                end
            end
        end

        % Side memory upkeep: accumulate the sideways part of the accepted step.
        if ~isempty(side_n) && ~frame_failed(count)
            side_acc = side_memory_decay * side_acc + dot(tip_final(count,:) - tip_final_last, side_n);
        end
    end

    if weak_signal && (needs_repair(count) || frame_failed(count))
        U_cache{count} = U;
    end

    % Update tip_final for the next frame. tip_final_last only ever advances
    % to a GOOD (non-frame_failed) tip -- see frames_since_last_good's
    % declaration comment for why. Still force the update on the very
    % first-ever iteration regardless of frame_failed (rare, but possible
    % if e.g. diam_tol itself flags the cold-start frame): tip_final_last
    % must exist by the time any later iteration's last_flag branch reads
    % it, via (:,:) assignment which auto-creates on first use (a plain
    % read of a never-yet-assigned tip_final_last would error).
    if ~frame_failed(count) || ~exist('tip_final_last', 'var')
        % tip_final_last2 upkeep for the lateral-offset guard above -- see
        % its doc block near the top of this script. Must happen BEFORE
        % tip_final_last itself is overwritten below, since tip_final_last2
        % needs the OUTGOING value.
        if exist('tip_final_last', 'var')
            tip_final_last2 = tip_final_last;
        else
            tip_final_last2 = [];
        end
        % Position half of the stationary-lock check, captured here (still
        % have the OLD tip_final_last to compare against) but NOT finalized
        % into stationary_streak until diamf_avg(count) exists -- the
        % median-of-cross-sections diameter computed much later in this
        % same iteration (see "Diameter of tube" below), which is what
        % actually showed the bit-identical-across-frames signature on
        % HV200_4_5. locate_tip's own early, cruder `diam` (used here
        % originally) is noisy frame to frame in a way diamf_avg isn't --
        % confirmed that comparing against it meant this guard's diameter
        % condition almost never held, so stationary_streak never actually
        % accumulated despite position genuinely freezing for ~1300 frames.
        stationary_pos_ok_this_frame = exist('tip_final_last', 'var') && ...
            pdist2(tip_final(count,:), tip_final_last) < stationary_pos_eps_px;
        tip_final_last(:,:) = tip_final(count,:);
        frames_since_last_good = 1;
    else
        frames_since_last_good = frames_since_last_good + 1;
        stationary_pos_ok_this_frame = false; % a failed frame can't extend the streak either
    end
    last_iter_failed = frame_failed(count); % see ringwalk seed-validity gate above

    % Find the curves along the sides of the tubes
    total1 = []; total2 = [];
    range1 = ceil(length(boundb)*0.5):length(boundb);
    dist1 = pdist2(boundb(range1,:),tip_final(count,:));
    postotal1 = find(dist1 > diamo*0.75)+range1(1)-1;
    if (~isempty(find(diff(postotal1(1:floor(length(postotal1)/2))>1))))
        postotal1(1:find(diff(postotal1(1:floor(length(postotal1)/2))>1))) = [];
    end
    total1(:,:) = boundb(postotal1,:);
    
    range2 = ceil(length(boundb)*0.5)-1:-1:1;
    dist2 = pdist2(boundb(range2,:),tip_final(count,:));
    postotal2 = range2(1)-find(dist2 > diamo*0.75)+1;
    if (~isempty(find(diff(postotal2(1:floor(length(postotal2)/2))>1))))
        postotal2(1:find(diff(postotal2(1:floor(length(postotal2)/2))>1))) = [];
    end
    total2(:,:) = boundb(postotal2,:);

    % Ensure that both curves also reach near the tip -- mirrors the maxy
    % check just below, but for the near-tip end instead of the far end,
    % and runs FIRST so the maxy check (which only looks at the far end)
    % can't unknowingly strip a side's only near-tip padding while fixing
    % the other side's far-end shortfall. range1/range2 above are a naive
    % 50%-INDEX bisection of boundb with no guaranteed relationship to the
    % tip's actual physical position -- a small shift in tip position
    % between two adjacent, visually near-identical frames can put almost
    % the WHOLE near-tip cap's boundary points on one side, leaving the
    % other side without a single point within diamo*0.75 of the tip even
    % before the exclusion filter runs. Confirmed on real data (HV207_58
    % frame 650 vs its immediate predecessor frame 649, otherwise close to
    % identical): frame 649's side1 came within 1.0px of the tip; frame
    % 650's side1 came no closer than 18.4px, well past the
    % diamo*0.75=10.1px exclusion radius. Left unfixed, that starves
    % side1 of any real near-tip presence BEFORE the maxy-rebalancing
    % below even runs -- which then made it worse by also stealing
    % side1's far-end points to fix side2's own maxy shortfall, leaving
    % side1 a stranded middle stub with neither end represented (total1
    % collapsed from 81 to 33 points, none of them near the actual ROI
    % target region, and the resulting ROI half degenerated to a sliver
    % instead of a filled strip).
    if ~isempty(total1) && ~isempty(total2)
        tip_reach_tol = diamo*0.75 + 2;
        if pdist2(total1(1,:), tip_final(count,:)) > tip_reach_tol
            while pdist2(total1(1,:), tip_final(count,:)) > tip_reach_tol && ~isempty(total2)
                total1 = vertcat(total2(1,:), total1);
                total2(1,:) = [];
            end
        elseif pdist2(total2(1,:), tip_final(count,:)) > tip_reach_tol
            while pdist2(total2(1,:), tip_final(count,:)) > tip_reach_tol && ~isempty(total1)
                total2 = vertcat(total1(1,:), total2);
                total1(1,:) = [];
            end
        end
    end

    % Ensure that both curves reach maxy
    if isempty(total1) || isempty(total2)
        dist_all = pdist2(boundb, tip_final(count,:));
        postotal_all = find(dist_all > diamo*0.75);
        half = ceil(length(postotal_all)*0.5);
        total1 = boundb(postotal_all(1:half),:);
        total2 = boundb(postotal_all(half+1:end),:);
    end
    if ~isempty(total1) && ~isempty(total2)
        if (max(total1(:,2)) < (maxy-1))
            while(max(total1(:,2)) < (maxy-1) && ~isempty(total2))
                total1 = vertcat(total1,total2(end,:));
                total2(end,:) = [];
            end
        elseif (max(total2(:,2)) < (maxy-1))
            while(max(total2(:,2)) < (maxy-1) && ~isempty(total1))
                total2 = vertcat(total2, total1(end,:));
                total1(end,:) = [];
            end
        end
    end
    if isempty(total1) || isempty(total2)
        dist_all = pdist2(boundb, tip_final(count,:));
        postotal_all = find(dist_all > diamo*0.75);
        if ~isempty(postotal_all)
            half = ceil(length(postotal_all)*0.5);
            total1 = boundb(postotal_all(1:half),:);
            total2 = boundb(postotal_all(half+1:end),:);
        end
    end

    if ~isempty(total1) && ~isempty(total2) && (abs(total1(end,1) - total2(end,1)) < 0.75*diam)
        total1(find(total1(:,2) >= max(total1(:,2))),:) = [];
        total2(find(total2(:,2) >= max(total2(:,2))),:) = [];
    end

    % ---- DIAGNOSTIC BLOCK 2: skeleton + geometry (frames smp and smp-1, see BLOCK 1) ----
    if dump_diag
        dp  = fullfile(outpath, sprintf('diag_%d', count));
        sz1 = size(U,1); sz2 = size(U,2);

        if strcmp(tip_method, 'skeleton')
            imwrite(imdilate(Q,  strel('disk',1)), [dp '_10_Q_thin.png']);
            imwrite(imdilate(Q2, strel('disk',1)), [dp '_11_Q2_debranched.png']);
            % S/S2: the OTHER skeleton (bwmorph 'skel', not 'thin') -- the
            % structure that actually generates the tip candidate voted on
            % (tip_skel/tip_mid), unlike Q/Q2 which only seed the ellipse
            % fit. Never dumped before this -- was previously only ever
            % inspected via a one-off standalone script, not the real
            % pipeline.
            imwrite(imdilate(S,  strel('disk',1)), [dp '_14_S_skel.png']);
            imwrite(imdilate(S2, strel('disk',1)), [dp '_15_S2_debranched.png']);

            Rch = uint8(U)*80; Gch = uint8(U)*80; Bch = uint8(U)*80;
            Qd  = imdilate(Q,  strel('disk',1)); Rch = Rch + uint8(Qd)*170;
            Q2d = imdilate(Q2, strel('disk',1)); Gch = Gch + uint8(Q2d)*170;
            if ~isempty(Qef)
                re = max(1,Qef(1,1)-4):min(sz1,Qef(1,1)+4);
                ce = max(1,Qef(1,2)-4):min(sz2,Qef(1,2)+4);
                Bch(re,ce) = 255;
            end
            % locate_tip.m's ellipse fit (center/axes/phin), drawn in white
            % so it stands out against the R=Q/G=Q2 coding above. Same
            % (row,col) convention ellipse_data.m itself uses throughout --
            % tip_new's columns come from bwboundaries ([row col]), so
            % "x"=row, "y"=col in center/axes/phin, not the usual image x/y.
            if isreal(axes) && all(axes > 0)
                tvals = linspace(0, 2*pi, 200);
                er = axes(1)*cos(tvals)*cos(phin) - axes(2)*sin(tvals)*sin(phin) + center(1);
                ec = axes(1)*cos(tvals)*sin(phin) + axes(2)*sin(tvals)*cos(phin) + center(2);
                er = round(er); ec = round(ec);
                valid = er>=1 & er<=sz1 & ec>=1 & ec<=sz2;
                idx = sub2ind([sz1 sz2], er(valid), ec(valid));
                Rch(idx) = 255; Gch(idx) = 255; Bch(idx) = 255;
            end
            imwrite(cat(3,Rch,Gch,Bch), [dp '_12_skeleton_overlay.png']);
        end

        Rch = uint8(U)*60; Gch = uint8(U)*60; Bch = uint8(U)*60;
        brows = max(1,min(sz1,boundb(:,1))); bcols = max(1,min(sz2,boundb(:,2)));
        for pi=1:size(boundb,1), Rch(brows(pi),bcols(pi))=255; Gch(brows(pi),bcols(pi))=255; end
        if ~isempty(total1)
            tr=max(1,min(sz1,total1(:,1))); tc=max(1,min(sz2,total1(:,2)));
            for pi=1:size(total1,1), Gch(tr(pi),tc(pi))=255; end
        end
        if ~isempty(total2)
            tr=max(1,min(sz1,total2(:,1))); tc=max(1,min(sz2,total2(:,2)));
            for pi=1:size(total2,1), Bch(tr(pi),tc(pi))=255; end
        end
        % locate_tip.m's ellipse fit (center/axes/phin) and the seed it was
        % fit around (Qef) -- computed for BOTH tip_method values (see the
        % single unconditional locate_tip call above), but previously only
        % ever drawn in the skeleton-only _12 image above, so a ringwalk run
        % (this run's tip_method) never showed how tip_ellipsef relates to
        % Qef at all. Magenta for Qef (unused elsewhere in this image),
        % white for the ellipse (matches the _12 image's convention).
        if ~isempty(Qef)
            re_q=max(1,Qef(1,1)-4):min(sz1,Qef(1,1)+4);
            ce_q=max(1,Qef(1,2)-4):min(sz2,Qef(1,2)+4);
            Rch(re_q,ce_q)=255; Gch(re_q,ce_q)=0; Bch(re_q,ce_q)=255;
        end
        if isreal(axes) && all(axes > 0)
            tvals = linspace(0, 2*pi, 200);
            er = axes(1)*cos(tvals)*cos(phin) - axes(2)*sin(tvals)*sin(phin) + center(1);
            ec = axes(1)*cos(tvals)*sin(phin) + axes(2)*sin(tvals)*cos(phin) + center(2);
            er = round(er); ec = round(ec);
            valid = er>=1 & er<=sz1 & ec>=1 & ec<=sz2;
            idx = sub2ind([sz1 sz2], er(valid), ec(valid));
            Rch(idx) = 255; Gch(idx) = 255; Bch(idx) = 255;
        end
        % tip_skel/tip_mid: the skeleton method's own independent,
        % non-ellipse-fit candidates (only ever populated when tip_method=
        % 'skeleton' hit the branched path this frame; empty/stale-cleared
        % otherwise -- see the per-iteration reset near the top of the
        % loop). Cyan for tip_skel, orange for tip_mid -- distinct from
        % boundary(yellow)/Qef(magenta)/ellipse(white)/tip_final(red) so
        % all the candidates a frame actually voted between are visible at
        % once, not just the winner.
        if exist('tip_skel', 'var') && ~isempty(tip_skel)
            re_sk=max(1,tip_skel(1)-3):min(sz1,tip_skel(1)+3);
            ce_sk=max(1,tip_skel(2)-3):min(sz2,tip_skel(2)+3);
            Rch(re_sk,ce_sk)=0; Gch(re_sk,ce_sk)=255; Bch(re_sk,ce_sk)=255;
        end
        if exist('tip_mid', 'var') && ~isempty(tip_mid)
            re_md=max(1,tip_mid(1)-3):min(sz1,tip_mid(1)+3);
            ce_md=max(1,tip_mid(2)-3):min(sz2,tip_mid(2)+3);
            Rch(re_md,ce_md)=255; Gch(re_md,ce_md)=165; Bch(re_md,ce_md)=0;
        end
        re=max(1,tip_final(count,1)-3):min(sz1,tip_final(count,1)+3);
        ce=max(1,tip_final(count,2)-3):min(sz2,tip_final(count,2)+3);
        Rch(re,ce)=255; Gch(re,ce)=0; Bch(re,ce)=0;
        imwrite(cat(3,Rch,Gch,Bch), [dp '_13_geometry_overlay.png']);
        disp(['DIAG block 2 saved to ' dp]);
    end
    % ---- END DIAGNOSTIC BLOCK 2 ----

    % Centerline: minimum-cost path through tube, weighted by distance from
    % wall — paths near the tube centre are cheap, so the optimal path
    % naturally follows the medial axis regardless of bends or branches.
    right_col = size(U,2) - 1;
    right_pix = find(U(:, right_col));
    while isempty(right_pix) && right_col > 1
        right_col = right_col - 1;
        right_pix = find(U(:, right_col));
    end
    % If mean of right_pix falls in a gap, snap to nearest actual U pixel
    ra_row = round(mean(right_pix));
    if ~U(ra_row, right_col)
        [~, snap] = min(abs(right_pix - ra_row));
        ra_row = right_pix(snap);
    end
    right_anchor = [ra_row, right_col];
    if weak_signal, right_anchor_row_last = ra_row; end

    % Weight: inversely proportional to distance from tube boundary, SQUARED
    % -- 1/(D+1) alone saturates within a few px of the wall (1/6 at D=5,
    % 1/11 at D=10: barely any further improvement deeper in), so across a
    % WIDE region (e.g. a tip bulb) the cost landscape goes nearly flat
    % once you're a bit off the wall. A flat landscape gives the greedy
    % descent below no real incentive to hug the true medial axis: a
    % shorter, merely-adequate path across the bulb can cost about the same
    % as the longer, properly-centered one, so it takes a diagonal
    % "shortcut" straight across instead of curving through the centre --
    % confirmed on HV209_116 frame 832, where the traced centerline cuts
    % straight from the shank to the tip instead of following the bulb's
    % actual medial axis, badly skewing the Half1/Half2 ROI split. The same
    % near-flatness can also stall the descent outright (frame 1: several
    % near-tied neighbours with no strictly-lower direction, so the walk
    % breaks early and the centerline never reaches the true tip). Squaring
    % makes the cost fall off much faster near the wall and stay
    % meaningfully non-flat further in, giving a sharper single-minimum
    % ridge along the medial axis instead of a broad plateau.
    D_tube = bwdist(~U);
    W_tube = Inf(size(U));
    W_tube(U) = 1 ./ (D_tube(U) + 1).^2;

    % Geodesic cost from right_anchor (low cost = centre of tube)
    GD = graydist(W_tube, right_anchor(2), right_anchor(1));
    GD(~U) = Inf;

    % Nearest U pixel to tip_final as trace start
    [Ur_all, Uc_all] = find(U);
    [~, tpos] = min(pdist2([Ur_all Uc_all], tip_final(count,:)));
    r = Ur_all(tpos); c = Uc_all(tpos);

    % Safety: if GD at start is Inf the tube is disconnected — fall back to Q endpoint
    if ~isfinite(GD(r,c))
        [~, epos] = max(Qec);
        r = Qel(epos,1); c = Qel(epos,2);
    end

    % Gradient descent from tip to right_anchor; visited mask prevents loops
    max_path = 3*nnz(U);
    path = zeros(max_path, 2);
    path(1,:) = [r c];
    n_path = 1;
    visited = false(size(U));
    visited(r,c) = true;
    for step = 1:max_path-1
        if GD(r,c) == 0, break; end
        r0 = max(1,r-1); r1 = min(size(U,1),r+1);
        c0 = max(1,c-1); c1 = min(size(U,2),c+1);
        nbhd = GD(r0:r1, c0:c1);
        nbhd(visited(r0:r1, c0:c1)) = Inf;
        [min_val, idx] = min(nbhd(:));
        % GD is a true geodesic distance field from right_anchor, so barring
        % floating-point ties there's always a strictly-lower unvisited
        % neighbour except at the anchor itself -- a plain min_val>=GD(r,c)
        % stops dead on the FIRST tied neighbour instead of stepping through
        % it, which can freeze the walk just a few steps from the tip in a
        % wide region (bwdist gives locally-repeated integer-ish distances
        % there -- confirmed on HV209_116 frame 1: the traced centerline
        % stalls inside the tip bulb and never reaches the true tip).
        % Tolerate exact ties (>, not >=); the visited mask still guarantees
        % termination.
        if min_val > GD(r,c), break; end
        [dr, dc] = ind2sub(size(nbhd), idx);
        r = r0+dr-1; c = c0+dc-1;
        n_path = n_path + 1;
        path(n_path,:) = [r c];
        visited(r,c) = true;
    end
    path = path(1:n_path,:);
    yctk = path(:,1); xctk = path(:,2);
    if debug_mode
        fprintf('  centerline F%d: n_path=%d start=[%d %d] end=[%d %d] right_anchor=[%d %d] GD_end=%.3f GD_start=%.3f\n', ...
            count, n_path, path(1,1), path(1,2), path(end,1), path(end,2), right_anchor(1), right_anchor(2), GD(path(end,1),path(end,2)), GD(path(1,1),path(1,2)));
    end

    % Cumulative arc length along path (0 at tip, max at base)
    path_dist = [0; cumsum(sqrt(sum(diff(path).^2, 2)))];

    % DEBUG: save overlay for frames smp and smp-1 (see DIAGNOSTIC BLOCK 1 above)
    if dump_diag
        dbg = zeros(size(U,1), size(U,2), 3);
        dbg(:,:,3) = double(U) * 0.4;   % tube mask: dark blue
        if strcmp(tip_method, 'skeleton')
            dbg(:,:,2) = double(Q) * 0.8;   % Q skeleton: green
        end
        % traced path in white
        for di = 1:size(path,1)
            dbg(path(di,1), path(di,2), :) = [1 1 1];
        end
        % right anchor in cyan
        dbg(right_anchor(1), right_anchor(2), :) = [0 1 1];
        % tip_final in magenta
        dbg(tip_final(count,1), tip_final(count,2), :) = [1 0 1];
        imwrite(dbg, fullfile(outpath, [fname sprintf('_debug_skel_%d.png', count)]));
        disp(['DEBUG saved: ' fullfile(outpath, [fname sprintf('_debug_skel_%d.png', count)])]);
    end

    % Subsample to 100 evenly-spaced points and smooth
    if (count == smp) npoints = ceil(path_dist(end)*1.1); end
    nline = 1:100; norder = floor(nline*path_dist(end)/100);
    nfinal = dsearchn(path_dist, norder');
    yct = yctk(nfinal); xct = xctk(nfinal); distct = path_dist(nfinal);
    xct = round(sgolayfilt(double(xct),3,15)); yct = round(sgolayfilt(double(yct),3,15));
    xct = max(1, min(xct, size(U,2))); yct = max(1, min(yct, size(U,1)));

    % distc_t: kept as-is for its own, separate purpose below (the
    % "tip_final-to-ROI gap" debug diagnostic) -- it measures how far the
    % FINAL voted tip (tip_final) ended up from Qef, which is only ever a
    % rough SEED for locate_tip's ellipse search (see Qef's own definition
    % comment above), not the final tip itself. That gap is a genuine QC
    % signal (how much did refinement move the tip from its seed), but it
    % has nothing to do with where the centerline's own arc-length
    % coordinate should start, and using it to trim xc/yc/distc (as this
    % used to do) silently shifted EVERY arc-length position -- including
    % non-zero starti/stopi, i.e. any shifted ROI, not just a tip-flush
    % one -- by however much that frame's Qef happened to miss tip_final
    % (confirmed on real data: 2.8-8.6px, frame-varying). The path already
    % starts at the mask pixel nearest tip_final (see "Nearest U pixel to
    % tip_final as trace start" above), so distct(1) is already ~0 there;
    % distct is monotonically non-decreasing by construction, so its own
    % minimum (index 1) is always the correct, tip-anchored start -- no
    % search or trim needed.
    distc_t = pdist2(tip_final(count,:), Qef);
    cut = 1;
    xc = xct(cut:end); yc = yct(cut:end); distc = distct(cut:end);

    % Calculate the gradient of the center line to get the normals
    dx = gradient(xc); dx(find(dx == 0)) = 0.01;
    dy = gradient(yc); dy(find(dy == 0)) = 0.01;

    % Finding the points where the normals hit the edge curves. Restricted
    % to a local arc-length window, then to genuine crossings of the fitted
    % line within it, tie-broken by distance to the centerline sample (see
    % nearest_crossing_to_sample below) -- a plain global nearest-point-to-
    % the-LINE search is what let a bend send this cross-section jumping to
    % a spatially-nearby-to-the-line but topologically-distant point on the
    % far side of the bend (verified on real HV207_9 frame 2746: samples
    % landed ~90-150px away along the boundary at the tube's sharper kink,
    % discarded downstream by line_continuity -- see session notes for the
    % full geometric writeup).
    al1 = [0; cumsum(sqrt(sum(diff(total1).^2, 2)))];
    al2 = [0; cumsum(sqrt(sum(diff(total2).^2, 2)))];
    crossing_window = diamo * 2; % arc-length px -- generous local margin, not a
                 % speed optimization (these arrays are a few hundred points
                 % either way); guards against a tube folding close enough to
                 % itself that a spatially-near-but-topologically-distant
                 % point could otherwise win the tie-break in step 2. Not
                 % expected to matter for tubes that don't self-fold (those
                 % fail mask segmentation before reaching this code anyway).

    poscross1 = []; poscross2 = []; t1_all = zeros(length(xc),1); t2_all = zeros(length(xc),1);
    for n = 1:length(xc)
        nfitc = fit(vertcat(xc(n),(xc(n) - dy(n))),vertcat(yc(n),(yc(n) + dx(n))),'poly1');

        if (n == 1) start_nfitc(:,:) = [nfitc.p1 nfitc.p2]; end

        sample_pt = [yc(n), xc(n)];
        edge1 = total1(:,1) - nfitc.p1.*total1(:,2) - nfitc.p2;
        cross1 = nearest_crossing_to_sample(edge1, total1, al1, sample_pt, crossing_window);
        poscross1(n) = cross1;

        edge2 = total2(:,1) - nfitc.p1.*total2(:,2) - nfitc.p2;
        cross2 = nearest_crossing_to_sample(edge2, total2, al2, sample_pt, crossing_window);
        poscross2(n) = cross2;

        % Signed half-width at this exact sample, for reconstruct_smooth_mask
        % (weak_signal visual-only mask) -- stashed here, BEFORE
        % line_continuity below can drop/reorder poscross1/poscross2 entries,
        % so this stays index-aligned with xc/yc/dx/dy (length(xc) long)
        % no matter how many points continuity-pruning removes downstream.
        normn = sqrt(dx(n)^2 + dy(n)^2); if normn == 0, normn = 1; end
        p1pt = total1(cross1,:); p2pt = total2(cross2,:);
        t1_all(n) = (p1pt(1)-yc(n))*(dx(n)/normn) + (p1pt(2)-xc(n))*(-dy(n)/normn);
        t2_all(n) = (p2pt(1)-yc(n))*(dx(n)/normn) + (p2pt(2)-xc(n))*(-dy(n)/normn);
    end

    % FWHM diameter calibration (see fwhm_diameter_correction in
    % run_config.m): periodically, on a handful of samples away from the
    % tip/base, measure a threshold-independent width straight off the raw
    % (unmasked) intensity profile -- using the SAME perpendicular line
    % (xc/yc/dx/dy) and the SAME mask crossings (poscross1/poscross2) as
    % the real per-sample diameter measurement above, just before
    % line_continuity can prune/reorder them -- and compare it to what the
    % mask itself reported at that exact sample. The ratio across all
    % calibration samples collected over the run becomes a single
    % correction factor applied to Diameter_um_corrected in the CSV (see
    % near the CSV export below). Deliberately NOT applied to diamo itself
    % or anything derived from it (exclusion radii, crossing windows,
    % corridor widths, etc.) -- all of that was tuned against mask-based
    % diamo semantics, and this correction is only trying to fix the
    % reported number, not rewire geometry that currently works.
    if fwhm_diameter_correction && exist('O_raw', 'var') && mod(count, fwhm_calib_interval) == 0
        n_total = length(xc);
        lo = max(1, round(0.15*n_total)); hi = min(n_total, round(0.85*n_total));
        if hi > lo
            samp_idx = unique(round(linspace(lo, hi, fwhm_calib_samples)));
            pass_mask = []; pass_fwhm = [];
            for si = samp_idx
                mask_w = pdist2(total1(poscross1(si),:), total2(poscross2(si),:));
                fwhm_w = fwhm_cross_section(O_raw, yc(si), xc(si), dx(si), dy(si), crossing_window);
                if isfinite(fwhm_w) && isfinite(mask_w) && mask_w > 0
                    fwhm_calib_mask_px(end+1) = mask_w;
                    fwhm_calib_fwhm_px(end+1) = fwhm_w;
                    pass_mask(end+1) = mask_w; %#ok<AGROW>
                    pass_fwhm(end+1) = fwhm_w; %#ok<AGROW>
                end
            end
            % Per-pass record (frame, sample count, this pass's own median
            % mask/FWHM width and ratio) -- kept SEPARATE from the pooled
            % fwhm_calib_mask_px/fwhm_calib_fwhm_px arrays above (which
            % only feed the single run-level correction factor) so a
            % post-hoc check can see whether the bias ratio itself is
            % stable across the run or drifts -- e.g. around a mid-run
            % treatment that might change signal characteristics (not
            % just true diameter) and invalidate a single blended factor.
            % Written to {fname}_fwhm_calibration.csv alongside the main
            % measurements CSV; see near the CSV export below.
            if ~isempty(pass_mask)
                pass_ratio = median(pass_fwhm ./ pass_mask);
                fwhm_calib_pass_frame(end+1) = count;
                fwhm_calib_pass_n(end+1) = numel(pass_mask);
                fwhm_calib_pass_mask_med(end+1) = median(pass_mask);
                fwhm_calib_pass_fwhm_med(end+1) = median(pass_fwhm);
                fwhm_calib_pass_ratio(end+1) = pass_ratio;
                if debug_mode
                    fprintf('  fwhm_calib F%d: n=%d mask_med=%.2fpx fwhm_med=%.2fpx ratio=%.3f\n', ...
                        count, numel(pass_mask), median(pass_mask), median(pass_fwhm), pass_ratio);
                end
            end
        end
    end

    % Ensure that all overlapping diameter lines are shifted backwards to
    % ensure continuity
    [poscross1, poscross2, distcf] = line_continuity(poscross1,poscross2,1,distc);
    [poscross1, poscross2, distcf] = line_continuity(poscross1,poscross2,2,distcf);
     
    xy1 = []; xy2 = []; xy1 = total1(poscross1,:); xy2 = total2(poscross2,:);
    if (length(xy1) > 20)
        xy1 = floor(sgolayfilt(xy1,3,15)); xy2 = floor(sgolayfilt(xy2,3,15));
    end
    xyout = vertcat(find(xy1(:,2) > size(U,2)), find(xy2(:,2) > size(U,2)));
    xy1(xyout,:) = []; xy2(xyout,:) = []; distcf(xyout) = [];

    % weak_signal only, visual only for now (see run_config.m): rebuild a
    % spike-free, hole-free mask from the tube's own shape for the
    % growth/roi_debug videos specifically -- U itself (used for
    % diamf_avg/ROI/tip-finding) is untouched. Uses t1_all/t2_all (NOT
    % the pipeline's own smoothed xy1/xy2 above) since width needs its own,
    % wider, decoupled-from-direction smoothing -- see reconstruct_smooth_mask.
    U_render = U;
    if weak_signal
        U_render = reconstruct_smooth_mask(U, boundb, xc, yc, dx, dy, distc, t1_all, t2_all, diamo, postotal1, postotal2);
    end

    % Cutoff the tip
    [tmp, distpos, tmp] = intersect(distc,distcf);
    distctf = [distct(1:cut-1); distc(distpos)]; xctf = [xct(1:cut-1); xc(distpos)]; yctf = [yct(1:cut-1); yc(distpos)]; 
    linectf = [yctf xctf];

    if (ROItype > 0)
        Esize = size(U);
        % Find ROI from centerline distance using percentages or distance
        % tip_excl_dist: total1/total2 always exclude boundary points within
        % diamo*0.75 px of tip_final (see postotal1/postotal2 above), so the
        % ROI side-curves always fall short of the tip by that radius. The
        % stitch (boundb(...postotal...)) is the only thing that closes that
        % gap, so it must fire whenever starti requests a start point inside
        % that always-excluded region — not merely when distc_t (an
        % unrelated tip-to-Qef distance) happens to exceed starti.
        if (pixelsize == 0)
            percent = (100*distctf)./(distctf(end));
            start_length = abs(percent - starti); [tmp startpos] = min(start_length);
            stop_length = abs(percent - stopi); [tmp stoppos] = min(stop_length);
            distc_t = (100*distc_t)/max(distctf);
            tip_excl_dist = (100*diamo*0.75)/max(distctf);
        else
            start_length = abs(distctf*pixelsize - starti); [tmp startpos] = min(start_length);
            stop_length = abs(distctf*pixelsize - stopi); [tmp stoppos] = min(stop_length);
            distc_t = distc_t*pixelsize;
            tip_excl_dist = diamo*0.75*pixelsize;
        end
        
        % Project ROI length onto the side curves.
        % Map the target physical distances (starti, stopi in µm) directly
        % onto the DENSE 100-pt centerline (distc in px / xc,yc) by
        % converting to pixels and finding the nearest-neighbour index.
        % This avoids distctf(startpos/stoppos) which can be wrong for
        % S-curved tubes where line_continuity leaves large gaps in distctf.
        if pixelsize > 0
            arc_start_px = starti / pixelsize;
            arc_stop_px  = min(stopi / pixelsize, distc(end));
        else
            arc_start_px = starti / 100 * distc(end);
            arc_stop_px  = stopi  / 100 * distc(end);
        end
        [~, k_start] = min(abs(distc - arc_start_px));
        [~, k_stop]  = min(abs(distc - arc_stop_px));
        k_start = max(1, min(k_start, length(xc)));
        k_stop  = max(1, min(k_stop,  length(xc)));

        % ROI start/stop boundary points, via the same construction as the
        % diameter cross-section search (see roi_boundary_crossing) instead
        % of closest_bound.m's own separate, cruder tangent estimate.
        % k_start's crossing search is anchored tip-side (see
        % nearest_crossing_to_sample's tip_anchor doc) -- k_stop is an
        % interior crossing with no such prior, so it keeps the default
        % Euclidean anchor. Constrained to land past k_start's own crossing
        % on each side (min_arclen) -- see nearest_crossing_to_sample's
        % min_arclen doc for the hairpin-collapse this guards against.
        [startc1, startc2] = roi_boundary_crossing(k_start, xc, yc, dx, dy, total1, al1, total2, al2, crossing_window, true);
        [stopc1,  stopc2]  = roi_boundary_crossing(k_stop,  xc, yc, dx, dy, total1, al1, total2, al2, crossing_window, false, al1(startc1), al2(startc2));

        % startc1/stopc1 and startc2/stopc2 are deliberately NOT swapped into
        % numeric order here (an earlier version of this code did, and it was
        % wrong -- see ordered_range's own comment for the full writeup: it
        % broke the pairing between "this side's crossing of the k_start
        % line" and "this side's crossing of the k_stop line" whenever side1
        % and side2 happened to be indexed in opposite directions along the
        % boundary for a given frame). startc1/startc2 always mean "this
        % side's crossing of the k_start line"; stopc1/stopc2 always mean
        % "...of the k_stop line" -- ordered_range (used below wherever a
        % slice is needed) handles whichever index direction that implies
        % per side, independently.
        if debug_mode
            fprintf('F%d: arcs %.1f->%.1f  k:%d->%d  c1:%d->%d  c2:%d->%d\n', ...
                count,arc_start_px,arc_stop_px,k_start,k_stop,startc1,stopc1,startc2,stopc2);
        end

        % tip_boundpos/tip_end1/tip_end2/cap_pts: computed once, up front,
        % and reused for BOTH the outer F polygon just below and the
        % roi1/roi2 stitch further down (see cap_boundary_arc/tip_cap_stitch).
        % The outer
        % polygon used to patch its own tip-ward gap with the raw
        % boundb(postotal2(1):postotal1(2),:) range instead -- the same
        % range the roi1/roi2 fix below already identified as wrong
        % (postotal1(2)/postotal2(1) are just the first elements past an
        % unrelated bisection point, not anchored to the tip at all). Since
        % F1/F2 = F .* roi1/roi2, a wrong/mismatched patch on the OUTER F
        % silently clips roi1/roi2 regardless of how correct they are --
        % confirmed on HV209_116 frame 1: F1/F2 still showed a notched,
        % disconnected edge after fixing roi1/roi2's own stitch, because F
        % itself was still cut along the old wrong range.
        if (starti < tip_excl_dist)
            tip_boundpos = dsearchn(boundb, tip_final(count,:));
            [~, near1] = min(abs(postotal1 - tip_boundpos)); tip_end1 = postotal1(near1);
            [~, near2] = min(abs(postotal2 - tip_boundpos)); tip_end2 = postotal2(near2);
            [cap_pts, end1_at_start] = cap_boundary_arc(boundb, tip_boundpos, tip_end1, tip_end2);
        end

        % Create masks for rectangles and circles, and include whether they are
        % normal, split or stationary
        if (ROItype ~= 2 | count == smp)
            if (circle == 0)
                roi = vertcat(total1(ordered_range(startc1,stopc1),:), total2(flip(ordered_range(startc2,stopc2)),:));
                if (starti < tip_excl_dist) roi = vertcat(cap_pts,roi); end
                F = poly2mask(roi(:,2),roi(:,1),Esize(1),Esize(2));
            else
                mask = zeros(Esize(1),Esize(2));
                roi = [linectf(stoppos,1) linectf(stoppos,2)];
                mask(roi(1),roi(2)) = 1;
                F = bwdist(mask) >= 0.5*circle.*diamo;
                F = imcomplement(F);
            end

            if (split == 1)
                if (circle > 0)
                    stoppos = length(linectf); stopc1 = length(total1); stopc2 = length(total2);
                end
                roi1 = vertcat(total1(ordered_range(startc1,stopc1),:), [yc(k_stop:-1:k_start), xc(k_stop:-1:k_start)]);
                roi2 = vertcat(total2(ordered_range(startc2,stopc2),:), [yc(k_stop:-1:k_start), xc(k_stop:-1:k_start)]);
                if (starti < tip_excl_dist)
                    % Stitch from the boundary point actually nearest the tip
                    % (tip_boundpos) to whichever element of postotal1/postotal2
                    % is actually closest to it BY BOUNDB INDEX -- not
                    % postotal1(2)/postotal2(1), which are just the first
                    % elements past an arbitrary bisection point
                    % (ceil(length(boundb)*0.5)) used only to split boundb into
                    % range1/range2 for the postotal1/postotal2 scan, unrelated
                    % to where the tip is. The two USUALLY sit close together
                    % (boundb's own start point often lands near the tip by
                    % convention), but not always -- confirmed on real data
                    % (HV207_24_left frame 1134-adjacent frames): when they
                    % don't, boundb(tip_boundpos:postotal1(2),:) walks a huge,
                    % wrong stretch of the boundary (270+ points instead of the
                    % ~20-point true tip cap) instead of erroring, so the old
                    % "usually close" assumption fails silently, not loudly.
                    % Verified on HV197_4_19 frames 2000-2043: valid frames went
                    % from 42/44 to 44/44 after the tip_boundpos change (kept);
                    % this closes the remaining gap in what it was anchored to.
                    % cap_pts/end1_at_start already computed above, up front
                    % (shared with the outer F polygon's own patch).
                    [stitch1, stitch2] = tip_cap_stitch(cap_pts, end1_at_start, xc, yc, dx, dy);
                    roi1 = vertcat(stitch1,roi1,boundb(tip_boundpos,:));
                    roi2 = vertcat(stitch2,roi2,boundb(tip_boundpos,:));
                end
                F1 = F.*poly2mask(roi1(:,2),roi1(:,1),Esize(1),Esize(2));
                F2 = F.*poly2mask(roi2(:,2),roi2(:,1),Esize(1),Esize(2));
                if debug_mode
                    roi_gap_px = min(pdist2(tip_final(count,:), vertcat(roi1,roi2)));
                    distc_t_unit = 'pct'; if (pixelsize > 0), distc_t_unit = 'um'; end
                    fprintf('  roi F%d: tip_final-to-ROI gap=%.1fpx (stitch_fired=%d, distc_t=%.2f%s, tip_excl_dist=%.2f%s)\n', ...
                        count, roi_gap_px, starti < tip_excl_dist, distc_t, distc_t_unit, tip_excl_dist, distc_t_unit);
                end
            end
        end
    
    
        % Rotate BT1 and BT2
        if (type == 1)
            BT1r = imrotate(BT1(:,:,count),-90);
            if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),-90); end
        elseif (type == 3)
            BT1r = imrotate(BT1(:,:,count),90);
            if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),90); end
        elseif (type == 4)
            BT1r = imrotate(BT1(:,:,count),180);
            if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),180); end
        else
            BT1r = BT1(:,:,count);
            if ~isempty(BT2), BT2r = BT2(:,:,count); end
        end
        
        
        % Calculate average intensities and pixel numbers
        if (max(O(:)) <= 255) FO = uint8(F);
        else FO = uint16(F);    
        end
        F = uint16(F);
        
        Fpixelnum(count) = nnz(O.*FO);
        intensityM(count) = sum(O(:))/nnz(O);
        if ~strcmp(mode, 'two_raw')
            intensityM_F(count) = sum(sum(O.*FO))/Fpixelnum(count);
            intensityB1_F(count) = sum(sum(BT1r.*F))/Fpixelnum(count);
            if ~isempty(BT2), intensityB2_F(count) = sum(sum(BT2r.*F))/Fpixelnum(count); end
        end

        if (split)
            if (max(O(:)) <= 255) F1O = uint8(F1); F2O = uint8(F2);
            else F1O = uint16(F1); F2O = uint16(F2);
            end

            F1 = uint16(F1);
            F2 = uint16(F2);

            F1pixelnum(count) = nnz(O.*F1O);
            F2pixelnum(count) = nnz(O.*F2O);
            if ~strcmp(mode, 'two_raw')
                intensityM_F1(count) = sum(sum(O.*F1O))/F1pixelnum(count);
                intensityB1_F1(count) = sum(sum(BT1r.*F1))/F1pixelnum(count);
                if ~isempty(BT2), intensityB2_F1(count) = sum(sum(BT2r.*F1))/F1pixelnum(count); end
                intensityM_F2(count) = sum(sum(O.*F2O))/F2pixelnum(count);
                intensityB1_F2(count) = sum(sum(BT1r.*F2))/F2pixelnum(count);
                if ~isempty(BT2), intensityB2_F2(count) = sum(sum(BT2r.*F2))/F2pixelnum(count); end
            end
        end
        
        % Histogram of first and last frame (smp=col1, stp=col2)
        if (distributions)
            if (count == stp || count == smp)
                Msize = [numel(O),1]; BT1size = [numel(BT1r),1];
                Mhist(:,d) = reshape(O,Msize);
                B1hist(:,d) = reshape(BT1r,BT1size);
                MhistF(:,d) = reshape(O.*FO,Msize);
                B1histF(:,d) = reshape(BT1r.*F,BT1size);
                if ~isempty(BT2)
                    BT2size = [numel(BT2r),1];
                    B2hist(:,d) = reshape(BT2r,BT2size);
                    B2histF(:,d) = reshape(BT2r.*F,BT2size);
                end
                d = d+1;
            end
        end
    end
    
    % Cut off the tip part of the diameter calculation if necessary
    if (pixelsize > 0) cutoffp = dsearchn(distcf',diamcutoff/pixelsize);
    else cutoffp = dsearchn(distcf',diamcutoff);
    end
    if (cutoffp > 1) xy1(cutoffp-1,:) = []; xy2(cutoffp-1,:) = []; end

    % Diameter of tube
    % Median, not mean: a plain mean lets a handful of bad cross-section
    % samples (most often right at a bend -- see nearest_crossing_to_sample
    % above, which reduces but doesn't eliminate these) drag the whole
    % frame's reported diameter. Median is robust to exactly that without
    % needing to know which samples are bad.
    diamf = diag(pdist2(xy1,xy2));
    diamf_avg(count) = median(diamf);

    % Stationary-lock finalization (diameter half) -- see the guard's own
    % doc block near the top of this script, and stationary_pos_ok_this_frame's
    % comment (in the tip_final_last update, ~900 lines up) for why this is
    % split into two touch points instead of computed in one place:
    % diamf_avg(count) just above is the first point in this iteration
    % where the smoothed, actually-bit-identical-on-a-stuck-lock diameter
    % exists at all.
    if ~frame_failed(count)
        if exist('diamf_avg_last', 'var') && stationary_pos_ok_this_frame && ...
                isfinite(diamf_avg(count)) && abs(diamf_avg(count) - diamf_avg_last) < stationary_diam_eps_px
            stationary_streak = stationary_streak + 1;
        else
            stationary_streak = 0;
        end
        diamf_avg_last = diamf_avg(count);
    end

    % Kymograph
    if (nkymo > 0)
        kymo_len = ceil(path_dist(end));

        % Save smp centerline for the fixed-line kymograph
        if (count == smp)
            yctk_smp = yctk; xctk_smp = xctk;
            kymo_len_smp = kymo_len;
            start_nfitc_smp = start_nfitc;
        end

        % Rotate L frame to match the rotated coordinate frame used for centerline
        Lframe = L(:,:,count);
        if (type == 1) Lframe = imrotate(Lframe,-90);
        elseif (type == 3) Lframe = imrotate(Lframe,90);
        elseif (type == 4) Lframe = imrotate(Lframe,180);
        end

        % Per-frame centerline kymograph
        linecte = []; linecte(:,:,1) = [yctk, xctk];
        for a = 2:nkymo
            if (mod(a,2) == 0), ind = floor(a*0.5);
            else, ind = -floor(a*0.5); end
            if (start_nfitc(1) < 0)
                if (mod(a,2) == 0), linecte(:,:,a) = [yctk+ind, xctk-ind];
                else, linecte(:,:,a) = [yctk-ind, xctk+ind]; end
            else
                if (mod(a,2) == 0), linecte(:,:,a) = [yctk+ind, xctk+ind];
                else, linecte(:,:,a) = [yctk-ind, xctk-ind]; end
            end
        end
        kymo = [];
        for a = 1:nkymo
            kymo(:,a) = improfile(imgaussfilt(Lframe,1.5), linecte(:,2,a), linecte(:,1,a), double(kymo_len));
        end
        kymo(isnan(kymo)) = 0;
        % kymo_avg's row count used to be fixed once from whichever frame was
        % processed first (5+npoints, from count==smp). That frame's path length
        % is not a reliable upper bound (e.g. bleach movies: mask/path length
        % varies a lot with brightness across the stack), so a later frame with
        % a longer path than that would overflow the column height and throw.
        % Grow kymo_avg on demand instead, and keep a kymo-only failure from
        % taking down tip/diameter data already computed earlier this frame.
        try
            kymo_col = mean(kymo,2);
            needed_rows = numel(kymo_col) + 5;
            if ~exist('kymo_avg','var') || isempty(kymo_avg)
                kymo_avg = zeros(needed_rows, smp-stp+1);
            elseif needed_rows > size(kymo_avg,1)
                kymo_avg = vertcat(zeros(needed_rows - size(kymo_avg,1), size(kymo_avg,2)), kymo_avg);
            end
            kymo_avg(:,count-stp+1) = vertcat(zeros(size(kymo_avg,1) - numel(kymo_col),1), kymo_col);
        catch kymoErr
            warning('TIGRMUM: kymo_avg update failed on frame %d — %s', count, kymoErr.message);
        end

        % Fixed-line kymograph using smp centerline for all frames
        linecte_f = []; linecte_f(:,:,1) = [yctk_smp, xctk_smp];
        for a = 2:nkymo
            if (mod(a,2) == 0), ind = floor(a*0.5);
            else, ind = -floor(a*0.5); end
            if (start_nfitc_smp(1) < 0)
                if (mod(a,2) == 0), linecte_f(:,:,a) = [yctk_smp+ind, xctk_smp-ind];
                else, linecte_f(:,:,a) = [yctk_smp-ind, xctk_smp+ind]; end
            else
                if (mod(a,2) == 0), linecte_f(:,:,a) = [yctk_smp+ind, xctk_smp+ind];
                else, linecte_f(:,:,a) = [yctk_smp-ind, xctk_smp-ind]; end
            end
        end
        kymo_f = [];
        for a = 1:nkymo
            kymo_f(:,a) = improfile(imgaussfilt(Lframe,1.5), linecte_f(:,2,a), linecte_f(:,1,a), double(kymo_len_smp));
        end
        kymo_f(isnan(kymo_f)) = 0;
        kymo_avg_fixed(:,count-stp+1) = vertcat(zeros((5 + npoints - kymo_len_smp),1), mean(kymo_f,2));
    end

    % Tip plot / ROI debug frame: rendered here exactly as before, but
    % BUFFERED rather than written to disk immediately -- see the buffered-
    % video block comment above growth_buf/roi_buf's pre-allocation. Skip
    % the tip marker/ROI shading entirely on a frame_failed frame -- same
    % reasoning as before (confirmed on HV198_1_16 frame 3314/3321: a
    % rejected point drawn as if valid). tip_final still holds a numeric
    % point either way (needed above for centerline/ROI to have something
    % to work with).
    show_overlay = ~frame_failed(count);
    if (tip_plot)
        growth_buf{count} = render_growth_frame(U_render, tip_final(count,:), yctk, xctk, F1, F2, ROItype, show_overlay, count, frame_rate);
        if isempty(V_frame_size), V_frame_size = size(growth_buf{count}); end
    end

    if roi_debug_video
        % O, not L: L is built once for the whole stack and is never
        % per-frame rotated, while O/U/F1/F2 all are (see the imrotate
        % block earlier in this loop) -- using L here would misalign the
        % overlay against the ROI geometry.
        roi_buf{count} = render_roi_debug_frame(O, U_render, yctk, xctk, F1, F2, ROItype, show_overlay, up_factor, Cmax, count, frame_rate);
        if isempty(Vroi_frame_size), Vroi_frame_size = size(roi_buf{count}); end
    end
    catch ME
        warning('TIGRMUM: frame %d failed — %s (%s:%d)', count, ME.message, ME.stack(1).name, ME.stack(1).line);
        frame_failed(count) = true;
        if tip_plot && ~isempty(V_frame_size)
            growth_buf{count} = zeros(V_frame_size, 'uint8');
        end
        if roi_debug_video && ~isempty(Vroi_frame_size)
            roi_buf{count} = zeros(Vroi_frame_size, 'uint8');
        end
        % Fixed-line kymograph: computable from L alone, fill even on failure
        if nkymo > 0 && exist('yctk_smp','var')
            Lframe = L(:,:,count);
            if (type == 1), Lframe = imrotate(Lframe,-90);
            elseif (type == 3), Lframe = imrotate(Lframe,90);
            elseif (type == 4), Lframe = imrotate(Lframe,180);
            end
            linecte_f = []; linecte_f(:,:,1) = [yctk_smp, xctk_smp];
            for a = 2:nkymo
                if (mod(a,2) == 0), ind = floor(a*0.5);
                else, ind = -floor(a*0.5); end
                if (start_nfitc_smp(1) < 0)
                    if (mod(a,2) == 0), linecte_f(:,:,a) = [yctk_smp+ind, xctk_smp-ind];
                    else, linecte_f(:,:,a) = [yctk_smp-ind, xctk_smp+ind]; end
                else
                    if (mod(a,2) == 0), linecte_f(:,:,a) = [yctk_smp+ind, xctk_smp+ind];
                    else, linecte_f(:,:,a) = [yctk_smp-ind, xctk_smp-ind]; end
                end
            end
            kymo_f = [];
            for a = 1:nkymo
                kymo_f(:,a) = improfile(imgaussfilt(Lframe,1.5), linecte_f(:,2,a), linecte_f(:,1,a), double(kymo_len_smp));
            end
            kymo_f(isnan(kymo_f)) = 0;
            kymo_avg_fixed(:,count-stp+1) = vertcat(zeros((5 + npoints - kymo_len_smp),1), mean(kymo_f,2));
        end
    end
end
warning('on', 'MATLAB:nearlySingularMatrix');

% Forward repair pass (weak_signal only): frames flagged severed/noisy/
% border-touch-failed (needs_repair) or diam_tol/tip_jump-failed
% (frame_failed) in the reverse pass above get one attempt at repair,
% walked in chronological order (stp:smp) so max_tip_jump_um can be used
% constructively as a lower bound on where the tip should be, instead of
% only as a post-hoc reject test. Only overwrites the specific frames it
% succeeds on -- anything it can't fix is left flagged for the existing
% NaN-fill below, exactly as if this pass didn't run.
if weak_signal && exist('U_smp', 'var')
    prev_tip_fwd = [];
    n_repaired = 0; n_attempted = 0;
    for count = stp:smp
        if ~(needs_repair(count) || frame_failed(count))
            if isfinite(tip_final(count,1))
                prev_tip_fwd = tip_final(count,:);
            end
            continue;
        end
        if isempty(U_cache{count})
            continue; % nothing cached -- leave flagged
        end
        n_attempted = n_attempted + 1;
        try
            U_rep = build_repaired_mask(U_cache{count}, U_smp, prev_tip_fwd, max_tip_jump_um, pixelsize);

            O = M(:,:,count);
            if (type == 1) O = imrotate(O,-90);
            elseif (type == 3) O = imrotate(O,90);
            elseif (type == 4) O = imrotate(O,180);
            end
            if (type == 1)
                BT1r = imrotate(BT1(:,:,count),-90);
                if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),-90); else, BT2r = []; end
            elseif (type == 3)
                BT1r = imrotate(BT1(:,:,count),90);
                if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),90); else, BT2r = []; end
            elseif (type == 4)
                BT1r = imrotate(BT1(:,:,count),180);
                if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),180); else, BT2r = []; end
            else
                BT1r = BT1(:,:,count);
                if ~isempty(BT2), BT2r = BT2(:,:,count); else, BT2r = []; end
            end

            old_intens = struct('Fpixelnum', Fpixelnum(count), 'intensityM', intensityM(count), ...
                'intensityM_F', intensityM_F(count), 'intensityB1_F', intensityB1_F(count), ...
                'intensityB2_F', intensityB2_F(count), 'F1pixelnum', F1pixelnum(count), ...
                'F2pixelnum', F2pixelnum(count), 'intensityM_F1', intensityM_F1(count), ...
                'intensityB1_F1', intensityB1_F1(count), 'intensityB2_F1', intensityB2_F1(count), ...
                'intensityM_F2', intensityM_F2(count), 'intensityB1_F2', intensityB1_F2(count), ...
                'intensityB2_F2', intensityB2_F2(count));

            [tip_row, diamf_val, intens, ok, yctk_rep, xctk_rep, F1_rep, F2_rep, U_smooth_rep] = find_tip_and_measure(count, U_rep, prev_tip_fwd, ...
                weight, diamo, tip_method, pixelsize, ROItype, split, circle, starti, stopi, ...
                diamcutoff, mode, O, BT1r, BT2r, old_intens, debug_mode, max_tip_jump_um, ellipse_fit_method, ellipse_candidate_max_jump_factor);

            if ok
                tip_final(count,:) = tip_row;
                diamf_avg(count) = diamf_val;
                intensityM(count) = intens.intensityM;
                intensityM_F(count) = intens.intensityM_F;
                Fpixelnum(count) = intens.Fpixelnum;
                intensityB1_F(count) = intens.intensityB1_F;
                intensityB2_F(count) = intens.intensityB2_F;
                intensityM_F1(count) = intens.intensityM_F1;
                intensityM_F2(count) = intens.intensityM_F2;
                F1pixelnum(count) = intens.F1pixelnum;
                F2pixelnum(count) = intens.F2pixelnum;
                intensityB1_F1(count) = intens.intensityB1_F1;
                intensityB2_F1(count) = intens.intensityB2_F1;
                intensityB1_F2(count) = intens.intensityB1_F2;
                intensityB2_F2(count) = intens.intensityB2_F2;
                frame_failed(count) = false;
                prev_tip_fwd = tip_row;
                n_repaired = n_repaired + 1;
                % Re-render this frame's buffered video content from the
                % REPAIRED mask/tip/ROI now that it's known good -- the
                % video is flushed to disk only after this whole pass (see
                % below), so this replaces whatever the reverse pass's
                % (since-discarded) attempt looked like before anyone ever
                % sees it.
                if tip_plot
                    growth_buf{count} = render_growth_frame(U_smooth_rep, tip_row, yctk_rep, xctk_rep, F1_rep, F2_rep, ROItype, true, count, frame_rate);
                end
                if roi_debug_video
                    roi_buf{count} = render_roi_debug_frame(O, U_smooth_rep, yctk_rep, xctk_rep, F1_rep, F2_rep, ROItype, true, up_factor, Cmax, count, frame_rate);
                end
                if debug_mode
                    fprintf('  [repair] F%d: REPAIRED\n', count);
                end
            else
                if debug_mode
                    fprintf('  [repair] F%d: repair attempted but still failed -- left flagged\n', count);
                end
            end
        catch ME_rep
            if debug_mode
                fprintf('  [repair] F%d: repair threw -- %s -- left flagged\n', count, ME_rep.message);
            end
        end
    end
    if debug_mode
        fprintf('Forward repair pass: %d/%d flagged frames repaired\n', n_repaired, n_attempted);
    end
end

% Flush the buffered video frames to disk now, in TRUE CHRONOLOGICAL order
% (stp:smp) rather than the reverse pass's own processing order (smp:-1:
% stp) -- both because repaired frames' content is only settled at this
% point (after the pass above), and because writing in real time order
% means the video now actually plays forward like a growth movie, instead
% of the tip visibly receding as playback progressed.
if (tip_plot == 1)
    for count = stp:smp
        if ~isempty(growth_buf{count})
            writeVideo(V, growth_buf{count});
        end
    end
    close(V);
end
if roi_debug_video
    for count = stp:smp
        if ~isempty(roi_buf{count})
            writeVideo(Vroi, roi_buf{count});
        end
    end
    close(Vroi);
end

% Resolve the FWHM diameter correction factor (see fwhm_diameter_correction
% and the calibration hook in the main per-frame loop above). PER-FRAME,
% not a single run-level number -- an earlier version used one global
% median factor, but confirmed on real data (HV208_100, frames 1-300,
% otherwise unperturbed) that the bias this corrects for is NOT actually
% constant: the raw mask-based diameter drifted -6.6% over that stretch
% while an independent FWHM ground truth stayed flat (-1.9%, i.e. noise)
% -- a threshold/SNR artifact (bleaching narrows the mask even though the
% true tube width hasn't moved), not a real diameter change. A single
% global factor can only rescale the whole curve, not remove a trend, so
% it silently carried that same -6.6% drift straight through into
% "corrected" too. Fix: interpolate the correction factor between
% calibration passes (mild moving-median smoothing across
% fwhm_calib_window passes first, since any one pass's ratio is only
% fwhm_calib_samples points), so a real, slow drift in the bias gets
% tracked and removed instead of baked into the output. Frames outside
% the calibrated range hold the nearest edge value rather than
% extrapolating a trend past where it was actually measured. Resolved
% BEFORE fig1 below (not just at CSV export) so the "Average Diameter"
% panel can plot the corrected trace too.
fwhm_correction_factor_by_frame = ones(numel(stp:smp), 1);
if fwhm_diameter_correction
    if numel(fwhm_calib_pass_frame) >= 2
        [pf_sorted, sidx] = sort(fwhm_calib_pass_frame(:));
        pr_sorted = fwhm_calib_pass_ratio(sidx);
        if fwhm_calib_window > 1
            pr_smooth = movmedian(pr_sorted, fwhm_calib_window);
        else
            pr_smooth = pr_sorted;
        end
        all_frames = (stp:smp)';
        fwhm_correction_factor_by_frame = interp1(pf_sorted, pr_smooth, all_frames, 'linear');
        fwhm_correction_factor_by_frame(all_frames < pf_sorted(1))   = pr_smooth(1);
        fwhm_correction_factor_by_frame(all_frames > pf_sorted(end)) = pr_smooth(end);
        fprintf('FWHM diameter calibration: %d passes (%d samples total), factor range %.3f-%.3f, median %.3f\n', ...
            numel(pf_sorted), numel(fwhm_calib_mask_px), min(pr_smooth), max(pr_smooth), median(pr_smooth));
    else
        warning('TIGRMUM: fwhm_diameter_correction enabled but only %d calibration pass(es) collected (need >=2 to interpolate a trend) -- Diameter_um_corrected left uncorrected (factor=1).', numel(fwhm_calib_pass_frame));
    end
    if ~isempty(fwhm_calib_pass_frame)
        Tcal = table(fwhm_calib_pass_frame(:), fwhm_calib_pass_n(:), ...
                     fwhm_calib_pass_mask_med(:), fwhm_calib_pass_fwhm_med(:), fwhm_calib_pass_ratio(:), ...
                     'VariableNames', {'Frame', 'N_samples', 'Mask_median_px', 'FWHM_median_px', 'Ratio'});
        writetable(Tcal, fullfile(outpath, [fname '_fwhm_calibration.csv']));
        disp(['FWHM calibration log saved: ' fullfile(outpath, [fname '_fwhm_calibration.csv'])]);
    end
end

% Final tip movement/diameter/pixel number on a per frame basis
fig1 = figure;
if strcmp(mode, 'two_raw')
    nsp = 2;
else
    nsp = 3;
end
subplot(nsp,1,1)
plot(tip_final(stp:smp,2),tip_final(stp:smp,1),'b')
tf = tip_final(stp:smp,:); tf = tf(all(isfinite(tf),2),:);
if ~isempty(tf), axis([min(tf(:,2))-5 max(tf(:,2))+5 min(tf(:,1))-5 max(tf(:,1))+5]); end
title('Tip Final Position', 'FontSize',16);

subplot(nsp,1,2)
dvals = diamf_avg(stp:smp); dvals = dvals(isfinite(dvals));
% Corrected (FWHM-calibrated) trace, same computation the CSV's
% Diameter_um_corrected column uses below -- plotted alongside the raw
% trace (not instead of it) so the correction's actual effect is visible
% directly in the figure, not just in the CSV. Equal to the raw trace
% whenever fwhm_diameter_correction is off.
diam_corrected_px = diamf_avg(stp:smp)' .* fwhm_correction_factor_by_frame;
dvals_c = diam_corrected_px(isfinite(diam_corrected_px));
maxval = max([dvals, dvals_c']);
% Extra headroom (1.6x instead of the usual 1.25x) ONLY when the
% FWHM-corrected legend is drawn -- gives the legend genuinely empty space
% to sit in above both curves (top ~37% of the panel) instead of hoping a
% corner happens to be clear. A specific corner ('northeast' etc.) was
% tried first and still covered real data on real output (HV209_85) --
% picking a corner assumes the data leaves one clear, which isn't
% guaranteed; carving out real headroom is. 'northeastoutside' was tried
% too and made exportgraphics hang in headless MATLAB (confirmed on real
% data) -- stays inside the axes.
if fwhm_diameter_correction, headroom = 1.6; else, headroom = 1.25; end
% Name the raw trace after whichever threshold method actually produced
% it (and its sensitivity, for otsu specifically -- the only method that
% multiplier applies to) so the figure is self-describing about which
% mask bias it's showing, without needing to cross-reference the CSV.
if strcmp(threshold_method, 'otsu')
    raw_label = sprintf('raw (otsu, %.2g)', otsu_sensitivity);
else
    raw_label = sprintf('raw (%s)', threshold_method);
end
if (pixelsize > 0)
    plot(stp:smp, diamf_avg(stp:smp)*pixelsize, 'b')
    hold on
    if fwhm_diameter_correction
        plot(stp:smp, diam_corrected_px*pixelsize, 'r')
        legend(raw_label, 'FWHM-corrected', 'Location', 'northeast')
    end
    ylabel('µm', 'FontSize',12);
    if ~isempty(dvals), axis([stp-1 smp+1 0.5*maxval*pixelsize headroom*maxval*pixelsize]); end
else
    plot(stp:smp, diamf_avg(stp:smp), 'b')
    hold on
    if fwhm_diameter_correction
        plot(stp:smp, diam_corrected_px, 'r')
        legend(raw_label, 'FWHM-corrected', 'Location', 'northeast')
    end
    ylabel('pixels', 'FontSize',12);
    if ~isempty(dvals), axis([stp-1 smp+1 0.5*maxval headroom*maxval]); end
end
xlabel('Frame', 'FontSize',12);
title('Average Diameter','FontSize',16)

if ~strcmp(mode, 'two_raw')
    subplot(nsp,1,3)
    plot(stp:smp,intensityM(stp:smp),'k') % whole-image intensity
    hold on
    plot(stp:smp,intensityM_F(stp:smp),'r') % full ROI
    if (split)
        plot(stp:smp,intensityM_F1(stp:smp),'b*') % split ROI 1
        plot(stp:smp,intensityM_F2(stp:smp),'g*') % split ROI 2
    end
    xlabel('Frame', 'FontSize',12);
    if strcmp(mode, 'ratio')
        title('Intensity Ratio', 'FontSize',16)
    else
        title('Intensity (Acceptor)', 'FontSize',16)
    end
    % Scale axis to include all plotted values (whole-tube + ROI)
    all_vals = [intensityM(stp:smp), intensityM_F(stp:smp)];
    if (split), all_vals = [all_vals, intensityM_F1(stp:smp), intensityM_F2(stp:smp)]; end
    all_vals = all_vals(isfinite(all_vals) & all_vals > 0);
    if ~isempty(all_vals)
        axis([stp-1 smp+1 min(all_vals)*0.75 max(all_vals)*1.25]);
    end
end
savefig(fig1, fullfile(figpath, [fname '_tip_diam_intensity.fig']));
exportgraphics(fig1, fullfile(figpath, [fname '_tip_diam_intensity.png']));

% Kymograph (per-frame centerline)
if (nkymo > 0) && exist('kymo_avg','var') && ~isempty(kymo_avg)
    kymo_avg(find(kymo_avg<0)) = 0;
    fig2 = figure;
    map = colormap(jet(255));
    map = vertcat([0 0 0],map);
    kymo_img = uint8(kymo_avg.*255/max(kymo_avg(:)));
    imshow(kymo_img, map);
    savefig(fig2, fullfile(figpath, [fname '_kymograph.fig']));
    imwrite(ind2rgb(kymo_img, map), fullfile(figpath, [fname '_kymograph.png']));

    % Fixed-line kymograph (smp centerline applied to all frames)
    if exist('kymo_avg_fixed','var') && ~isempty(kymo_avg_fixed)
    kymo_avg_fixed(find(kymo_avg_fixed<0)) = 0;
    fig2b = figure;
    map = colormap(jet(255));
    map = vertcat([0 0 0],map);
    kymo_img_f = uint8(kymo_avg_fixed.*255/max(kymo_avg_fixed(:)));
    imshow(kymo_img_f, map);
    savefig(fig2b, fullfile(figpath, [fname '_kymograph_fixed_line.fig']));
    imwrite(ind2rgb(kymo_img_f, map), fullfile(figpath, [fname '_kymograph_fixed_line.png']));
    end  % kymo_avg_fixed guard
end  % nkymo > 0

% Total intensity plots (ratio trace only available with ratio stack)
if (ROItype > 0) && strcmp(mode, 'ratio')
    fig3 = figure;
    if (split)
        F1ratio = intensityB1_F1(stp:smp)./intensityB2_F1(stp:smp);
        subplot(1,3,2)
        hold on
        plot(stp:smp,F1ratio,'b')
        axis([stp-1 smp+1 0.8 max(F1ratio(:))*1.25]);
        title('Intensity F1 (split ROI 1)'); xlabel('Frame');
       
        F2ratio = intensityB1_F2(stp:smp)./intensityB2_F2(stp:smp);
        subplot(1,3,3)
        hold on
        plot(stp:smp,F2ratio,'b')
        axis([stp-1 smp+1 0.8 max(F1ratio(:))*1.25]);
        title('Intensity F2 (split ROI 2)'); xlabel('Frame');
       
        subplot(1,3,1); 
        plot(stp:smp,F2ratio./F1ratio,'b')
        axis([stp-1 smp+1 0.5 2]);
        title('Intensity ratio between split ROIs'); xlabel('Frame');
    else
        Fratio = intensityB1_F(stp:smp)./intensityB2_F(stp:smp);
        hold on
        plot(stp:smp,Fratio,'b');
        axis([stp-1 smp+1 0.8 max(Fratio(:))*1.25]);
        title('Intensity F'); xlabel('Frame');
    end
    savefig(fig3, fullfile(figpath, [fname '_intensity_ratio.fig']));
    exportgraphics(fig3, fullfile(figpath, [fname '_intensity_ratio.png']));
end

% ROI intensity figure for single-channel and two_raw modes
if (ROItype > 0) && ~strcmp(mode, 'ratio')
    fig3 = figure;
    F1v = intensityM_F1(stp:smp); F2v = intensityM_F2(stp:smp); Fv = intensityM_F(stp:smp);
    if (split)
        subplot(1,2,1)
        hold on
        plot(stp:smp, Fv,  'k'); plot(stp:smp, F1v, 'b'); plot(stp:smp, F2v, 'g');
        legend('Full ROI','Half 1','Half 2','Location','best');
        xlabel('Frame'); title('ROI Intensity (Acceptor)', 'FontSize',14);
        all_v = [Fv, F1v, F2v]; all_v = all_v(isfinite(all_v) & all_v > 0);
        if ~isempty(all_v), axis([stp-1 smp+1 min(all_v)*0.85 max(all_v)*1.15]); end

        subplot(1,2,2)
        ratio_12 = F2v ./ F1v;
        plot(stp:smp, ratio_12, 'k');
        xlabel('Frame'); title('Intensity Ratio Half2/Half1', 'FontSize',14);
        rv = ratio_12(isfinite(ratio_12) & ratio_12 > 0);
        if ~isempty(rv), axis([stp-1 smp+1 min(rv)*0.85 max(rv)*1.15]); end
    else
        plot(stp:smp, Fv, 'r');
        xlabel('Frame'); title('ROI Intensity (Acceptor)', 'FontSize',14);
        all_v = Fv(isfinite(Fv) & Fv > 0);
        if ~isempty(all_v), axis([stp-1 smp+1 min(all_v)*0.85 max(all_v)*1.15]); end
    end
    savefig(fig3, fullfile(figpath, [fname '_roi_intensity.fig']));
    exportgraphics(fig3, fullfile(figpath, [fname '_roi_intensity.png']));
end

% NaN-fill failed frames so CSV shows NaN instead of 0
if any(frame_failed(stp:smp))
    fi = find(frame_failed);
    fi = fi(fi >= stp & fi <= smp);
    tip_final(fi,:) = NaN;
    Ucount(fi) = NaN;
    diamf_avg(fi) = NaN;
    intensityM(fi) = NaN;
    if ROItype > 0
        intensityM_F(fi) = NaN; Fpixelnum(fi) = NaN;
        intensityB1_F(fi) = NaN;
        if ~isempty(BT2), intensityB2_F(fi) = NaN; end
        if split
            intensityM_F1(fi) = NaN; F1pixelnum(fi) = NaN;
            intensityM_F2(fi) = NaN; F2pixelnum(fi) = NaN;
        end
    end
end

% CSV export of per-frame measurements
% Intensities are mean per non-zero pixel inside each mask.
% Total signal = mean × pixel_count.
csv_frames  = (stp:smp)';
csv_time_s  = (csv_frames - 1) .* frame_rate; % Frame 1 = t=0, matching the video overlays
csv_tip_row = tip_final(stp:smp, 1);
csv_tip_col = tip_final(stp:smp, 2);
csv_diam_px = diamf_avg(stp:smp)';
csv_diam_um = csv_diam_px .* pixelsize;
% Diameter_um_corrected: Diameter_um scaled by fwhm_correction_factor_by_frame
% (see above, PER-FRAME not a single scalar) -- equal to Diameter_um
% wherever fwhm_diameter_correction is off or calibration didn't collect
% enough passes (factor stays 1 there). Always present (not gated behind
% fwhm_diameter_correction) so a run's CSV format doesn't change shape
% based on that setting.
csv_diam_um_corrected = csv_diam_um .* fwhm_correction_factor_by_frame;
csv_wtmean  = intensityM(stp:smp)';
csv_overlap = Ucount(stp:smp)';
% ringwalk_fallback_to_skeleton only: 1 if this row's tip came from
% skeleton_tip_fallback (whether or not it ultimately passed the jump
% check), 0 otherwise. NOT NaN'd for frame_failed rows below -- distinct
% from the measurement columns, this should still record that recovery was
% attempted/used even when the frame is still flagged, so the CSV
% distinguishes "fallback tried and failed" from "fallback never applicable".
csv_fb_used = double(tip_recovered_via_skeleton(stp:smp));

if (ROItype > 0)
    csv_roi_npx   = Fpixelnum(stp:smp)';
    csv_roi_mean  = intensityM_F(stp:smp)';
    csv_roi_total = csv_roi_mean .* csv_roi_npx;

    if (split)
        csv_h1_npx   = F1pixelnum(stp:smp)';
        csv_h1_mean  = intensityM_F1(stp:smp)';
        csv_h1_total = csv_h1_mean .* csv_h1_npx;
        csv_h2_npx   = F2pixelnum(stp:smp)';
        csv_h2_mean  = intensityM_F2(stp:smp)';
        csv_h2_total = csv_h2_mean .* csv_h2_npx;
        csv_ratio_h2h1 = csv_h2_mean ./ csv_h1_mean;

        T = table(csv_frames, csv_time_s, csv_tip_row, csv_tip_col, ...
                  csv_diam_px, csv_diam_um, csv_diam_um_corrected, csv_overlap, csv_wtmean, ...
                  csv_roi_npx, csv_roi_mean, csv_roi_total, ...
                  csv_h1_npx, csv_h1_mean, csv_h1_total, ...
                  csv_h2_npx, csv_h2_mean, csv_h2_total, csv_ratio_h2h1, csv_fb_used, ...
                  'VariableNames', { ...
                  'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
                  'Diameter_px', 'Diameter_um', 'Diameter_um_corrected', 'Frame_overlap_ratio', 'WholeTube_mean_intensity', ...
                  'ROI_pixel_count', 'ROI_mean_intensity', 'ROI_total_signal', ...
                  'Half1_pixel_count', 'Half1_mean_intensity', 'Half1_total_signal', ...
                  'Half2_pixel_count', 'Half2_mean_intensity', 'Half2_total_signal', ...
                  'Ratio_Half2_Half1', 'Tip_skeleton_fallback_used'});
    else
        T = table(csv_frames, csv_time_s, csv_tip_row, csv_tip_col, ...
                  csv_diam_px, csv_diam_um, csv_diam_um_corrected, csv_overlap, csv_wtmean, ...
                  csv_roi_npx, csv_roi_mean, csv_roi_total, csv_fb_used, ...
                  'VariableNames', { ...
                  'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
                  'Diameter_px', 'Diameter_um', 'Diameter_um_corrected', 'Frame_overlap_ratio', 'WholeTube_mean_intensity', ...
                  'ROI_pixel_count', 'ROI_mean_intensity', 'ROI_total_signal', 'Tip_skeleton_fallback_used'});
    end
else
    T = table(csv_frames, csv_time_s, csv_tip_row, csv_tip_col, ...
              csv_diam_px, csv_diam_um, csv_diam_um_corrected, csv_overlap, csv_wtmean, csv_fb_used, ...
              'VariableNames', { ...
              'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
              'Diameter_px', 'Diameter_um', 'Diameter_um_corrected', 'Frame_overlap_ratio', 'WholeTube_mean_intensity', 'Tip_skeleton_fallback_used'});
end
writetable(T, fullfile(outpath, [fname '_measurements.csv']));
disp(['CSV saved: ' fullfile(outpath, [fname '_measurements.csv'])]);

% Distributions of intensity on the first and last frames (col1=smp, col2=stp)
if (distributions == 1)
    Mhist = double(Mhist); MhistF = double(MhistF);
    B1hist = double(B1hist); B1histF = double(B1histF);

    figd1 = figure;
    subplot(1,2,1)
    histogram(Mhist(Mhist(:,1)>0.1,1)); hold on;
    if size(Mhist,2) >= 2, histogram(Mhist(Mhist(:,2)>0.1,2)); end
    title('Histogram C')
    subplot(1,2,2)
    histogram(MhistF(MhistF(:,1)>0.1,1)); hold on;
    if size(MhistF,2) >= 2, histogram(MhistF(MhistF(:,2)>0.1,2)); end
    title('Histogram CF')
    savefig(figd1, fullfile(figpath, [fname '_hist_C.fig']));
    exportgraphics(figd1, fullfile(figpath, [fname '_hist_C.png']));

    figd2 = figure;
    subplot(1,2,1)
    histogram(B1hist(B1hist(:,1)>0.1,1)); hold on;
    if size(B1hist,2) >= 2, histogram(B1hist(B1hist(:,2)>0.1,2)); end
    title('Histogram B1')
    subplot(1,2,2)
    histogram(B1histF(B1histF(:,1)>0.1,1)); hold on;
    if size(B1histF,2) >= 2, histogram(B1histF(B1histF(:,2)>0.1,2)); end
    title('Histogram B1F')
    savefig(figd2, fullfile(figpath, [fname '_hist_B1.fig']));
    exportgraphics(figd2, fullfile(figpath, [fname '_hist_B1.png']));

    if ~isempty(BT2)
        B2hist = double(B2hist); B2histF = double(B2histF);
        figd3 = figure;
        subplot(1,2,1)
        histogram(B2hist(B2hist(:,1)>0.1,1)); hold on;
        if size(B2hist,2) >= 2, histogram(B2hist(B2hist(:,2)>0.1,2)); end
        title('Histogram B2')
        subplot(1,2,2)
        histogram(B2histF(B2histF(:,1)>0.1,1)); hold on;
        if size(B2histF,2) >= 2, histogram(B2histF(B2histF(:,2)>0.1,2)); end
        title('Histogram B2F')
        savefig(figd3, fullfile(figpath, [fname '_hist_B2.fig']));
        exportgraphics(figd3, fullfile(figpath, [fname '_hist_B2.png']));
    end
end

diary off;

if (workspace) save([outpath '/' fname '_result.mat']); end

% ============================================================================
% Multi-blob keep-and-bridge (weak_signal only). Used at TWO points in the
% main loop's mask-building (right after bwareaopen, and again after
% imclose) instead of a plain bwareafilt(U,1): a genuine tube fragment
% (most often the bright GCaMP tip itself) can survive as a component
% separate from the main piece rather than actually merging with it -- the
% two can look connected at low zoom without truly being one component.
% Plain bwareafilt(U,1) then keeps only whichever piece has more total
% pixels and silently discards the other, regardless of size -- confirmed
% on HV198_1_16 frame 3321: a bright, well-formed GCaMP tip blob (1121px,
% comparable width to the rest of the tube) got discarded outright because
% the dimmer shank piece happened to have slightly more pixels. Has to run
% at BOTH points, not just after imclose: the earlier bwareafilt (right
% after bwareaopen) would otherwise already have discarded the fragment
% before the later, imclose-stage check ever got a chance to see it.
% ============================================================================

% ============================================================================
% Local tip-ward tangent for ring_walk_tip seed placement (ringwalk_seed_from_tip):
% fits the tube's own LOCAL direction from the current frame's own skeleton
% near the seed point, via PCA over a small window -- not from tip-history
% (too noisy when real per-frame growth is only ~1px) or a base-to-seed
% chord (wrong on a curved tube: the chord's direction can differ a lot from
% the tube's actual local path there). Used only to pick WHERE to place the
% offset seed point (walk back along this axis from tip_final_last, then
% snap to the mask -- see snap_to_mask below and the seeding block in the
% main loop); the walk's own first-step direction choice is resolved
% separately, by a hard smaller-column rule (ring_walk_tip's
% prefer_smaller_col), not by this tangent -- an earlier version tried using
% this tangent AS the direction estimate directly and it made no difference
% either way, since the real problem was the seed point itself (see
% ringwalk_seed_from_tip's doc comment in run_config.example.m).
%
% A tangent line has no direction, only an axis -- sign is fixed using this
% pipeline's own established convention (see the ringwalk base-anchor scan
% in the main loop, which already assumes every tube crosses the crop's
% RIGHT border): smaller column is tip-ward, larger column is base-ward.
% Picking which SIDE of an axis is correct is a far coarser, easier
% question than getting the axis's precise angle right, so this convention
% (already relied on everywhere else ringwalk anchors itself) is a safe way
% to resolve it.
%
% Returns [] when a reliable tangent can't be fit (too few local skeleton
% pixels), so the caller can skip seeding for this frame and fall back to a
% full base-anchored walk instead.
% ============================================================================
% ============================================================================
% Callbacks for the manual tip-seed interactive figure (see
% manual_tip_seed_interactive in the main loop). Plain function handles
% rather than closures/nested functions: state (the current candidate
% point, its marker handle, whether Enter confirmed it) lives in the
% figure's own appdata so each callback invocation reads/writes the same
% shared state without needing to capture mutable variables by reference.
% ============================================================================
function seed_motion_cb(~, ~, ax, hline, vline)
    cp = get(ax, 'CurrentPoint');
    set(hline, 'YData', [cp(1,2) cp(1,2)]);
    set(vline, 'XData', [cp(1,1) cp(1,1)]);
end

function seed_click_cb(src, ~, ax)
    cp = get(ax, 'CurrentPoint');
    gx = cp(1,1); gy = cp(1,2);
    setappdata(src, 'manual_pt', [round(gy), round(gx)]);
    old_marker = getappdata(src, 'marker_h');
    if ~isempty(old_marker) && isvalid(old_marker), delete(old_marker); end
    new_marker = plot(ax, gx, gy, 'gs', 'MarkerSize', 16, 'LineWidth', 2.5, 'HitTest', 'off');
    setappdata(src, 'marker_h', new_marker);
end

function seed_key_cb(src, evt)
    if strcmp(evt.Key, 'return') && ~isempty(getappdata(src, 'manual_pt'))
        setappdata(src, 'confirmed', true);
        uiresume(src);
    end
end

function seed_close_cb(src, ~)
    setappdata(src, 'confirmed', false);
    uiresume(src);
end

function dir_vec = local_tip_tangent(U, seed, diamo_est)
    dir_vec = [];
    [rows, cols] = size(U);
    r = round(seed(1)); c = round(seed(2));
    win = max(3, round(1.5 * diamo_est));
    r0 = max(1, r-win); r1 = min(rows, r+win);
    c0 = max(1, c-win); c1 = min(cols, c+win);
    sub = U(r0:r1, c0:c1);
    skel = bwmorph(sub, 'skel', Inf);
    [sr, sc] = find(skel);
    if numel(sr) < 3
        return; % too few local skeleton points to fit a reliable tangent
    end
    pts = double([sr, sc]);
    pts = pts - mean(pts, 1);
    [~, ~, V] = svd(pts, 0);
    tangent = V(:,1)'; % [drow dcol], principal (largest-variance) direction -- sign arbitrary
    if tangent(2) > 0
        % This pipeline's tubes always enter from the right border (see the
        % base-anchor scan in the main loop) -- smaller column is tip-ward.
        tangent = -tangent;
    end
    dir_vec = tangent;
end

% Robust cross-sectional width estimate, replacing locate_tip/edge_quant's
% single-column reading (at ref_col, the tube's crossing into the crop) --
% that one column can read artificially low on a frame-specific
% segmentation quirk (a marginal pixel dropout, a slightly different
% crossing angle) even when the tube itself looks completely normal in the
% actual footage, since nothing else about the frame feeds into a
% single-column read. Median over several columns stepping inward absorbs
% one bad column without hiding a real, sustained taper (same reasoning as
% the old diamo-only version of this logic, now applied to every frame's
% `diam` too -- see main loop and find_tip_and_measure). Verified needed:
% frames 53/57 of 20260327_3_cropped read diam=19px vs a diamo=45px
% reference and got NaN'd by diam_tol, despite looking unremarkable in
% growth.mp4 -- both are single-column artifacts, not real width changes.
%
% fallback_val is used only if every sampled column is empty (no mask
% pixels at all near the border that frame) -- pass the raw locate_tip
% diam as fallback, same as the original diamo cold-start logic did.
function d = robust_diam(U, ref_col, fallback_val, count, debug_mode)
    samples = [];
    for doff = 0:5:50
        dcol = ref_col - doff;
        if dcol < 1, break; end
        drows = find(U(:,dcol));
        if ~isempty(drows)
            % Largest contiguous run, not the full row span: a small
            % disconnected speck elsewhere in the same column (weak_signal's
            % rescue logic can leave these) would otherwise inflate the
            % span-based width several-fold. Confirmed on 20260327_2 frame
            % 500: true tube run ~81px, full span 386px because of three
            % stray 5px specks in the same column -- fed a bogus diamo=356
            % into ws_smooth_r, which then collapsed the reference mask
            % from 38244px to 9px and broke almost every later frame.
            gaps = find(diff(drows) > 1);
            run_starts = [drows(1); drows(gaps+1)];
            run_ends = [drows(gaps); drows(end)];
            samples(end+1) = max(run_ends - run_starts) + 1; %#ok<AGROW>
        end
    end
    if ~isempty(samples)
        % Median, not mean: doff=0 (the column closest to the crop edge) is
        % the sample most exposed to border artifacts (e.g. a genuine but
        % localised thickening right where the tube meets the crop boundary
        % -- see session notes on HV197_4_19 frame 2015). A single inflated
        % sample pulls the mean proportionally; median ignores it as long as
        % fewer than half the samples are affected, at no cost when the
        % samples are well-behaved.
        d = median(samples);
    else
        d = fallback_val;
    end
    % The column-scan above assumes the tube crosses these columns close to
    % perpendicular -- when it instead meets the border at a shallow/
    % diagonal angle, a vertical slice measures a much longer span than the
    % tube's true cross-section (confirmed on 20260327_2 frame 500: tube
    % runs diagonally, column-scan gave ~356px against a true ~80-100px
    % width). Cross-check against Area/MajorAxisLength -- the same width
    % proxy already used in signal_threshold.m for bent/diagonal shapes --
    % and fall back to it if the column-scan estimate looks implausibly
    % large.
    rp = regionprops(U, 'Area', 'MajorAxisLength');
    if ~isempty(rp) && rp(1).MajorAxisLength > 0
        d_axis = rp(1).Area / rp(1).MajorAxisLength;
        if d > 1.5 * d_axis
            if debug_mode
                fprintf('  diam F%d: column-scan=%.1fpx implausible vs Area/MajorAxisLength=%.1fpx -- using axis estimate\n', ...
                    count, d, d_axis);
            end
            d = d_axis;
        end
    end
end

% Snaps a float point (e.g. an offset seed computed along an estimated
% tangent, which won't generally land exactly on a mask pixel, especially
% once the tube curves over the offset distance) to the nearest actual TRUE
% pixel of U within a diamo-scaled search window. Returns snapped=false if
% no mask pixel is found in that window at all (e.g. the offset walked off
% the tube entirely, or off the edge of the frame) -- caller should treat
% that as "seeding not possible this frame" and fall back to a base walk.
function [r, c, snapped] = snap_to_mask(U, pt, diamo_est)
    r = NaN; c = NaN; snapped = false;
    [rows, cols] = size(U);
    win = max(3, round(1.5 * diamo_est));
    r0 = max(1, round(pt(1))-win); r1 = min(rows, round(pt(1))+win);
    c0 = max(1, round(pt(2))-win); c1 = min(cols, round(pt(2))+win);
    if r0 > r1 || c0 > c1
        return;
    end
    sub = U(r0:r1, c0:c1);
    [ys, xs] = find(sub);
    if isempty(ys)
        return;
    end
    d = hypot(double(ys) + r0 - 1 - pt(1), double(xs) + c0 - 1 - pt(2));
    [~, k] = min(d);
    r = ys(k) + r0 - 1;
    c = xs(k) + c0 - 1;
    snapped = true;
end

function idx = nearest_crossing_to_sample(edge_vals, side_pts, side_arclen, sample_pt, window_radius, tip_anchor, min_arclen)
% Used by the per-sample diameter cross-section search (both the reverse
% pass and find_tip_and_measure's own copy): finds where the fitted
% normal line actually crosses this boundary side, then picks whichever
% crossing is physically nearest (Euclidean) to the centerline sample.
%
% tip_anchor (optional, default false): when true, anchors step 1 (below)
% to side_pts' own first point (side_arclen==0) instead of the raw
% Euclidean-nearest point. Needed specifically for the tip-ward crossing
% search (roi_boundary_crossing's k_start call): side_pts (total1/total2)
% already excludes anything within the tip-exclusion radius, so its own
% first point IS essentially the true answer here -- but on a tightly
% hooked/curled tip (confirmed on HV209_116), the hook can curl back close
% enough to itself that some OTHER, far-along-the-boundary point ends up
% raw-Euclidean-closer to the tip-adjacent sample than side_pts' own start
% is. That's exactly the "hairpin" failure mode the step-1 comment below
% already warns about -- the tip-ward call is where it actually triggers
% on real data (frame 1: startc2 landed at index 16 instead of ~1,
% because Euclidean anchoring latched onto a distant, wrong point on the
% hook). Arc-length-zero is a direct, structural answer here, not a
% Euclidean guess, so it can't fall into that trap. Left as an opt-in
% flag rather than the new default: interior (k_stop-style) crossings have
% no such prior and are exactly the case the Euclidean anchor is meant
% for.
if nargin < 6, tip_anchor = false; end
if nargin < 7 || isempty(min_arclen), min_arclen = -Inf; end
%
% min_arclen (optional, default -Inf i.e. no constraint): excludes any
% candidate at or before this arc-length. Used by roi_boundary_crossing's
% k_stop call, constrained to al(startc) -- the stop crossing must lie
% FURTHER from the tip than the already-found start crossing on the same
% side, since arc_stop_px > arc_start_px always by construction. Guards
% the exact "hairpin" failure the tip_anchor doc above describes, but for
% the k_stop (non-tip_anchor, Euclidean-anchored) call specifically: on a
% tightly hooked tip, the boundary point nearest the tip (arclen~0) can
% ALSO be the raw-Euclidean-nearest point to a k_stop sample that's still
% close to the tip, collapsing stopc to the exact same index as startc --
% confirmed on HV209_116 frame 494 (c1:1->1, a zero-length side1 arc that
% collapsed Half1's ROI to a handful of pixels while every neighboring
% frame got a normal 10-40 point span). Restricting candidates to
% side_arclen > min_arclen directly rules that out: whatever the nearest
% point look like in raw Euclidean space, it cannot be at or before a
% point already claimed as the start crossing.
%
% Two things this is NOT, and why:
%
% 1. NOT a plain global min(abs(edge_vals)) ("take the point with smallest
%    perpendicular distance to the line, period"). A bent tube's boundary
%    is not convex, so a single line can cross it more than twice -- on
%    real data (HV207_9 frame 2746) the SAME fitted line crossed one side
%    at three genuinely separate points, 8px, 92px, and 151px along the
%    boundary from the centerline sample, with perpendicular residuals of
%    0.37, 0.03, and 0.25 respectively. All three are real crossings (all
%    near-zero); which one has the single smallest residual is decided by
%    sub-pixel discretization noise (exactly where each boundary vertex
%    happens to fall relative to the true continuous crossing), not by
%    which one is the true local cross-section. The old code took the
%    global min and got the 92px one. See session notes for the full
%    diagnostic images/writeup.
% 2. NOT a plain nearest-point-on-the-boundary-to-the-sample either
%    (skipping the line fit entirely). That would independently pick a
%    "nearest" point on each side with no guarantee the two points
%    correspond to the same true cross-section -- in a tapering or
%    asymmetric stretch they could correspond to different points along
%    the tube's length, skewing the measured width, and other code
%    downstream (the Half1/Half2 ROI split) depends on both sides being
%    found along the same tangent-perpendicular direction.
%
% Two-stage search: (1) restrict candidates to a local window of
% window_radius (arc-length px along this side, via side_arclen) around
% whichever point on this side is raw-nearest (Euclidean) to the sample --
% a fresh, one-shot anchor computed from scratch every call, not carried
% over from the previous sample (so one bad sample can't drag the next one
% off course). (2) within that window, restrict further to genuine
% crossings of the fitted line (local minima of |edge_vals|), then break
% the tie between them by distance to the sample -- the one criterion the
% line-only residual ignores entirely.
%
% The window in step (1) is a deliberate second line of defense, not just
% a speed optimization (arrays here are a few hundred points either way --
% cheap regardless): a raw nearest-point search alone (skip straight to
% step 2 with no window) is provably safe UNLESS the tube ever curves back
% close enough to itself in image space that a genuinely different stretch
% of boundary is physically nearer to the sample than the true local
% cross-section -- a hairpin/near-self-touching case. Restricting by
% ARC-LENGTH first (not raw distance) means a point that's spatially close
% but topologically far along the boundary can never enter the candidate
% set to begin with, regardless of how the tie-break in step 2 would have
% scored it. Not expected to matter on tubes that don't fold back on
% themselves (which would fail mask segmentation before reaching this
% code anyway) -- kept as a low-cost safety margin, not because it's been
% observed to trigger on real data.
d_to_sample = hypot(side_pts(:,1) - sample_pt(1), side_pts(:,2) - sample_pt(2));
past_min = side_arclen > min_arclen;
if ~any(past_min), past_min = true(size(side_arclen)); end % constraint unsatisfiable
                 % (e.g. min_arclen >= every point on this side) -- ignore it
                 % rather than search an empty set; better to fall back to
                 % the old (possibly hairpin-prone) behavior than error out.
if tip_anchor
    [~, anchor] = min(side_arclen); % side_pts' own first point -- see tip_anchor doc above
else
    d_masked = d_to_sample; d_masked(~past_min) = Inf;
    [~, anchor] = min(d_masked);
end
in_window = (abs(side_arclen - side_arclen(anchor)) <= window_radius) & past_min;
window_idx = find(in_window); % contiguous, since side_arclen is monotonic
if isempty(window_idx) % window landed entirely before min_arclen -- relax the
                 % arc-length constraint rather than return nothing
    in_window = abs(side_arclen - side_arclen(anchor)) <= window_radius;
    window_idx = find(in_window);
end

a = abs(edge_vals(window_idx));
nloc = numel(a);
is_min = false(nloc, 1);
if nloc == 1
    is_min(1) = true;
else
    is_min(2:end-1) = a(2:end-1) <= a(1:end-2) & a(2:end-1) <= a(3:end);
    is_min(1) = a(1) <= a(2);
    is_min(end) = a(end) <= a(end-1);
end
cand = window_idx(is_min);
if isempty(cand)
    cand = window_idx; % degenerate fallback: no local minimum found within
                 % the window (should not happen in practice)
end
[~, rel] = min(d_to_sample(cand));
idx = cand(rel);
end

function [c1, c2] = roi_boundary_crossing(pos, xc, yc, dx, dy, total1, al1, total2, al2, window, tip_anchor, min_al1, min_al2)
% tip_anchor (optional, default false): passed straight through to
% nearest_crossing_to_sample -- see its own doc for why the tip-ward
% (k_start) call needs this and the interior (k_stop) one doesn't.
% min_al1/min_al2 (optional, default -Inf i.e. unconstrained): passed
% straight through as nearest_crossing_to_sample's min_arclen -- pass
% al1(startc1)/al2(startc2) for the k_stop call so its crossing can never
% land at or before the already-found start crossing on the same side. See
% nearest_crossing_to_sample's own min_arclen doc for the failure this
% guards (HV209_116 frame 494).
if nargin < 11, tip_anchor = false; end
if nargin < 13 || isempty(min_al1), min_al1 = -Inf; end
if nargin < 14 || isempty(min_al2), min_al2 = -Inf; end
% Finds where a "diameter line" at centerline sample `pos` crosses each
% side -- literally the same construction the per-sample diameter
% cross-section search uses (this file's own reverse-pass loop), just
% evaluated at one specific position instead of every sample. Used for the
% ROI's start/stop boundary (at arc-length starti/stopi from the tip),
% which used to go through closest_bound.m instead.
%
% The point of doing it THIS way rather than calling closest_bound.m:
% dx/dy here are gradient(xc)/gradient(yc), a CENTERED difference computed
% once over the whole centerline (averaging both neighbours) -- the same
% tangent estimate already proven out for the diameter measurement.
% closest_bound.m instead recomputed its own tangent from scratch at just
% the one query position, using a one-sided difference (only the point
% ahead, or only the point behind -- never both). Confirmed on real data
% (HV207_58): after fixing closest_bound.m's crossing SEARCH (restricting
% to genuine local minima, tie-broken by distance), several frames still
% showed a stable, repeatable "not quite perpendicular" ROI cut, with
% start/stop indices barely different from before the fix -- i.e. the
% search was already finding the right answer for the line it was given,
% the line itself was pointing slightly the wrong way. A one-sided
% difference is exactly the kind of estimate that produces a consistent
% bias at a specific index rather than random noise, which matches what
% was observed (stable across frames, not flickering). Reusing the
% already-centered dx/dy removes that discrepancy entirely instead of
% patching around it.
nfitc = fit(vertcat(xc(pos),(xc(pos) - dy(pos))),vertcat(yc(pos),(yc(pos) + dx(pos))),'poly1');
sample_pt = [yc(pos), xc(pos)];
edge1 = total1(:,1) - nfitc.p1.*total1(:,2) - nfitc.p2;
c1 = nearest_crossing_to_sample(edge1, total1, al1, sample_pt, window, tip_anchor, min_al1);
edge2 = total2(:,1) - nfitc.p1.*total2(:,2) - nfitc.p2;
c2 = nearest_crossing_to_sample(edge2, total2, al2, sample_pt, window, tip_anchor, min_al2);
end

function [cap_pts, end1_at_start] = cap_boundary_arc(boundb, tip_boundpos, tip_end1, tip_end2)
% Extracts the near-tip boundary arc bounded by tip_end1/tip_end2 (with
% tip_boundpos always inside it) -- the tube's true rounded/blunt tip cap,
% excluded from total1/total2 by the diamo*0.75 tip-exclusion radius.
% boundb is a CLOSED loop, so the arc between two indices can be walked
% two ways; picks whichever of boundb(cap_lo:cap_hi,:) or its wrap-around
% complement boundb([cap_hi:end,1:cap_lo],:) is SHORTER. A plain
% boundb(cap_lo:cap_hi,:) silently picks the wrong (long) one whenever
% tip_boundpos/tip_end1/tip_end2 straddle boundb's own index-1/end seam --
% which happens whenever the tip actually used for tip_final(count,:) (the
% post-voting/post-jump-recovery decision) drifts away from the internal
% ellipse-fit tip that locate_tip.m centered boundb on. Confirmed on
% HV203_4_21 (a zigzag-tube dataset, threshold_method=triangle): the near-
% tip gap should only span ~1.5*diamo (~20-30px), but the raw index slice
% was instead pulling in 100+ points -- visible as a ballooned, rounded
% "blob" ROI cap in growth.mp4 instead of the tube's true tapered tip, and
% as a degenerate (occasionally empty) roi1/roi2 downstream. The true
% near-tip arc is never more than a few tube-widths, i.e. always much
% shorter than half of boundb, so "shorter of the two arcs" is a safe,
% general disambiguator -- no dataset-specific threshold needed.
%
% end1_at_start: true if cap_pts(1,:) is the tip_end1 side, so callers can
% tell the two ends apart without relying on cap_lo/cap_hi identity (which
% the wrap-around case inverts).
L = size(boundb, 1);
cap_lo = min([tip_boundpos, tip_end1, tip_end2]);
cap_hi = max([tip_boundpos, tip_end1, tip_end2]);
if (cap_hi - cap_lo) <= L - (cap_hi - cap_lo)
    cap_pts = boundb(cap_lo:cap_hi, :);
    end1_at_start = (tip_end1 == cap_lo);
else
    cap_pts = boundb([cap_hi:L, 1:cap_lo], :);
    end1_at_start = (tip_end1 == cap_hi);
end
end

function [stitch1, stitch2] = tip_cap_stitch(cap_pts, end1_at_start, xc, yc, dx, dy)
% Splits the near-tip boundary arc (see cap_boundary_arc, which supplies
% cap_pts/end1_at_start) by which side of the tube's own local axis each
% point falls on, using the tip-most centerline tangent
% (xc(1)/yc(1)/dx(1)/dy(1)) -- NOT by raw boundb index order split at the
% single point tip_boundpos (the previous approach), which only produces
% an even split when tip_boundpos happens to sit exactly at the cap's
% true bilateral center. For a wide/blunt tip (e.g. flattened against a
% wall), a small offset there sends most of the round cap's arc to one
% side, badly skewing Half1/Half2 signal comparisons even though the tip
% position itself is fine and nothing else about the frame looks wrong.
% Confirmed on HV209_116 frame 832 (a wall-flattened tip): the old split
% put nearly the whole cap on one side, visibly non-perpendicular to the
% traced centerline in growth.mp4/roi_debug.avi.
%
% IMPORTANT: cap_pts is filtered by side as a single CONTIGUOUS run per
% side, not a per-point boolean split -- boundb is a pixelated, staircase
% digital contour, so the raw cross-product sign can flip back and forth
% for a few points right around the true crossing instead of changing
% exactly once. A per-point filter (side>=0 / side<0) fragments those
% flickers into multiple separate runs, which poly2mask then renders as a
% notched, disconnected ROI edge that doesn't follow the tube outline at
% all -- confirmed on HV209_116 frame 1 after the first version of this
% fix. Finding the single point closest to the dividing axis and splitting
% the already-ordered cap_pts there instead keeps each side one genuine
% contiguous arc, like the boundb-index split this replaces did.
Tx = dx(1); Ty = dy(1); Cx = xc(1); Cy = yc(1); % tip-ward tangent + tip point, (col,row)
side = Ty.*(cap_pts(:,2)-Cx) - Tx.*(cap_pts(:,1)-Cy); % cross(T, P-C): which side of the tube's axis
[~, split_idx] = min(abs(side)); % single contiguous split, closest point to the axis
part_a = cap_pts(1:split_idx, :);
part_b = cap_pts(split_idx+1:end, :);

if end1_at_start
    stitch1 = part_a; stitch2 = part_b;
else
    stitch1 = part_b; stitch2 = part_a;
end
end

function r = ordered_range(a, b)
% Builds an index range from a to b, ascending or descending as needed --
% used instead of a plain `a:b` wherever a and b are two INDEPENDENTLY
% meaningful crossing indices (e.g. startc1 = side1's crossing of the
% k_start line, stopc1 = side1's crossing of the k_stop line) that must
% keep their identity rather than being reordered by numeric value.
%
% An earlier version of this code instead swapped startc1<->stopc1 (and
% separately startc2<->stopc2) whenever the pair came out numerically
% backwards, to guarantee a valid ascending slice. That silently breaks
% the correspondence between "this side's crossing of the k_start line"
% and "...of the k_stop line" whenever side1 and side2 happen to be
% indexed in OPPOSITE directions along the boundary for a given frame --
% which they can be, independently, since total1/total2 are each traced
% from the mask's own boundary-following order with no guaranteed
% relationship to the centerline's own direction. Confirmed on real data
% (HV207_58 frame 940, a tube with a sharp ~90deg hook near the tip):
% side1 needed no swap (already ascending) but side2 did, so after
% independent swapping "stopc2" ended up holding side2's crossing of the
% k_START line while "stopc1" still correctly held side1's crossing of
% the k_STOP line -- total1(stopc1) and total2(stopc2) were then each on
% a DIFFERENT fitted line, nowhere near collinear with the actual k_stop
% centerline point (perpendicular distance up to ~9px in that frame,
% instead of ~0). Fix: never swap which line a crossing belongs to --
% just walk each side's own index range in whichever direction its own
% start/stop crossing indices imply, independently per side.
if a <= b, r = a:b; else, r = a:-1:b; end
end

function w = fwhm_cross_section(O_raw, row0, col0, dx_n, dy_n, max_radius)
% Full-width-at-half-maximum across the tube, measured directly off raw
% (unmasked) intensity along the perpendicular "diameter line" through
% (row0,col0) -- same line the mask-crossing search uses (normal to the
% centerline tangent (dx_n,dy_n)), just evaluated against the continuous
% intensity profile instead of walking to a binary mask edge. Used only
% for the periodic FWHM diameter calibration (fwhm_diameter_correction),
% not the per-frame measurement itself, so this is deliberately strict:
% a rejected sample here just means one fewer calibration point, not a
% wrong per-frame diameter, so there's no fallback/best-effort path like
% nearest_crossing_to_sample's.
normn = sqrt(dx_n^2 + dy_n^2);
if normn == 0, w = NaN; return; end
ts = (-max_radius:0.25:max_radius)';
rows_q = row0 + ts.*(dx_n/normn);
cols_q = col0 + ts.*(-dy_n/normn);
vals = interp2(O_raw, cols_q, rows_q, 'linear', 0);
baseline = min(vals(1), vals(end));
peak = max(vals);
noise_est = std(vals(1:min(5,numel(vals))));
if peak <= baseline || (peak - baseline) < max(3*noise_est, 1)
    w = NaN; return; % no clean peak above the noise floor -- reject
end
half = baseline + (peak - baseline)/2;
idx = find(vals >= half);
if isempty(idx), w = NaN; return; end
i0 = idx(1); i1 = idx(end);
if i0 > 1, left = interp1(vals([i0-1 i0]), ts([i0-1 i0]), half); else, left = ts(i0); end
if i1 < numel(ts), right = interp1(vals([i1 i1+1]), ts([i1 i1+1]), half); else, right = ts(i1); end
w = right - left;
if ~isfinite(w) || w <= 0, w = NaN; end
end

function write_settings_log(cfg, groups, filepath)
% Writes cfg's fields to filepath as grouped `name = value` lines (no
% comments), in the order/grouping given by `groups` -- an Nx2 cell array
% of {group_title, {field_names...}}. Fields listed in a group but absent
% from cfg are silently skipped (keeps this tolerant of older run_config.m
% files missing newer parameters).
fid = fopen(filepath, 'w');
for g = 1:size(groups,1)
    fprintf(fid, '[%s]\n', groups{g,1});
    names = groups{g,2};
    for v = 1:numel(names)
        name = names{v};
        if ~isfield(cfg, name), continue; end
        val = cfg.(name);
        if ischar(val) || isstring(val)
            fprintf(fid, '%s = %s\n', name, val);
        else
            fprintf(fid, '%s = %g\n', name, val);
        end
    end
    fprintf(fid, '\n');
end
fclose(fid);
end

function U = keep_and_bridge_blobs(U_in, diamo_est, U_smp, debug_mode, count)
    cc = bwconncomp(U_in);
    if cc.NumObjects <= 1
        U = bwareafilt(U_in, 1);
        return;
    end
    stats = regionprops(cc, 'Area', 'MajorAxisLength');
    [~, largest_idx] = max([stats.Area]);
    keep = false(cc.NumObjects, 1);
    keep(largest_idx) = true;
    has_ref = ~isempty(U_smp) && any(U_smp(:));
    for ci = 1:cc.NumObjects
        if ci == largest_idx, continue; end
        s = stats(ci);
        if s.MajorAxisLength <= 0, continue; end
        % Width comparable to the tube's own measured diameter -- not a
        % thin noise sliver, not a blob much wider than the real tube.
        width_est = s.Area / s.MajorAxisLength;
        width_ok = width_est >= 0.5*diamo_est && width_est <= 1.5*diamo_est;
        % Elongated along its own axis (several tube-widths long), not
        % round/blobby noise.
        length_ok = s.MajorAxisLength >= 3*diamo_est;
        % Sits where the reference mask says the tube should be. On the
        % very first frame processed (establishing the reference itself,
        % before U_smp exists), there's nothing to check against yet --
        % defaulting this to false would mean the one frame that most
        % needs the rescue could never get it (caught via HV198_1_16
        % frame 3321 itself being the reference: its own tip blob kept
        % getting discarded because there was no U_smp yet to validate
        % against). Default to true (not checked, not penalised) when no
        % reference exists; only require real overlap once one does.
        overlap_ok = true;
        if has_ref
            comp_mask = false(size(U_in));
            comp_mask(cc.PixelIdxList{ci}) = true;
            overlap_ok = nnz(comp_mask & U_smp) / s.Area >= 0.3;
        end
        if width_ok && length_ok && overlap_ok
            keep(ci) = true;
            if debug_mode
                fprintf('  blob-keep F%d: component %d kept (width=%.1f len=%.1f overlap_ok=%d, diamo_est=%.1f)\n', ...
                    count, ci, width_est, s.MajorAxisLength, overlap_ok, diamo_est);
            end
        end
    end
    U = false(size(U_in));
    U(cc.PixelIdxList{largest_idx}) = true;
    if nnz(keep) > 1
        bridge_r = max(1, round(diamo_est * 0.15));
        remaining = setdiff(find(keep), largest_idx);
        while ~isempty(remaining)
            D = bwdist(U);
            piece_dists = zeros(numel(remaining), 1);
            for ri = 1:numel(remaining)
                piece_dists(ri) = min(D(cc.PixelIdxList{remaining(ri)}));
            end
            [~, nearest] = min(piece_dists);
            piece = false(size(U_in));
            piece(cc.PixelIdxList{remaining(nearest)}) = true;
            U = bridge_to_mask(U, piece, bridge_r);
            remaining(nearest) = [];
        end
    end
    U = bwareafilt(U, 1);
end

% ============================================================================
% Video frame rendering (growth.mp4 / roi_debug.avi), factored out so the
% SAME rendering code produces both the initial (reverse-pass) frame and
% any later re-render for a repaired frame -- video writing itself is
% buffered (not streamed) and flushed to disk only after the forward
% repair pass, in chronological order, so a repaired frame's video content
% matches its corrected CSV data instead of showing whatever the (later
% discarded) reverse-pass attempt looked like. See project notes for why
% this had to change: ~1/3 of frames on HV198_1_16 went through repair,
% and every one of them previously showed a blank marker in the video
% despite having valid, corrected data in the CSV.
% ============================================================================

function img = render_growth_frame(U, tip_row, yctk, xctk, F1, F2, ROItype, show_overlay, count, frame_rate)
    Splot = zeros(size(U));
    if show_overlay
        r1 = max(1,tip_row(1)-3); r2 = min(size(Splot,1),tip_row(1)+3);
        c1 = max(1,tip_row(2)-3); c2 = min(size(Splot,2),tip_row(2)+3);
        Splot(r1:r2,c1:c2) = 1;
    end
    Cplot = zeros(size(U));
    Cplot(sub2ind([size(Cplot,1) size(Cplot,2)], yctk, xctk)) = 2.*ones(size(xctk));
    image2 = U*20 + Splot*40 + Cplot*30;
    if (ROItype > 0) && show_overlay
        image2 = image2 + double(F1*60 + F2*80);
    end
    h = figure('visible', 'off');
    % Fixed, explicit pixel size -- getframe() otherwise captures whatever
    % MATLAB's default headless figure size happens to resolve to, which is
    % NOT deterministic: it depends on the invoking environment's display/
    % HiDPI backing-scale context (confirmed: a plain -nodisplay -batch call
    % gives a 512x384 canvas on a virtual 1024x768 "screen", but the same
    % code run under a Retina-scaled session previously produced 1120x840 --
    % exactly 2x MATLAB's classic 560x420 default figure size). Same code,
    % different growth.mp4 resolution/crispness purely from environment, not
    % from anything this pipeline actually computed differently. Pin it so
    % every run produces the same output regardless of how MATLAB was
    % launched.
    set(h, 'Units', 'pixels', 'Position', [100 100 1120 840]);
    imagesc(image2);
    clim([0 200]);
    % Time and Frame are two SEPARATE text() calls, not one concatenated
    % string -- Time's own digit count changes over the course of a run,
    % which shifted a single combined string's "Frame: N" left/right frame
    % to frame. Frame is right-aligned against the image width so its
    % position never depends on Time's width.
    timestr = strcat('Time(s): ',num2str(((count-1)*frame_rate)));
    framestr = strcat('Frame: ',num2str(count));
    % FontSize 36 bold: the figure is pinned to 1120x840 px above, where MATLAB's
    % default 10 pt text (and 16 pt, tried first) is still tiny in the finished growth.mp4.
    text(10,10,timestr,'color','white','FontSize',36,'FontWeight','bold')
    text(size(image2,2)-10,10,framestr,'color','white','FontSize',36,'FontWeight','bold','HorizontalAlignment','right')
    set(gca,'xtick',[]); set(gca,'xticklabel',[]); set(gca,'ytick',[]); set(gca,'yticklabel',[]);
    frame = getframe(gcf);
    img = frame.cdata;
    close(h);
end

function rgb_roi = render_roi_debug_frame(O, U, yctk, xctk, F1, F2, ROItype, show_overlay, up_factor, Cmax, count, frame_rate)
    Od = min(255, double(O)./Cmax.*255);
    jetmap = uint8(vertcat([0 0 0], jet(255)) .* 255);
    idx = uint8(Od) + 1;
    rgb = reshape(jetmap(idx(:),:), size(O,1), size(O,2), 3);
    rch = rgb(:,:,1); gch = rgb(:,:,2); bch = rgb(:,:,3);
    line_r = max(0, up_factor - 1);
    if (ROItype > 0) && show_overlay
        f1_edge = bwperim(logical(F1));
        f2_edge = bwperim(logical(F2));
        if line_r > 0
            f1_edge = imdilate(f1_edge, strel('disk', line_r));
            f2_edge = imdilate(f2_edge, strel('disk', line_r));
        end
        rch(f1_edge) = 255; gch(f1_edge) = 0;   bch(f1_edge) = 0;
        rch(f2_edge) = 0;   gch(f2_edge) = 0;   bch(f2_edge) = 255;
    end
    Cplot = zeros(size(U));
    Cplot(sub2ind([size(Cplot,1) size(Cplot,2)], yctk, xctk)) = 1;
    clm = logical(Cplot);
    if line_r > 0, clm = imdilate(clm, strel('disk', line_r)); end
    rch(clm) = 255; gch(clm) = 255; bch(clm) = 255;
    rgb_roi = cat(3, rch, gch, bch);
    if exist('insertText','file')
        % Time and Frame are two SEPARATE insertText calls, not one
        % concatenated string -- Time's own digit count changes over the
        % course of a run, which shifted a single combined string's
        % "Frame: N" left/right frame to frame. Frame is right-anchored
        % (AnchorPoint 'RightTop') so its position never depends on Time's
        % width.
        timestr = ['Time(s): ' num2str((count-1)*frame_rate)];
        framestr = ['Frame: ' num2str(count)];
        rgb_roi = insertText(rgb_roi,[5 5],timestr,'FontSize',8,'TextColor','white','BoxOpacity',0);
        rgb_roi = insertText(rgb_roi,[size(rgb_roi,2)-5 5],framestr,'FontSize',8,'TextColor','white','BoxOpacity',0,'AnchorPoint','RightTop');
    end
end

function U_smooth = reconstruct_smooth_mask(U, boundb, xc, yc, dx, dy, distc, t1_all, t2_all, diamo, postotal1, postotal2)
% Rebuild a spike-free, hole-free mask from the tube's own shape, for the
% growth/roi_debug videos specifically (weak_signal only) -- does not feed
% back into diamf_avg/ROI/tip-finding, which stay based on the original U.
%
% Direction/bends and width are smoothed SEPARATELY on purpose (v2 design,
% see project notes): xc/yc (the already-tracked medial-axis centerline)
% and dx/dy (its local tangent, hence the perpendicular probe direction)
% are used AS-IS, so a real bend is followed exactly as tightly as before
% -- only the per-side half-width (t1_all/t2_all, the raw signed offset
% from the centerline along that same perpendicular, one entry per xc/yc
% sample -- computed and stashed in the main per-sample loop above, BEFORE
% line_continuity can drop/reorder points, so it stays index-aligned with
% xc/yc/dx/dy no matter how much continuity-pruning shortens poscross1/
% poscross2 downstream) gets smoothed, with a much wider, robust (median)
% window than a plain positional smoothing of xy1/xy2 could use. A local
% dark-spot threshold pinch is an imaging artifact, not a real width
% change, and needs a wide enough window to be outvoted by the genuine
% width around it; but smoothing xy1/xy2's raw (row,col) POSITIONS with a
% window that wide also rounds off real bends (the two curves round
% unevenly, distorting width right where the tube turns). Decoupling means
% a wide width-window can't cause bend-thickening: a bend only ever moves
% `center`/the perpendicular direction here, never the half-widths. The
% median filter also absorbs the occasional wrong-index outlier that
% line_continuity would otherwise have corrected for the real measurement
% path -- fine here since this is visual only.
U_smooth = U;
n = numel(xc);
if n < 2 || numel(t1_all) ~= n || numel(t2_all) ~= n
    return; % not enough boundary data this frame -- fall back to the raw mask
end

norm_t = sqrt(dx(:).^2 + dy(:).^2);
norm_t(norm_t == 0) = 1;
perp_row =  dx(:) ./ norm_t;
perp_col = -dy(:) ./ norm_t;
center = [yc(:) xc(:)];

t1 = t1_all(:);
t2 = t2_all(:);

% Window sized in arc-length terms (a few tube-diameters), converted to a
% sample count via the centerline's own point spacing -- diamo-relative,
% not a fixed pixel count, consistent with how the rest of this codebase
% scales corridor/closing radii.
spacing = mean(abs(diff(distc(:))));
if ~isfinite(spacing) || spacing <= 0, spacing = 1; end
win = round(6 * diamo / spacing);
win = max(5, win);
if mod(win, 2) == 0, win = win + 1; end
win = min(win, 2*floor((n-1)/2) + 1);
win = max(3, win);

t1s = medfilt1(t1, win, 'truncate');
t2s = medfilt1(t2, win, 'truncate');

xy1_new = center + t1s .* [perp_row perp_col];
xy2_new = center + t2s .* [perp_row perp_col];

% Tip needs a small stitched cap: xy1/xy2 both stop short of the very tip
% by design (postotal1/postotal2 exclude boundary points within
% diamo*0.75px of it), so closing [xy1_new; flipud(xy2_new)] directly
% would leave an unnaturally flat/blunt edge right at the tip instead of
% its real taper. boundb(postotal2(1):postotal1(2),:) is the same
% tip-region boundary arc already used to close the ROI polygon near the
% tip (see the ROI construction above) -- same technique, reused here.
% It's smoothed too (was raw/unfiltered before -- the tip is exactly
% where GCaMP signal/mask quality is roughest, so it showed real spikes
% even after xy1/xy2 got smoothed), then endpoint-blended (linear ramp)
% onto xy1_new(1,:)/xy2_new(1,:) so the join has no visible seam. Window
% sized relative to diamo (like the width window above), not a fixed
% point count: boundb steps ~1px apart, so a fixed small window (an
% earlier version used 9) is a shrinking fraction of a tip-cap arc as
% diamo grows, and left real 1-2px-wide boundary-tracing spikes only
% partially smoothed (confirmed on HV198_1_16 frame 3090 -- a genuine
% double spike survived at window 9, mostly resolved at window~1.5x
% diamo; going wider still leaves a 1px residual right at the seam
% (medfilt1's 'truncate' edge-padding weakens right at the array boundary
% no matter how wide the nominal window is) while starting to blunt the
% true taper, so 1.5x is the point of diminishing returns, not a full fix).
tip_cap = double(boundb(postotal2(1):postotal1(2), :));
if size(tip_cap,1) >= 5
    cap_step = mean(sqrt(sum(diff(tip_cap).^2, 2)));
    if ~isfinite(cap_step) || cap_step <= 0, cap_step = 1; end
    cap_win = round(1.5 * diamo / cap_step);
    cap_win = max(3, cap_win);
    if mod(cap_win, 2) == 0, cap_win = cap_win + 1; end
    cap_win = min(cap_win, 2*floor((size(tip_cap,1)-1)/2) + 1);
    tip_cap = [medfilt1(tip_cap(:,1), cap_win, 'truncate'), medfilt1(tip_cap(:,2), cap_win, 'truncate')];
end
n_cap = size(tip_cap, 1);
frac = (0:n_cap-1)' / max(1, n_cap-1);
err_start = xy2_new(1,:) - tip_cap(1,:);
err_end   = xy1_new(1,:) - tip_cap(end,:);
tip_cap = tip_cap + (1-frac).*err_start + frac.*err_end;

poly = [tip_cap; xy1_new; flipud(xy2_new)];
candidate = poly2mask(poly(:,2), poly(:,1), size(U,1), size(U,2));
if any(candidate(:))
    U_smooth = candidate;
end
end

% ============================================================================
% Forward repair pass support (weak_signal only). See project notes: the
% main loop above walks backward (smp:-1:stp), so "previous frame in the
% loop" means "later frame in real time" -- useful for shrinking a known-
% good reference shape toward the tip, but the wrong direction for using
% "the tip can't have retracted more than max_tip_jump_um" as a
% constructive repair bound (that needs the REAL previous-in-time frame).
% These two functions implement that: build_repaired_mask unions in the
% reference mask's own shape (same technique the old always-on weak_signal
% used) for the shank, then extends the mask forward toward the expected
% tip location when this frame's own tip falls short of the growth-rate
% bound; find_tip_and_measure is a faithful re-derivation of the main
% loop's own tip-finding + curves/centerline/ROI/diameter logic (kept
% deliberately parallel to the inline code above, not shared with it, to
% avoid regression risk to the already-verified reverse pass), used only
% by the forward repair pass below so a repaired frame's tip/diameter/ROI
% numbers are mutually consistent. Diagnostics, kymograph, and the two
% output videos are NOT reproduced here -- see session notes: video
% writing is append-only (no seeking back to patch one frame), and kymo/
% diagnostics are visualization aids, not the measurements.csv data this
% pass exists to fix.
% ============================================================================

function U = build_repaired_mask(U0, U_smp, prev_tip, max_tip_jump_um, pixelsize)
    % Shank/base repair: union in the reference mask's own shape, cropped to
    % this frame's own detected tip column (same technique the old
    % always-on weak_signal used, now applied only to flagged frames).
    [~, Uc_plain] = find(U0);
    tip_col = size(U0, 2);
    if ~isempty(Uc_plain), tip_col = min(Uc_plain); end
    U_ref_shrunk = U_smp;
    U_ref_shrunk(:, 1:(tip_col - 1)) = false;
    U = U0 | U_ref_shrunk;
    U = bwareafilt(U, 1);

    % Tip repair: the tip cannot have retracted more than max_tip_jump_um
    % since the previous (chronologically earlier) frame's own tip. If this
    % frame's own mask doesn't reach that far, extend it using the
    % reference mask's own shape as a guide -- same crop-and-union
    % technique as the shank repair above, just cropped less aggressively.
    if ~isempty(prev_tip) && pixelsize > 0
        max_jump_px = max_tip_jump_um / pixelsize;
        [~, Uc] = find(U);
        this_tip_col = min(Uc);
        expected_min_col = max(1, prev_tip(2) - max_jump_px);
        if this_tip_col > expected_min_col
            U_ref_extend = U_smp;
            ext_col = max(1, round(expected_min_col));
            U_ref_extend(:, 1:(ext_col - 1)) = false;
            U = U | U_ref_extend;
            U = bwareafilt(U, 1);
        end
    end
end

% Cross-method fallback (ringwalk_fallback_to_skeleton): retries a SINGLE
% frame using the skeleton method's own Qef/branch-removal/voting logic,
% for when tip_method='ringwalk' produces a tip that fails the jump-check
% (main loop, ~line 1000) and has no other same-frame candidate to recover
% from (tip_skel/tip_mid are only ever populated when tip_method='skeleton'
% natively runs). A self-contained duplicate of the primary skeleton path
% (main loop, ~lines 692-980) -- deliberately NOT refactored into a shared
% function with that path or with find_tip_and_measure's own near-identical
% copy (the forward repair pass), so neither of those already-verified
% paths carries any regression risk from this addition. Confirmed needed
% on 20260327_3_cropped (ringwalk_seed_from_tip=1): frames 63/97/134 hit a
% sharp bend where ring_walk_tip's direction-continuity scoring picks the
% wrong branch with a clear margin, and had no rescue candidate available.
%
% Returns ok=false (tip_out=[]) if the computation raises -- this only ever
% runs on already-anomalous frames (sharp bends, marginal masks), exactly
% where branch_removal/dsearchn are most likely to hit an edge case, and
% must never crash a run that would otherwise have just NaN'd one frame.
function [tip_out, diam_out, maxy_out, boundb_out, Qef_out, Qel_out, Qec_out, ...
          tip_ellipse_out, center_out, phin_out, axes_out, stats_out, edges_out, ok] = ...
    skeleton_tip_fallback(U, weight, diamo, tip_final_last, last_flag, count, debug_mode, ellipse_fit_method, ellipse_candidate_max_jump_factor)

    tip_out = []; diam_out = []; maxy_out = []; boundb_out = []; Qef_out = [];
    Qel_out = []; Qec_out = []; tip_ellipse_out = []; center_out = []; phin_out = [];
    axes_out = []; stats_out = []; edges_out = []; ok = false;

    try
        % Removing branches from thinned image (same as main loop's skeleton branch)
        Q = bwmorph(U,'thin',Inf);

        Qe = bwmorph(Q,'endpoints');
        [Qer,Qec] = find(Qe > 0);
        Qel = [Qer Qec];

        Qb = bwmorph(Q,'branchpoints');
        [Qbr,Qbc] = find(Qb > 0);
        if (Qbr > 0)
            Qbf = [Qbr Qbc];
            [Q2, Qef, tmp] = branch_removal(Q,Qbf,Qel,0,1);
        else
            Q2 = Q;
            [tmp,Qepos] = max(Qec);
            Qef = Qel;
            Qef(Qepos,:) = [];
        end
        if isempty(Qef) && ~isempty(Qel)
            [~, Qepos] = max(Qel(:,2));
            Qef = Qel(Qepos,:);
        end

        % Finding the radius for ellipse fitting -- re-run here since it
        % depends on THIS call's own Qef, not the primary method's.
        tols = 0; rad=1;
        while (tols == 0)
            sides = false; connect = false;
            try
                K = U(Qef(1)-rad:Qef(1)+rad,Qef(2)-rad:Qef(2)+rad);
            catch
                rad = 100;
                tols = 40;
                break;
            end
            Ke = [K(:,1)' K(end,2:end) K(end-1:-1:1,end)' K(1,end-1:-1:2)];
            Kd = diff(Ke);
            Kd(end+1) = Ke(1) - Ke(end);
            if (nnz(Kd) == 2) connect = true; end
            Ks = [sum(K(:,1)) sum(K(1,:)) sum(K(:,end)) sum(K(end,:))];
            if (nnz(Ks) <= 2)
                bou = bwboundaries(K);
                if ~isempty(bou)
                    Kb = bou{1};
                    Kbl = [find(Kb(:,1) == 1); find(Kb(:,2) == 1); find(Kb(:,1) == size(K,1)); find(Kb(:,2) == size(K,1))];
                    if (size(Kbl,1) < size(K,1)) sides = true; end
                end
            end
            if(connect == true && sides == true) tols = rad; end
            rad = rad + 1;
        end

        % Same capped-search fix as the primary path above (see its comment) --
        % diamo and tip_final_last are both already this function's own params.
        % max_jump_px: see ellipse_candidate_max_jump_factor's doc near the top of this file.
        max_jump_px = ellipse_candidate_max_jump_factor * diamo;
        [boundb, tip_ellipse, tip_new, tip_check, diam, maxy, center, phin, axes, stats, edges] = locate_tip(U, tols, Qef, 2*diamo, tip_final_last, max_jump_px, ellipse_fit_method);
        diam = robust_diam(U, size(U,2) - 1, diam, count, debug_mode);
        tip_ellipsepos = dsearchn(boundb,tip_ellipse);
        tip_ellipsef = boundb(tip_ellipsepos,:);

        S = bwmorph(U,'skel',Inf);
        Se = bwmorph(S,'endpoints');
        [Ser,Sec] = find(Se > 0);
        Sel = [Ser Sec];

        Sb = bwmorph(S,'branchpoints');
        [Sbr,Sbc] = find(Sb > 0);
        Sbl = [Sbr Sbc];

        tip_skel = []; tip_mid = [];

        if isempty(Sbl)
            S2 = S; S2area = 1;
            [~, base_pos] = max(Sel(:,2));
            Sef = Sel; Sef(base_pos,:) = [];
        else
            if (last_flag == 0) Sbf = Sbl(dsearchn(Sbl,Qef),:);
            else [tmp, Sbmin] = min(pdist2(Sbl,tip_final_last) + pdist2(Sbl,Qef));
                Sbf = Sbl(Sbmin,:);
            end

            close_dist = 0;
            if (pdist2(Qef,Sbf) > weight*diamo) close_dist = 1; end
            if (weight == 0) kill_angle = 0;
            else kill_angle = 75;
            end
            [S2,Sef,S2area] = branch_removal(S,Sbf,Sel,kill_angle,close_dist);
        end

        if (size(Sef,1) > 1)
            if size(Sef,1) > 2
                d_to_ellipse = pdist2(Sef, tip_ellipsef);
                [~, order] = sort(d_to_ellipse);
                Sef = Sef(order(1:2),:);
            end
            % See the main loop's identical branch decision for why this
            % trusts skel_lastpos directly instead of the old blended formula.
            [tmp, skel_ellipsepos] = min(pdist2(Sef,tip_ellipsef));
            if (last_flag == 1)
                [tmp, skel_lastpos] = min(pdist2(Sef,tip_final_last));
                choice = skel_lastpos;
            else
                choice = skel_ellipsepos;
            end

            tip_choice = [dsearchn(boundb,Sef(1,:));dsearchn(boundb,Sef(2,:))];
            if (min(tip_choice) == tip_choice(2)) S2area = 1/S2area; end
            tip_skelpos = tip_choice(choice);
            tip_skel = boundb(tip_skelpos,:);

            cn = 0; tip_angle = [];
            for i = min(tip_choice):max(tip_choice)
                cn = cn+1;
                tip_angle(cn) = atan2((boundb(i,2) - Sbf(2)),(boundb(i,1) - Sbf(1)));
                if (pi - abs(max(tip_angle)) < abs(min(tip_angle)))
                    if (tip_angle(cn) < 0) tip_angle(cn) = 2*pi + tip_angle(cn); end
                end
            end
            target_angle = (tip_angle(1) + tip_angle(end)*S2area)/(S2area+1);

            tip_anglediff = abs(tip_angle - target_angle);
            [tmp, tip_anglepos] = min(tip_anglediff);
            tip_midpos = tip_anglepos+min(tip_choice)-1;
            tip_mid = boundb(tip_midpos,:);

            tip_range_tol = 2;
            % Same continuity cross-check as the primary path -- see its
            % comment (main loop, ~line 1250).
            topo_ok = (tip_ellipsepos>min(tip_choice)-tip_range_tol && tip_ellipsepos<max(tip_choice)+tip_range_tol);
            continuity_ok = ~last_flag || pdist2(tip_ellipsef,tip_final_last) <= pdist2(tip_skel,tip_final_last);
            if topo_ok && continuity_ok
                tip_final_fb = tip_ellipsef;
                if debug_mode
                    fprintf('  [fallback] tip F%d: branched choice=%d ellipsepos=%d in range -> ellipsef\n', count, choice, tip_ellipsepos);
                end
            else
                tip_ellipsedist = [pdist2(tip_ellipsef,tip_mid) pdist2(tip_ellipsef,tip_skel)];
                if (last_flag)
                    tip_finaldist = [pdist2(tip_final_last,tip_mid) pdist2(tip_final_last,tip_skel)];
                    [tmp, tip_finalpos] = min([(1-0.33)*tip_finaldist(1)+0.33*tip_ellipsedist(1) (1-0.33)*tip_finaldist(2)+0.33*tip_ellipsedist(2)]);
                else
                    [tmp, tip_finalpos] = min(tip_ellipsedist);
                end
                if (tip_finalpos == 1) tip_final_fb = tip_mid; else tip_final_fb = tip_skel; end
                if debug_mode
                    srclabel = 'skel'; if (tip_finalpos==1), srclabel = 'mid'; end
                    fprintf('  [fallback] tip F%d: branched choice=%d ellipsepos=%d NOT in range -> %s\n', count, choice, tip_ellipsepos, srclabel);
                end
            end
        else
            tip_skel = boundb(dsearchn(boundb,Sef(1,:)),:);
            if (last_flag) [tmp, tip_finaldistpos] = min([pdist2(tip_final_last,tip_ellipsef) pdist2(tip_final_last,tip_skel)]);
            else tip_finaldistpos = 2;
            end
            if (tip_finaldistpos == 1) tip_final_fb = tip_ellipsef; else tip_final_fb = tip_skel; end
            if debug_mode
                srclabel = 'skel'; if (tip_finaldistpos==1), srclabel = 'ellipsef'; end
                fprintf('  [fallback] tip F%d: unbranched last_flag=%d -> %s\n', count, last_flag, srclabel);
            end
        end

        tip_out = tip_final_fb; diam_out = diam; maxy_out = maxy; boundb_out = boundb;
        Qef_out = Qef; Qel_out = Qel; Qec_out = Qec; tip_ellipse_out = tip_ellipse;
        center_out = center; phin_out = phin; axes_out = axes; stats_out = stats; edges_out = edges;
        ok = true;
    catch err
        if debug_mode
            fprintf('  [fallback] tip F%d: skeleton_tip_fallback raised (%s) -- not used\n', count, err.message);
        end
        ok = false;
        tip_out = [];
    end
end

function [tip_row, diamf_val, intens, ok, yctk_out, xctk_out, F1_out, F2_out, U_smooth_out] = find_tip_and_measure(count, U, prev_tip, ...
        weight, diamo, tip_method, pixelsize, ROItype, split, circle, starti, stopi, ...
        diamcutoff, mode, O, BT1r, BT2r, old_intens, debug_mode, max_tip_jump_um, ellipse_fit_method, ellipse_candidate_max_jump_factor)

if nargin < 21 || isempty(ellipse_fit_method), ellipse_fit_method = 'ransac'; end
if nargin < 22 || isempty(ellipse_candidate_max_jump_factor), ellipse_candidate_max_jump_factor = Inf; end

    ok = true;
    last_flag = ~isempty(prev_tip);
    intens = old_intens; % ROItype==2 (stationary ROI, reused from smp) not
                          % supported here -- falls back to the reverse
                          % pass's own values for that stack layout.
    F1_out = zeros(size(U)); F2_out = zeros(size(U)); % default when ROItype<=0/==2/split==0 -- video re-render just skips ROI shading then

    % Finding the tip-ward reference point (Qef) -- skeleton + branch-removal
    % only; ringwalk not supported in the repair pass (experimental, unused
    % on real stacks as of this session).
    Q = bwmorph(U,'thin',Inf);
    Qe = bwmorph(Q,'endpoints');
    [Qer,Qec] = find(Qe > 0);
    Qel = [Qer Qec];
    Qb = bwmorph(Q,'branchpoints');
    [Qbr,Qbc] = find(Qb > 0);
    if (Qbr > 0)
        Qbf = [Qbr Qbc];
        [Q2, Qef, tmp] = branch_removal(Q,Qbf,Qel,0,1);
    else
        Q2 = Q;
        [tmp,Qepos] = max(Qec);
        Qef = Qel;
        Qef(Qepos,:) = [];
    end
    if isempty(Qef) && ~isempty(Qel)
        % Same defensive fallback as the reverse pass's own copy above --
        % see that comment for the full explanation (confirmed root cause
        % of the F3271 crash: branch_removal over-pruned a 3-endpoint
        % skeleton to zero endpoints).
        [~, Qepos] = max(Qel(:,2));
        Qef = Qel(Qepos,:);
    end

    % Finding the radius for ellipse fitting
    tols = 0; rad=1;
    while (tols == 0)
        sides = false; connect = false;
        try
            K = U(Qef(1)-rad:Qef(1)+rad,Qef(2)-rad:Qef(2)+rad);
        catch
            rad = 100;
            tols = 40;
            break;
        end
        Ke = [K(:,1)' K(end,2:end) K(end-1:-1:1,end)' K(1,end-1:-1:2)];
        Kd = diff(Ke);
        Kd(end+1) = Ke(1) - Ke(end);
        if (nnz(Kd) == 2) connect = true; end
        Ks = [sum(K(:,1)) sum(K(1,:)) sum(K(:,end)) sum(K(end,:))];
        if (nnz(Ks) <= 2)
            bou = bwboundaries(K);
            if ~isempty(bou)
                Kb = bou{1};
                Kbl = [find(Kb(:,1) == 1); find(Kb(:,2) == 1); find(Kb(:,1) == size(K,1)); find(Kb(:,2) == size(K,1))];
                if (size(Kbl,1) < size(K,1)) sides = true; end
            end
        end
        if(connect == true && sides == true) tols = rad; end
        rad = rad + 1;
    end

    % Same capped-search fix as the reverse pass (see main loop's comment) --
    % diamo and prev_tip are both already this function's own params.
    % max_jump_px: see ellipse_candidate_max_jump_factor's doc near the top of this file.
    max_jump_px = ellipse_candidate_max_jump_factor * diamo;
    [boundb, tip_ellipse, tip_new, tip_check, diam, maxy, center, phin, axes, stats, edges] = locate_tip(U, tols, Qef, 2*diamo, prev_tip, max_jump_px, ellipse_fit_method);
    % Same robust-diam overwrite as the reverse pass (see main loop) -- keeps
    % the tolerance check below comparing like-for-like instead of a robust
    % diamo reference against one noisy single-column per-frame sample.
    diam = robust_diam(U, size(U,2) - 1, diam, count, debug_mode);
    tip_ellipsepos = dsearchn(boundb,tip_ellipse);
    tip_ellipsef = boundb(tip_ellipsepos,:);

    S = bwmorph(U,'skel',Inf);
    Se = bwmorph(S,'endpoints');
    [Ser,Sec] = find(Se > 0);
    Sel = [Ser Sec];
    Sb = bwmorph(S,'branchpoints');
    [Sbr,Sbc] = find(Sb > 0);
    Sbl = [Sbr Sbc];

    % Diameter sanity check against the frozen reference (same as the
    % reverse pass) -- if repair still can't produce a plausible diameter,
    % report failure so the caller leaves this frame flagged/NaN'd.
    diam_tol = 2;
    if (diam < diamo/diam_tol) || (diam > diamo*diam_tol)
        ok = false;
        if debug_mode
            fprintf('  [repair] diam F%d: diam=%.1fpx vs diamo=%.1fpx -- still out of tolerance\n', count, diam, diamo);
        end
    end

    if isempty(Sbl)
        S2 = S; S2area = 1;
        [~, base_pos] = max(Sel(:,2));
        Sef = Sel; Sef(base_pos,:) = [];
    else
        if (last_flag == 0) Sbf = Sbl(dsearchn(Sbl,Qef),:);
        else [tmp, Sbmin] = min(pdist2(Sbl,prev_tip) + pdist2(Sbl,Qef));
            Sbf = Sbl(Sbmin,:);
        end
        close_dist = 0;
        if (pdist2(Qef,Sbf) > weight*diamo) close_dist = 1; end
        if (weight == 0) kill_angle = 0;
        else kill_angle = 75;
        end
        [S2,Sef,S2area] = branch_removal(S,Sbf,Sel,kill_angle,close_dist);
    end

    if (size(Sef,1) > 1)
        if size(Sef,1) > 2
            d_to_ellipse = pdist2(Sef, tip_ellipsef);
            [~, order] = sort(d_to_ellipse);
            Sef = Sef(order(1:2),:);
        end
        % See the main loop's identical branch decision for why this
        % trusts skel_lastpos directly instead of the old blended formula.
        [tmp, skel_ellipsepos] = min(pdist2(Sef,tip_ellipsef));
        if (last_flag == 1)
            [tmp, skel_lastpos] = min(pdist2(Sef,prev_tip));
            choice = skel_lastpos;
        else
            choice = skel_ellipsepos;
        end
        tip_choice = [dsearchn(boundb,Sef(1,:));dsearchn(boundb,Sef(2,:))];
        if (min(tip_choice) == tip_choice(2)) S2area = 1/S2area; end
        tip_skelpos = tip_choice(choice);
        tip_skel = boundb(tip_skelpos,:);

        cn = 0; tip_angle = [];
        for i = min(tip_choice):max(tip_choice)
            cn = cn+1;
            tip_angle(cn) = atan2((boundb(i,2) - Sbf(2)),(boundb(i,1) - Sbf(1)));
            if (pi - abs(max(tip_angle)) < abs(min(tip_angle)))
                if (tip_angle(cn) < 0) tip_angle(cn) = 2*pi + tip_angle(cn); end
            end
        end
        target_angle = (tip_angle(1) + tip_angle(end)*S2area)/(S2area+1);
        tip_anglediff = abs(tip_angle - target_angle);
        [tmp, tip_anglepos] = min(tip_anglediff);
        tip_midpos = tip_anglepos+min(tip_choice)-1;
        tip_mid = boundb(tip_midpos,:);

        tip_range_tol = 2;
        % Same continuity cross-check as the primary path -- see its
        % comment (main loop, ~line 1250).
        topo_ok = (tip_ellipsepos>min(tip_choice)-tip_range_tol && tip_ellipsepos<max(tip_choice)+tip_range_tol);
        continuity_ok = ~last_flag || pdist2(tip_ellipsef,prev_tip) <= pdist2(tip_skel,prev_tip);
        if topo_ok && continuity_ok
            tip_row = tip_ellipsef;
        else
            tip_ellipsedist = [pdist2(tip_ellipsef,tip_mid) pdist2(tip_ellipsef,tip_skel)];
            if (last_flag)
                tip_finaldist = [pdist2(prev_tip,tip_mid) pdist2(prev_tip,tip_skel)];
                [tmp, tip_finalpos] = min([(1-0.33)*tip_finaldist(1)+0.33*tip_ellipsedist(1) (1-0.33)*tip_finaldist(2)+0.33*tip_ellipsedist(2)]);
            else
                [tmp, tip_finalpos] = min(tip_ellipsedist);
            end
            if (tip_finalpos == 1) tip_row = tip_mid; else tip_row = tip_skel; end
        end
    else
        tip_skel = boundb(dsearchn(boundb,Sef(1,:)),:);
        if (last_flag) [tmp, tip_finaldistpos] = min([pdist2(prev_tip,tip_ellipsef) pdist2(prev_tip,tip_skel)]);
        else tip_finaldistpos = 2;
        end
        if (tip_finaldistpos == 1) tip_row = tip_ellipsef; else tip_row = tip_skel; end
    end

    if debug_mode
        fprintf('  [repair] tip F%d -> [%d %d]\n', count, tip_row(1), tip_row(2));
    end

    % Tip-jump sanity check against the real previous-in-time frame -- same
    % physical bound as the reverse pass's own check, just now checked
    % against the correct chronological neighbour.
    if last_flag && pixelsize > 0
        tip_jump_um = pdist2(tip_row, prev_tip) * pixelsize;
        if tip_jump_um > max_tip_jump_um
            ok = false;
            if debug_mode
                fprintf('  [repair] tip F%d: jump=%.2fum > max_tip_jump_um=%.1fum -- repair did not converge\n', ...
                    count, tip_jump_um, max_tip_jump_um);
            end
        end
    end

    % Find the curves along the sides of the tubes
    total1 = []; total2 = [];
    range1 = ceil(length(boundb)*0.5):length(boundb);
    dist1 = pdist2(boundb(range1,:),tip_row);
    postotal1 = find(dist1 > diamo*0.75)+range1(1)-1;
    if (~isempty(find(diff(postotal1(1:floor(length(postotal1)/2))>1))))
        postotal1(1:find(diff(postotal1(1:floor(length(postotal1)/2))>1))) = [];
    end
    total1(:,:) = boundb(postotal1,:);

    range2 = ceil(length(boundb)*0.5)-1:-1:1;
    dist2 = pdist2(boundb(range2,:),tip_row);
    postotal2 = range2(1)-find(dist2 > diamo*0.75)+1;
    if (~isempty(find(diff(postotal2(1:floor(length(postotal2)/2))>1))))
        postotal2(1:find(diff(postotal2(1:floor(length(postotal2)/2))>1))) = [];
    end
    total2(:,:) = boundb(postotal2,:);

    % Ensure that both curves also reach near the tip. See the reverse
    % pass's own copy of this block for the full writeup (root-caused on
    % HV207_58 frame 650 vs frame 649) -- runs before the maxy check below
    % so that check can't unknowingly strip a side's only near-tip padding
    % while fixing the other side's far-end shortfall.
    if ~isempty(total1) && ~isempty(total2)
        tip_reach_tol = diamo*0.75 + 2;
        if pdist2(total1(1,:), tip_row) > tip_reach_tol
            while pdist2(total1(1,:), tip_row) > tip_reach_tol && ~isempty(total2)
                total1 = vertcat(total2(1,:), total1);
                total2(1,:) = [];
            end
        elseif pdist2(total2(1,:), tip_row) > tip_reach_tol
            while pdist2(total2(1,:), tip_row) > tip_reach_tol && ~isempty(total1)
                total2 = vertcat(total1(1,:), total2);
                total1(1,:) = [];
            end
        end
    end

    if isempty(total1) || isempty(total2)
        dist_all = pdist2(boundb, tip_row);
        postotal_all = find(dist_all > diamo*0.75);
        half = ceil(length(postotal_all)*0.5);
        total1 = boundb(postotal_all(1:half),:);
        total2 = boundb(postotal_all(half+1:end),:);
    end
    if ~isempty(total1) && ~isempty(total2)
        if (max(total1(:,2)) < (maxy-1))
            while(max(total1(:,2)) < (maxy-1) && ~isempty(total2))
                total1 = vertcat(total1,total2(end,:));
                total2(end,:) = [];
            end
        elseif (max(total2(:,2)) < (maxy-1))
            while(max(total2(:,2)) < (maxy-1) && ~isempty(total1))
                total2 = vertcat(total2, total1(end,:));
                total1(end,:) = [];
            end
        end
    end
    if isempty(total1) || isempty(total2)
        dist_all = pdist2(boundb, tip_row);
        postotal_all = find(dist_all > diamo*0.75);
        if ~isempty(postotal_all)
            half = ceil(length(postotal_all)*0.5);
            total1 = boundb(postotal_all(1:half),:);
            total2 = boundb(postotal_all(half+1:end),:);
        end
    end
    if ~isempty(total1) && ~isempty(total2) && (abs(total1(end,1) - total2(end,1)) < 0.75*diam)
        total1(find(total1(:,2) >= max(total1(:,2))),:) = [];
        total2(find(total2(:,2) >= max(total2(:,2))),:) = [];
    end

    % Centerline: minimum-cost path through tube, weighted by distance from wall
    right_col = size(U,2) - 1;
    right_pix = find(U(:, right_col));
    while isempty(right_pix) && right_col > 1
        right_col = right_col - 1;
        right_pix = find(U(:, right_col));
    end
    ra_row = round(mean(right_pix));
    if ~U(ra_row, right_col)
        [~, snap] = min(abs(right_pix - ra_row));
        ra_row = right_pix(snap);
    end
    right_anchor = [ra_row, right_col];

    % Squared, same reasoning as the reverse pass's own copy of this block.
    D_tube = bwdist(~U);
    W_tube = Inf(size(U));
    W_tube(U) = 1 ./ (D_tube(U) + 1).^2;
    GD = graydist(W_tube, right_anchor(2), right_anchor(1));
    GD(~U) = Inf;

    [Ur_all, Uc_all] = find(U);
    [~, tpos] = min(pdist2([Ur_all Uc_all], tip_row));
    r = Ur_all(tpos); c = Uc_all(tpos);
    if ~isfinite(GD(r,c))
        [~, epos] = max(Qec);
        r = Qel(epos,1); c = Qel(epos,2);
    end

    max_path = 3*nnz(U);
    path = zeros(max_path, 2);
    path(1,:) = [r c];
    n_path = 1;
    visited = false(size(U));
    visited(r,c) = true;
    for step = 1:max_path-1
        if GD(r,c) == 0, break; end
        r0 = max(1,r-1); r1 = min(size(U,1),r+1);
        c0 = max(1,c-1); c1 = min(size(U,2),c+1);
        nbhd = GD(r0:r1, c0:c1);
        nbhd(visited(r0:r1, c0:c1)) = Inf;
        [min_val, idx] = min(nbhd(:));
        % GD is a true geodesic distance field from right_anchor, so barring
        % floating-point ties there's always a strictly-lower unvisited
        % neighbour except at the anchor itself -- a plain min_val>=GD(r,c)
        % stops dead on the FIRST tied neighbour instead of stepping through
        % it, which can freeze the walk just a few steps from the tip in a
        % wide region (bwdist gives locally-repeated integer-ish distances
        % there -- confirmed on HV209_116 frame 1: the traced centerline
        % stalls inside the tip bulb and never reaches the true tip).
        % Tolerate exact ties (>, not >=); the visited mask still guarantees
        % termination.
        if min_val > GD(r,c), break; end
        [dr, dc] = ind2sub(size(nbhd), idx);
        r = r0+dr-1; c = c0+dc-1;
        n_path = n_path + 1;
        path(n_path,:) = [r c];
        visited(r,c) = true;
    end
    path = path(1:n_path,:);
    yctk = path(:,1); xctk = path(:,2);
    if debug_mode
        fprintf('  centerline F%d: n_path=%d start=[%d %d] end=[%d %d] right_anchor=[%d %d] GD_end=%.3f GD_start=%.3f\n', ...
            count, n_path, path(1,1), path(1,2), path(end,1), path(end,2), right_anchor(1), right_anchor(2), GD(path(end,1),path(end,2)), GD(path(1,1),path(1,2)));
    end
    path_dist = [0; cumsum(sqrt(sum(diff(path).^2, 2)))];

    nline = 1:100; norder = floor(nline*path_dist(end)/100);
    nfinal = dsearchn(path_dist, norder');
    yct = yctk(nfinal); xct = xctk(nfinal); distct = path_dist(nfinal);
    xct = round(sgolayfilt(double(xct),3,15)); yct = round(sgolayfilt(double(yct),3,15));
    xct = max(1, min(xct, size(U,2))); yct = max(1, min(yct, size(U,1)));

    % See the reverse pass's own copy of this block for why cut is fixed
    % at 1 (the path's own start, already ~tip_row) instead of searching
    % for a match to distc_t (the tip-to-Qef seed gap, a QC number
    % unrelated to where arc-length should start).
    distc_t = pdist2(tip_row, Qef);
    cut = 1;
    xc = xct(cut:end); yc = yct(cut:end); distc = distct(cut:end);

    dx = gradient(xc); dx(find(dx == 0)) = 0.01;
    dy = gradient(yc); dy(find(dy == 0)) = 0.01;

    % See the reverse pass's own copy of this loop for why the search is
    % windowed by arc-length, then restricted to genuine line crossings,
    % tie-broken by distance to the centerline sample
    % (nearest_crossing_to_sample), instead of a global nearest-point-to-
    % the-line search.
    al1 = [0; cumsum(sqrt(sum(diff(total1).^2, 2)))];
    al2 = [0; cumsum(sqrt(sum(diff(total2).^2, 2)))];
    crossing_window = diamo * 2;

    poscross1 = []; poscross2 = []; t1_all = zeros(length(xc),1); t2_all = zeros(length(xc),1);
    for n = 1:length(xc)
        nfitc = fit(vertcat(xc(n),(xc(n) - dy(n))),vertcat(yc(n),(yc(n) + dx(n))),'poly1');
        sample_pt = [yc(n), xc(n)];
        edge1 = total1(:,1) - nfitc.p1.*total1(:,2) - nfitc.p2;
        cross1 = nearest_crossing_to_sample(edge1, total1, al1, sample_pt, crossing_window);
        poscross1(n) = cross1;
        edge2 = total2(:,1) - nfitc.p1.*total2(:,2) - nfitc.p2;
        cross2 = nearest_crossing_to_sample(edge2, total2, al2, sample_pt, crossing_window);
        poscross2(n) = cross2;

        % Signed half-width at this exact sample, for reconstruct_smooth_mask
        % -- see the reverse pass's own copy of this loop for why it's
        % stashed here rather than derived from xy1/xy2 after continuity
        % pruning below.
        normn = sqrt(dx(n)^2 + dy(n)^2); if normn == 0, normn = 1; end
        p1pt = total1(cross1,:); p2pt = total2(cross2,:);
        t1_all(n) = (p1pt(1)-yc(n))*(dx(n)/normn) + (p1pt(2)-xc(n))*(-dy(n)/normn);
        t2_all(n) = (p2pt(1)-yc(n))*(dx(n)/normn) + (p2pt(2)-xc(n))*(-dy(n)/normn);
    end

    [poscross1, poscross2, distcf] = line_continuity(poscross1,poscross2,1,distc);
    [poscross1, poscross2, distcf] = line_continuity(poscross1,poscross2,2,distcf);

    xy1 = total1(poscross1,:); xy2 = total2(poscross2,:);
    if (length(xy1) > 20)
        xy1 = floor(sgolayfilt(xy1,3,15)); xy2 = floor(sgolayfilt(xy2,3,15));
    end
    xyout = vertcat(find(xy1(:,2) > size(U,2)), find(xy2(:,2) > size(U,2)));
    xy1(xyout,:) = []; xy2(xyout,:) = []; distcf(xyout) = [];

    % Same smoothed-boundary mask reconstruction as the reverse pass's own
    % copy (see reconstruct_smooth_mask) -- this function only ever runs
    % under weak_signal=1 (called by the forward repair pass), so no
    % separate gate needed here.
    U_smooth_out = reconstruct_smooth_mask(U, boundb, xc, yc, dx, dy, distc, t1_all, t2_all, diamo, postotal1, postotal2);

    [tmp, distpos, tmp] = intersect(distc,distcf);
    distctf = [distct(1:cut-1); distc(distpos)]; xctf = [xct(1:cut-1); xc(distpos)]; yctf = [yct(1:cut-1); yc(distpos)];
    linectf = [yctf xctf];

    if (ROItype > 0) && (ROItype ~= 2)
        Esize = size(U);
        if (pixelsize == 0)
            percent = (100*distctf)./(distctf(end));
            stop_length = abs(percent - stopi); [tmp, stoppos] = min(stop_length);
            distc_t = (100*distc_t)/max(distctf);
            tip_excl_dist = (100*diamo*0.75)/max(distctf);
        else
            stop_length = abs(distctf*pixelsize - stopi); [tmp, stoppos] = min(stop_length);
            distc_t = distc_t*pixelsize;
            tip_excl_dist = diamo*0.75*pixelsize;
        end

        if pixelsize > 0
            arc_start_px = starti / pixelsize;
            arc_stop_px  = min(stopi / pixelsize, distc(end));
        else
            arc_start_px = starti / 100 * distc(end);
            arc_stop_px  = stopi  / 100 * distc(end);
        end
        [~, k_start] = min(abs(distc - arc_start_px));
        [~, k_stop]  = min(abs(distc - arc_stop_px));
        k_start = max(1, min(k_start, length(xc)));
        k_stop  = max(1, min(k_stop,  length(xc)));

        % See the reverse pass's own copy of this block for why this uses
        % roi_boundary_crossing (the diameter-line construction) instead of
        % closest_bound.m.
        % k_start's crossing search is anchored tip-side (see
        % nearest_crossing_to_sample's tip_anchor doc) -- k_stop is an
        % interior crossing with no such prior, so it keeps the default
        % Euclidean anchor. Constrained to land past k_start's own crossing
        % on each side (min_arclen) -- see nearest_crossing_to_sample's
        % min_arclen doc for the hairpin-collapse this guards against.
        [startc1, startc2] = roi_boundary_crossing(k_start, xc, yc, dx, dy, total1, al1, total2, al2, crossing_window, true);
        [stopc1,  stopc2]  = roi_boundary_crossing(k_stop,  xc, yc, dx, dy, total1, al1, total2, al2, crossing_window, false, al1(startc1), al2(startc2));
        % See the reverse pass's own copy of this block (and ordered_range's
        % comment) for why startc1/stopc1/startc2/stopc2 are NOT swapped into
        % numeric order here.

        % See the reverse pass's own copy of this block for why this is
        % computed once, up front, and reused for both the outer F polygon
        % just below and the roi1/roi2 stitch further down.
        if (starti < tip_excl_dist)
            tip_boundpos = dsearchn(boundb, tip_row);
            [~, near1] = min(abs(postotal1 - tip_boundpos)); tip_end1 = postotal1(near1);
            [~, near2] = min(abs(postotal2 - tip_boundpos)); tip_end2 = postotal2(near2);
            [cap_pts, end1_at_start] = cap_boundary_arc(boundb, tip_boundpos, tip_end1, tip_end2);
        end

        if (circle == 0)
            roi = vertcat(total1(ordered_range(startc1,stopc1),:), total2(flip(ordered_range(startc2,stopc2)),:));
            if (starti < tip_excl_dist), roi = vertcat(cap_pts,roi); end
            F = poly2mask(roi(:,2),roi(:,1),Esize(1),Esize(2));
        else
            maskc = zeros(Esize(1),Esize(2));
            roi = [linectf(stoppos,1) linectf(stoppos,2)];
            maskc(roi(1),roi(2)) = 1;
            F = bwdist(maskc) >= 0.5*circle.*diamo;
            F = imcomplement(F);
        end

        if (split == 1)
            if (circle > 0)
                stoppos = length(linectf); stopc1 = length(total1); stopc2 = length(total2);
            end
            roi1 = vertcat(total1(ordered_range(startc1,stopc1),:), [yc(k_stop:-1:k_start), xc(k_stop:-1:k_start)]);
            roi2 = vertcat(total2(ordered_range(startc2,stopc2),:), [yc(k_stop:-1:k_start), xc(k_stop:-1:k_start)]);
            if (starti < tip_excl_dist)
                % cap_pts/end1_at_start already computed above, up front
                % (shared with the outer F polygon's own patch).
                [stitch1, stitch2] = tip_cap_stitch(cap_pts, end1_at_start, xc, yc, dx, dy);
                roi1 = vertcat(stitch1,roi1,boundb(tip_boundpos,:));
                roi2 = vertcat(stitch2,roi2,boundb(tip_boundpos,:));
            end
            F1 = F.*poly2mask(roi1(:,2),roi1(:,1),Esize(1),Esize(2));
            F2 = F.*poly2mask(roi2(:,2),roi2(:,1),Esize(1),Esize(2));
        end

        if (max(O(:)) <= 255) FO = uint8(F);
        else FO = uint16(F);
        end
        F = uint16(F);

        intens.Fpixelnum = nnz(O.*FO);
        intens.intensityM = sum(O(:))/nnz(O);
        if ~strcmp(mode, 'two_raw')
            intens.intensityM_F = sum(sum(O.*FO))/intens.Fpixelnum;
            intens.intensityB1_F = sum(sum(BT1r.*F))/intens.Fpixelnum;
            if ~isempty(BT2r), intens.intensityB2_F = sum(sum(BT2r.*F))/intens.Fpixelnum; end
        end

        if (split)
            if (max(O(:)) <= 255) F1O = uint8(F1); F2O = uint8(F2);
            else F1O = uint16(F1); F2O = uint16(F2);
            end
            F1 = uint16(F1); F2 = uint16(F2);
            F1_out = F1; F2_out = F2;
            intens.F1pixelnum = nnz(O.*F1O);
            intens.F2pixelnum = nnz(O.*F2O);
            if ~strcmp(mode, 'two_raw')
                intens.intensityM_F1 = sum(sum(O.*F1O))/intens.F1pixelnum;
                intens.intensityB1_F1 = sum(sum(BT1r.*F1))/intens.F1pixelnum;
                if ~isempty(BT2r), intens.intensityB2_F1 = sum(sum(BT2r.*F1))/intens.F1pixelnum; end
                intens.intensityM_F2 = sum(sum(O.*F2O))/intens.F2pixelnum;
                intens.intensityB1_F2 = sum(sum(BT1r.*F2))/intens.F2pixelnum;
                if ~isempty(BT2r), intens.intensityB2_F2 = sum(sum(BT2r.*F2))/intens.F2pixelnum; end
            end
        end
    else
        intens.intensityM = sum(O(:))/nnz(O);
    end

    if (pixelsize > 0), cutoffp = dsearchn(distcf',diamcutoff/pixelsize);
    else, cutoffp = dsearchn(distcf',diamcutoff);
    end
    if (cutoffp > 1), xy1(cutoffp-1,:) = []; xy2(cutoffp-1,:) = []; end

    diamf = diag(pdist2(xy1,xy2)); % median, not mean -- see the reverse pass's own copy
    diamf_val = median(diamf);
    yctk_out = yctk; xctk_out = xctk;
end

function ok = candidate_passes_tip_guard(pt, tip_final_last, axis_unit, ...
    max_tip_jump_um, frames_since_last_good, pixelsize, ...
    lateral_offset_max_factor, diamo_est, stationary_lock_active, stationary_pos_eps_px, ...
    side_n, side_acc, side_limit_px)
% Unified acceptance test for a tip-position candidate, combining the three
% independent guards (Euclidean jump budget, lateral-offset-from-axis, and
% stationary-lock exclusion) into one predicate so the primary pick and
% every recovery-pool candidate are held to exactly the same standard,
% rather than the pool only ever being re-checked against the plain jump
% budget. See the guards' shared doc block near max_tip_jump_um's own
% derivation, and lateral_offset_max_factor's own default, near the top of
% main_track_movies.m.
%
% axis_unit: precomputed once per frame by the caller (identical for every
% candidate in the pool -- it depends only on tip_final_last/history/U, not
% on which candidate is being tested), not recomputed per-candidate here.
% Empty when no usable axis exists (see the caller's own fallback chain),
% in which case the lateral check is simply skipped for this candidate.

if nargin < 13, side_n = []; side_acc = 0; side_limit_px = Inf; end
jump_um = pdist2(pt, tip_final_last) * pixelsize;
ok = jump_um <= max_tip_jump_um * frames_since_last_good;

if ok && ~isempty(side_n)
    % Side memory (see side_offset_max_factor's doc): cumulative sideways offset
    % may not exceed the limit unless this step reduces it.
    side_new = side_acc + dot(pt - tip_final_last, side_n);
    ok = abs(side_new) <= side_limit_px || abs(side_new) <= abs(side_acc);
end

if ok && ~isempty(axis_unit)
    d_vec = pt - tip_final_last;
    long_comp = dot(d_vec, axis_unit);
    lateral_px = norm(d_vec - long_comp * axis_unit);
    ok = lateral_px <= lateral_offset_max_factor * diamo_est;
end

if ok && stationary_lock_active
    % Already locked onto a frozen point for stationary_lock_n_frames in a
    % row (see stationary_streak's own upkeep) -- refuse to extend that
    % streak with yet another point that's still essentially the same
    % spot, even though it trivially passes both checks above (near-zero
    % displacement always will). Forces the pool to either produce a
    % genuinely different point or fail outright (frame gets NaN'd/flagged
    % rather than silently continuing the freeze).
    ok = pdist2(pt, tip_final_last) >= stationary_pos_eps_px;
end
end
function [pt_new, moved_px] = step_along_contour(boundb, from_pt, to_pt, step_px, min_euclid)
% Walk about step_px of ARC LENGTH along the ordered contour boundb, starting
% at the contour point nearest from_pt and heading for the contour point
% nearest to_pt (the shorter way round). Stops early at the target if it is
% closer than step_px. min_euclid (optional) additionally requires the
% stopping point to be at least that far, straight-line, from from_pt -- the
% stationary nudge needs this so the move clears stationary_pos_eps_px.
% Returns the point reached and its straight-line distance from from_pt
% (moved_px = 0 means no move was possible, caller falls back).
if nargin < 5, min_euclid = 0; end
n = size(boundb, 1);
by = double(boundb(:,1)); bx = double(boundb(:,2));
[~, i0] = min(hypot(by - from_pt(1), bx - from_pt(2)));
[~, i1] = min(hypot(by - to_pt(1), bx - to_pt(2)));
fwd = mod(i1 - i0, n); bwd = mod(i0 - i1, n);
if fwd <= bwd, dirn = 1; arc = fwd; else dirn = -1; arc = bwd; end
if arc == 0
    pt_new = boundb(i0,:); moved_px = 0; return;
end
path_idx = mod(i0 - 1 + dirn*(0:arc), n) + 1;
seg = [0; cumsum(hypot(diff(by(path_idx)), diff(bx(path_idx))))];
eu = hypot(by(path_idx) - from_pt(1), bx(path_idx) - from_pt(2));
k = find(seg >= step_px & eu >= min_euclid, 1, 'first');
if isempty(k)
    k = numel(path_idx);
elseif min_euclid == 0 && k > 1 && seg(k) > step_px
    k = k - 1; % a cap must not overshoot; only the nudge (min_euclid > 0) may
end
pt_new = boundb(path_idx(k),:);
moved_px = hypot(double(pt_new(1)) - from_pt(1), double(pt_new(2)) - from_pt(2));
end
