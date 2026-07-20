clear all
close all

run('run_config.m'); % Per-run parameters (gitignored) — copy from run_config.example.m

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
if ~strcmp(mode, 'ratio')
    for fc = 1:size(BT1,3)
        frm = BT1(:,:,fc);
        BT1(:,:,fc) = frm .* cast(signal_threshold(frm, threshold_method, up_factor, weak_signal), class(BT1));
    end
    if ~isempty(BT2)
        for fc = 1:size(BT2,3)
            frm = BT2(:,:,fc);
            BT2(:,:,fc) = frm .* cast(signal_threshold(frm, threshold_method, up_factor, weak_signal), class(BT2));
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
frame_failed = false(smp, 1);
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
    try
    O = M(:,:,count);
    
    if (type == 1) O = imrotate(O,-90); 
    elseif (type == 3) O = imrotate(O,90); 
    elseif (type == 4) O = imrotate(O,180);
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
    if debug_mode && (count == smp || count == smp - 1)
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
        % Cross-frame continuity, mirroring the skeleton method's own use
        % of tip_final_last/last_flag: gated behind last_flag so it's
        % never referenced before it's actually assigned (count==smp, the
        % cold-start reference frame, always has last_flag==0).
        if last_flag
            Qef = ring_walk_tip(U, [rw_row, rw_col], 'prev_tip', tip_final_last);
        else
            Qef = ring_walk_tip(U, [rw_row, rw_col]);
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

    [boundb, tip_ellipse, tip_new, tip_check, diam, maxy, center, phin, axes, stats, edges] = locate_tip(U, tols, Qef);
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
        % Single-column diam (measured at maxy-1 by locate_tip/edge_quant)
        % underestimates the true diameter on weak-signal stacks: that
        % column sits right where the tube crosses into the frame, which
        % is where segmentation is most marginal. Average the cross-
        % sectional span over several columns moving inward from the edge
        % instead of trusting one column. Verified on HV202_2_11 frame
        % 623: single-column=17px vs multi-column mean=20.3px.
        ref_col = size(U,2) - 1; % same column locate_tip/edge_quant uses
        diamo_samples = [];
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
                diamo_samples(end+1) = max(run_ends - run_starts) + 1;
            end
        end
        if ~isempty(diamo_samples)
            % Median, not mean: doff=0 (the column closest to the crop edge)
            % is the sample most exposed to border artifacts (e.g. a
            % genuine but localised thickening right where the tube meets
            % the crop boundary -- see session notes on HV197_4_19 frame
            % 2015). A single inflated sample pulls the mean proportionally;
            % median ignores it as long as fewer than half the samples are
            % affected, at no cost when the samples are well-behaved.
            diamo = median(diamo_samples);
        else
            diamo = diam; % fallback if no columns had any mask pixels
        end
        % The column-scan above assumes the tube crosses these columns close
        % to perpendicular -- when it instead meets the border at a shallow/
        % diagonal angle, a vertical slice measures a much longer span than
        % the tube's true cross-section (confirmed on 20260327_2 frame 500:
        % tube runs diagonally, column-scan gave ~356px against a true
        % ~80-100px width). Cross-check against Area/MajorAxisLength -- the
        % same width proxy already used in signal_threshold.m for bent/
        % diagonal shapes -- and fall back to it if the column-scan estimate
        % looks implausibly large.
        rp_diamo = regionprops(U, 'Area', 'MajorAxisLength');
        if ~isempty(rp_diamo) && rp_diamo(1).MajorAxisLength > 0
            diamo_axis = rp_diamo(1).Area / rp_diamo(1).MajorAxisLength;
            if diamo > 1.5 * diamo_axis
                if debug_mode
                    fprintf('  diamo F%d: column-scan=%.1fpx implausible vs Area/MajorAxisLength=%.1fpx -- using axis estimate\n', ...
                        count, diamo, diamo_axis);
                end
                diamo = diamo_axis;
            end
        end
        if debug_mode
            fprintf('  diamo F%d: single-col=%.1fpx multi-col-median=%.1fpx (n=%d cols) samples=%s\n', ...
                count, diam, diamo, numel(diamo_samples), mat2str(diamo_samples));
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
        % Voting to decide which branch to be chosen as closer to the tip
        [tmp, skel_ellipsepos] = min(pdist2(Sef,tip_ellipsef));
        if (last_flag == 1)
            [tmp, skel_lastpos] = min(pdist2(Sef,tip_final_last));
            if ((skel_lastpos+skel_ellipsepos+1) > 4) choice = 2; else choice = 1; end
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

        test = [];
        % Tolerance absorbs per-frame boundary-tracing noise: boundb is
        % rebuilt from scratch each frame via bwboundaries, so the same
        % index can land a few units off between frames even when the
        % ellipse-fit tip itself hasn't moved (observed: a 1-unit miss on
        % an otherwise-identical ellipsepos flipped this to the fallback
        % vote and shifted the tracked tip by ~5px on a single frame).
        tip_range_tol = 2;
        if (tip_ellipsepos>min(tip_choice)-tip_range_tol && tip_ellipsepos<max(tip_choice)+tip_range_tol)
            tip_final(count,:) = tip_ellipsef;
            if debug_mode
                fprintf('  tip F%d: branchpt=%d branched choice=%d ellipsepos=%d in [%d,%d] margin=%d -> ellipsef\n', ...
                    count, ~isempty(Sbl), choice, tip_ellipsepos, min(tip_choice), max(tip_choice), ...
                    min(tip_ellipsepos-min(tip_choice), max(tip_choice)-tip_ellipsepos));
            end
        else
            tip_ellipsedist = [pdist2(tip_ellipsef,tip_mid) pdist2(tip_ellipsef,tip_skel)];
            if (last_flag)
                tip_finaldist = [pdist2(tip_final_last,tip_mid) pdist2(tip_final_last,tip_skel)];
                [tmp, tip_finalpos] = min([(1-0.33)*tip_finaldist(1)+0.33*tip_ellipsedist(1) (1-0.33)*tip_finaldist(2)+0.33*tip_ellipsedist(2)]);
            else
                [tmp, tip_finalpos] = min(tip_ellipsedist);
            end
            if (tip_finalpos == 1) tip_final(count,:) = tip_mid; else tip_final(count,:) = tip_skel; end
            test = [test count];
            if debug_mode
                srclabel = 'skel'; if (tip_finalpos==1), srclabel = 'mid'; end
                overshoot = min(tip_ellipsepos-min(tip_choice), max(tip_choice)-tip_ellipsepos);
                if (last_flag)
                    fprintf('  tip F%d: branchpt=%d branched choice=%d ellipsepos=%d NOT in [%d,%d] overshoot=%d last_flag=%d -> %s (ellipsedist=[%.1f %.1f] finaldist=[%.1f %.1f] blend=[%.1f %.1f] tip_mid=[%d %d] tip_skel=[%d %d] tip_final_last=[%d %d])\n', ...
                        count, ~isempty(Sbl), choice, tip_ellipsepos, min(tip_choice), max(tip_choice), overshoot, last_flag, srclabel, ...
                        tip_ellipsedist(1), tip_ellipsedist(2), tip_finaldist(1), tip_finaldist(2), ...
                        (1-0.33)*tip_finaldist(1)+0.33*tip_ellipsedist(1), (1-0.33)*tip_finaldist(2)+0.33*tip_ellipsedist(2), ...
                        tip_mid(1), tip_mid(2), tip_skel(1), tip_skel(2), tip_final_last(1), tip_final_last(2));
                else
                    fprintf('  tip F%d: branchpt=%d branched choice=%d ellipsepos=%d NOT in [%d,%d] overshoot=%d last_flag=%d -> %s (ellipsedist=[%.1f %.1f])\n', ...
                        count, ~isempty(Sbl), choice, tip_ellipsepos, min(tip_choice), max(tip_choice), overshoot, last_flag, srclabel, tip_ellipsedist(1), tip_ellipsedist(2));
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

    % Tip-position sanity check (weak_signal only): a real tube tip cannot
    % jump implausibly far between adjacent frames. Empirically calibrated,
    % not growth-rate-derived: frame-to-frame tip displacement was measured
    % on 3 real datasets (~6500 transitions total) -- genuine growth+jitter
    % never exceeded ~9.7um on two clean datasets, while a third (known
    % segmentation failures, e.g. the mask splitting the tube in two) showed
    % a sharp gap in the distribution: nothing between ~5um and ~41um, with
    % ~2% of frames landing at 65-69um. 15um sits in the middle of that gap
    % -- same flagging result (0 false positives on the clean datasets, ~68
    % frames flagged on the bad one) at any threshold from 10 to 30um, so
    % the exact value isn't sensitive. See session notes for the analysis.
    if weak_signal && last_flag && pixelsize > 0
        tip_jump_um = pdist2(tip_final(count,:), tip_final_last) * pixelsize;
        if tip_jump_um > max_tip_jump_um
            % The chosen candidate is implausibly far -- before giving up,
            % check whether one of the OTHER candidates this same frame
            % already produced (ellipsef/skel/mid, whichever this code path
            % computed) happens to land within range. This was previously a
            % pure reject-after-the-fact test: it flagged the frame but left
            % whatever far-off point the voting logic picked in tip_final,
            % which then got drawn into the growth/roi_debug videos as if it
            % were a real position (confirmed on HV198_1_16 frame 3314: a
            % near-empty mask (diam~0px) produced a spurious ellipsef far
            % from frame 3313's tip; the jump check correctly NaN'd the CSV
            % but the video still showed the bad point, since video drawing
            % was never gated on frame_failed -- see Tip plot section below,
            % now fixed there too). Recovering a nearby alternate candidate
            % when one exists directly reduces how often this situation can
            % happen at all, rather than only cleaning up after it.
            cand = tip_ellipsef; cand_label = {'ellipsef'};
            if ~isempty(tip_skel), cand = [cand; tip_skel]; cand_label{end+1} = 'skel'; end
            if ~isempty(tip_mid),  cand = [cand; tip_mid];  cand_label{end+1} = 'mid';  end
            cand_dist_px = pdist2(cand, tip_final_last);
            [best_dist_px, best_idx] = min(cand_dist_px);
            if best_dist_px * pixelsize <= max_tip_jump_um
                tip_final(count,:) = cand(best_idx,:);
                if debug_mode
                    fprintf('  tip F%d: original jump=%.2fum > %.1fum -- recovered via %s candidate (jump=%.2fum)\n', ...
                        count, tip_jump_um, max_tip_jump_um, cand_label{best_idx}, best_dist_px*pixelsize);
                end
            else
                % No candidate this frame produced is plausible either.
                % Still assign the closest one (downstream centerline/ROI
                % code needs *some* numeric point to work with this
                % iteration), but flag the frame so it's NaN'd in the CSV
                % and the video skips drawing a marker for it.
                tip_final(count,:) = cand(best_idx,:);
                frame_failed(count) = true;
                if debug_mode
                    fprintf('  tip F%d: jump=%.2fum > max_tip_jump_um=%.1fum, no candidate within range (best=%.2fum via %s) -- flagged, results NaN''d\n', ...
                        count, tip_jump_um, max_tip_jump_um, best_dist_px*pixelsize, cand_label{best_idx});
                end
            end
        end
    end

    if weak_signal && (needs_repair(count) || frame_failed(count))
        U_cache{count} = U;
    end

    % Update tip_final for the next frame
    tip_final_last(:,:) = tip_final(count,:);
    
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
    if debug_mode && (count == smp || count == smp - 1)
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

    % Weight: inversely proportional to distance from tube boundary
    D_tube = bwdist(~U);
    W_tube = Inf(size(U));
    W_tube(U) = 1 ./ (D_tube(U) + 1);

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
        if min_val >= GD(r,c), break; end
        [dr, dc] = ind2sub(size(nbhd), idx);
        r = r0+dr-1; c = c0+dc-1;
        n_path = n_path + 1;
        path(n_path,:) = [r c];
        visited(r,c) = true;
    end
    path = path(1:n_path,:);
    yctk = path(:,1); xctk = path(:,2);

    % Cumulative arc length along path (0 at tip, max at base)
    path_dist = [0; cumsum(sqrt(sum(diff(path).^2, 2)))];

    % DEBUG: save overlay for frames smp and smp-1 (see DIAGNOSTIC BLOCK 1 above)
    if debug_mode && (count == smp || count == smp - 1)
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

    distc_t = pdist2(tip_final(count,:), Qef);
    [tmp, cut] = min(abs(distct - distc_t));
    xc = xct(cut:end); yc = yct(cut:end); distc = distct(cut:end);
    
    % Calculate the gradient of the center line to get the normals
    dx = gradient(xc); dx(find(dx == 0)) = 0.01;
    dy = gradient(yc); dy(find(dy == 0)) = 0.01;

    % Finding the points where the normals hit the edge curves
    poscross1 = []; poscross2 = []; t1_all = zeros(length(xc),1); t2_all = zeros(length(xc),1);
    for n = 1:length(xc)
        nfitc = fit(vertcat(xc(n),(xc(n) - dy(n))),vertcat(yc(n),(yc(n) + dx(n))),'poly1');

        if (n == 1) start_nfitc(:,:) = [nfitc.p1 nfitc.p2]; end

        edge1 = total1(:,1) - nfitc.p1.*total1(:,2) - nfitc.p2;
        [tmp cross1] = min(abs(edge1));
        poscross1(n) = cross1;

        edge2 = total2(:,1) - nfitc.p1.*total2(:,2) - nfitc.p2;
        [tmp cross2] = min(abs(edge2));
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

        [startc1,stopc1] = closest_bound(total1,xc,yc,k_start,k_stop,diamo*2);
        [startc2,stopc2] = closest_bound(total2,xc,yc,k_start,k_stop,diamo*2);

        % Guarantee ordering (tip-end first, needed for polygon construction)
        if stopc1 < startc1, [startc1,stopc1] = deal(stopc1,startc1); end
        if stopc2 < startc2, [startc2,stopc2] = deal(stopc2,startc2); end

        if debug_mode
            fprintf('F%d: arcs %.1f->%.1f  k:%d->%d  c1:%d->%d  c2:%d->%d\n', ...
                count,arc_start_px,arc_stop_px,k_start,k_stop,startc1,stopc1,startc2,stopc2);
        end
        
        % Create masks for rectangles and circles, and include whether they are
        % normal, split or stationary
        if (ROItype ~= 2 | count == smp)
            if (circle == 0)
                roi = vertcat(total1(startc1:stopc1,:), total2(stopc2:-1:startc2,:));
                if (starti < tip_excl_dist) roi = vertcat(boundb(postotal2(1):postotal1(2),:),roi); end
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
                roi1 = vertcat(total1(startc1:stopc1,:), [yc(k_stop:-1:k_start), xc(k_stop:-1:k_start)]);
                roi2 = vertcat(total2(startc2:stopc2,:), [yc(k_stop:-1:k_start), xc(k_stop:-1:k_start)]);
                if (starti < tip_excl_dist)
                    % Stitch from the boundary point actually nearest the tip, not
                    % range2(1) (just the arbitrary bisection index used to split
                    % boundb into range1/range2 for the postotal1/postotal2 scan --
                    % unrelated to where the tip is). The two usually sit close
                    % together (boundb's start point already lands near the tip by
                    % convention), but range2(1) is a coincidence, not a guarantee.
                    % Verified on HV197_4_19 frames 2000-2043: valid frames went
                    % from 42/44 to 44/44 after this change.
                    tip_boundpos = dsearchn(boundb, tip_final(count,:));
                    roi1 = vertcat(boundb(tip_boundpos:postotal1(2),:),roi1,boundb(tip_boundpos,:));
                    roi2 = vertcat(boundb(tip_boundpos:-1:postotal2(1),:),roi2,boundb(tip_boundpos,:));
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
    diamf = diag(pdist2(xy1,xy2));
    diamf_avg(count) = sum(diamf)/length(diamf);
    
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
                diamcutoff, mode, O, BT1r, BT2r, old_intens, debug_mode, max_tip_jump_um);

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
if (pixelsize > 0)
    plot(stp:smp, diamf_avg(stp:smp)*pixelsize, 'b')
    ylabel('µm', 'FontSize',12);
    if ~isempty(dvals), axis([stp-1 smp+1 0.5*max(dvals)*pixelsize 1.25*max(dvals)*pixelsize]); end
else
    plot(stp:smp, diamf_avg(stp:smp), 'b')
    ylabel('pixels', 'FontSize',12);
    if ~isempty(dvals), axis([stp-1 smp+1 0.5*max(dvals) 1.25*max(dvals)]); end
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
csv_wtmean  = intensityM(stp:smp)';
csv_overlap = Ucount(stp:smp)';

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
                  csv_diam_px, csv_diam_um, csv_overlap, csv_wtmean, ...
                  csv_roi_npx, csv_roi_mean, csv_roi_total, ...
                  csv_h1_npx, csv_h1_mean, csv_h1_total, ...
                  csv_h2_npx, csv_h2_mean, csv_h2_total, csv_ratio_h2h1, ...
                  'VariableNames', { ...
                  'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
                  'Diameter_px', 'Diameter_um', 'Frame_overlap_ratio', 'WholeTube_mean_intensity', ...
                  'ROI_pixel_count', 'ROI_mean_intensity', 'ROI_total_signal', ...
                  'Half1_pixel_count', 'Half1_mean_intensity', 'Half1_total_signal', ...
                  'Half2_pixel_count', 'Half2_mean_intensity', 'Half2_total_signal', ...
                  'Ratio_Half2_Half1'});
    else
        T = table(csv_frames, csv_time_s, csv_tip_row, csv_tip_col, ...
                  csv_diam_px, csv_diam_um, csv_overlap, csv_wtmean, ...
                  csv_roi_npx, csv_roi_mean, csv_roi_total, ...
                  'VariableNames', { ...
                  'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
                  'Diameter_px', 'Diameter_um', 'Frame_overlap_ratio', 'WholeTube_mean_intensity', ...
                  'ROI_pixel_count', 'ROI_mean_intensity', 'ROI_total_signal'});
    end
else
    T = table(csv_frames, csv_time_s, csv_tip_row, csv_tip_col, ...
              csv_diam_px, csv_diam_um, csv_overlap, csv_wtmean, ...
              'VariableNames', { ...
              'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
              'Diameter_px', 'Diameter_um', 'Frame_overlap_ratio', 'WholeTube_mean_intensity'});
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
    imagesc(image2);
    clim([0 200]);
    % Time and Frame are two SEPARATE text() calls, not one concatenated
    % string -- Time's own digit count changes over the course of a run,
    % which shifted a single combined string's "Frame: N" left/right frame
    % to frame. Frame is right-aligned against the image width so its
    % position never depends on Time's width.
    timestr = strcat('Time(s): ',num2str(((count-1)*frame_rate)));
    framestr = strcat('Frame: ',num2str(count));
    text(10,10,timestr,'color','white')
    text(size(image2,2)-10,10,framestr,'color','white','HorizontalAlignment','right')
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

function [tip_row, diamf_val, intens, ok, yctk_out, xctk_out, F1_out, F2_out, U_smooth_out] = find_tip_and_measure(count, U, prev_tip, ...
        weight, diamo, tip_method, pixelsize, ROItype, split, circle, starti, stopi, ...
        diamcutoff, mode, O, BT1r, BT2r, old_intens, debug_mode, max_tip_jump_um)

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

    [boundb, tip_ellipse, tip_new, tip_check, diam, maxy, center, phin, axes, stats, edges] = locate_tip(U, tols, Qef);
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
        [tmp, skel_ellipsepos] = min(pdist2(Sef,tip_ellipsef));
        if (last_flag == 1)
            [tmp, skel_lastpos] = min(pdist2(Sef,prev_tip));
            if ((skel_lastpos+skel_ellipsepos+1) > 4) choice = 2; else choice = 1; end
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
        if (tip_ellipsepos>min(tip_choice)-tip_range_tol && tip_ellipsepos<max(tip_choice)+tip_range_tol)
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

    D_tube = bwdist(~U);
    W_tube = Inf(size(U));
    W_tube(U) = 1 ./ (D_tube(U) + 1);
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
        if min_val >= GD(r,c), break; end
        [dr, dc] = ind2sub(size(nbhd), idx);
        r = r0+dr-1; c = c0+dc-1;
        n_path = n_path + 1;
        path(n_path,:) = [r c];
        visited(r,c) = true;
    end
    path = path(1:n_path,:);
    yctk = path(:,1); xctk = path(:,2);
    path_dist = [0; cumsum(sqrt(sum(diff(path).^2, 2)))];

    nline = 1:100; norder = floor(nline*path_dist(end)/100);
    nfinal = dsearchn(path_dist, norder');
    yct = yctk(nfinal); xct = xctk(nfinal); distct = path_dist(nfinal);
    xct = round(sgolayfilt(double(xct),3,15)); yct = round(sgolayfilt(double(yct),3,15));
    xct = max(1, min(xct, size(U,2))); yct = max(1, min(yct, size(U,1)));

    distc_t = pdist2(tip_row, Qef);
    [tmp, cut] = min(abs(distct - distc_t));
    xc = xct(cut:end); yc = yct(cut:end); distc = distct(cut:end);

    dx = gradient(xc); dx(find(dx == 0)) = 0.01;
    dy = gradient(yc); dy(find(dy == 0)) = 0.01;

    poscross1 = []; poscross2 = []; t1_all = zeros(length(xc),1); t2_all = zeros(length(xc),1);
    for n = 1:length(xc)
        nfitc = fit(vertcat(xc(n),(xc(n) - dy(n))),vertcat(yc(n),(yc(n) + dx(n))),'poly1');
        edge1 = total1(:,1) - nfitc.p1.*total1(:,2) - nfitc.p2;
        [tmp, cross1] = min(abs(edge1));
        poscross1(n) = cross1;
        edge2 = total2(:,1) - nfitc.p1.*total2(:,2) - nfitc.p2;
        [tmp, cross2] = min(abs(edge2));
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

        [startc1,stopc1] = closest_bound(total1,xc,yc,k_start,k_stop,diamo*2);
        [startc2,stopc2] = closest_bound(total2,xc,yc,k_start,k_stop,diamo*2);
        if stopc1 < startc1, [startc1,stopc1] = deal(stopc1,startc1); end
        if stopc2 < startc2, [startc2,stopc2] = deal(stopc2,startc2); end

        if (circle == 0)
            roi = vertcat(total1(startc1:stopc1,:), total2(stopc2:-1:startc2,:));
            if (starti < tip_excl_dist), roi = vertcat(boundb(postotal2(1):postotal1(2),:),roi); end
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
            roi1 = vertcat(total1(startc1:stopc1,:), [yc(k_stop:-1:k_start), xc(k_stop:-1:k_start)]);
            roi2 = vertcat(total2(startc2:stopc2,:), [yc(k_stop:-1:k_start), xc(k_stop:-1:k_start)]);
            if (starti < tip_excl_dist)
                tip_boundpos = dsearchn(boundb, tip_row);
                roi1 = vertcat(boundb(tip_boundpos:postotal1(2),:),roi1,boundb(tip_boundpos,:));
                roi2 = vertcat(boundb(tip_boundpos:-1:postotal2(1),:),roi2,boundb(tip_boundpos,:));
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

    diamf = diag(pdist2(xy1,xy2));
    diamf_val = sum(diamf)/length(diamf);
    yctk_out = yctk; xctk_out = xctk;
end