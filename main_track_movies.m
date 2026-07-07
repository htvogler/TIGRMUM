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
[fribra_dir, ~, ~] = fileparts(pathf);
[root_dir,   ~, ~] = fileparts(fribra_dir);
outpath = fullfile(root_dir, 'TIGRMUM_results', fname);
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

% Loop backwards over stack
if (distributions), d = 1; end
U_prev = [];
right_anchor_row_last = []; % weak_signal border-extension continuity, see below
frame_failed = false(smp, 1);
if ~exist('V_frame_size','var'), V_frame_size = []; end
Vroi_frame_size = [];
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
    U = bwareaopen(P, round(100 * up_factor^2));
    U = bwareafilt(U,1);

    % weak_signal only: use the reference (first analysed, i.e. count==smp)
    % frame's own full mask -- not a thin centerline -- as a spatial prior
    % for which nearby real signal (P) pixels should count as tube. A full
    % 2D mask, dilated by a small margin, naturally covers the tube's actual
    % width and shape, not just an idealised 1px path -- verified on
    % HV198_1_16 3185-3301: dilating the reference frame's mask by just 5px
    % (native; scaled by up_factor here) already covers 98-100% of every
    % other frame's own mask in this range, including badly split/truncated
    % ones. Replaces the old centerline-based (yctk_smp/xctk_smp) version of
    % this same idea, which needed a bounding-box-clip workaround
    % specifically because a 1D line has no width of its own to be a shape
    % prior with.
    %
    % Only bridge COHERENT fragments here, same area floor as bwareaopen
    % above -- not every scattered raw-threshold pixel that happens to fall
    % within the (fairly generous) dilated region. An earlier version just
    % unioned in P & U_ref_grown wholesale: on frames with only a few
    % noise-level hits in that region, this created several tiny 1-12px
    % "whisker" appendages, each becoming a spurious skeleton endpoint
    % (verified: pushed one frame's endpoint count from 20 to 23, another's
    % 18 to 24) -- branch_removal and the tip-selection logic downstream
    % assume a simple tip+base skeleton and broke on the extra branches,
    % producing the "Colon operands must be real scalars" warnings and
    % occasional hard crashes the user hit. Each qualifying fragment is
    % bridged with a proper corridor (bridge_to_mask.m), not a plain union,
    % so it's guaranteed to end up in the same connected component as U
    % rather than leaving the skeleton looking at two separate blobs.
    % The loop walks backward from the reference (longest/most-grown) frame
    % toward earlier, shorter ones -- the tube's tip keeps receding as count
    % decreases, so U_smp's OWN tip region is never valid for any other
    % frame. Cap U_ref_grown so it can never extend past this frame's own
    % plain (pre-rescue) reach, plus a small margin to still allow filling a
    % gap right at the current tip -- the reference must only ever help
    % with the stationary base/shank, never redefine where the tip is.
    U_ref_grown = [];
    if weak_signal && exist('U_smp', 'var')
        U_ref_grown = imdilate(U_smp, strel('disk', round(5 * up_factor)));
        [~, Uc_plain] = find(U);
        if ~isempty(Uc_plain)
            tip_margin = round(5 * up_factor);
            min_allowed_col = max(1, min(Uc_plain) - tip_margin);
            U_ref_grown(:, 1:(min_allowed_col - 1)) = false;
        end
        candidates = bwlabel(P & U_ref_grown & ~U);
        for ci = 1:max(candidates(:))
            frag = candidates == ci;
            if nnz(frag) < round(100 * up_factor^2), continue; end
            if exist('diamo', 'var')
                corridor_r = max(1, round(diamo / 2));
            else
                rp = regionprops(frag, 'MinorAxisLength');
                corridor_r = max(up_factor, round(rp.MinorAxisLength / 2));
            end
            U = bridge_to_mask(U, frag, corridor_r);
        end
    end

    % Gap repair: recover disconnected P pieces close to U and aligned with its axis
    Ustats = regionprops(U, 'Centroid', 'Orientation', 'MajorAxisLength');
    if ~isempty(Ustats)
        prox_dist = max(round(30 * up_factor), round(Ustats.MajorAxisLength * 0.15));
        U_grown = imdilate(U, strel('disk', prox_dist));
        Pother = bwlabel(P & ~U);
        U_prev_grown = [];
        if ~isempty(U_prev)
            U_prev_grown = imdilate(U_prev, strel('disk', prox_dist));
        end
        % Opt-in via weak_signal, like the reference-mask block above: prox_dist has
        % a 30px floor, which in a small crop is close to half the frame, so
        % the proximity gate barely filters anything. The temporal test then
        % unconditionally re-admits any disconnected P piece that overlaps
        % the previous frame's (dilated) mask -- a persistent, fixed-position
        % artifact (dust speck, hot pixel) recurring near the tube satisfies
        % that every frame and gets rescued back into U indefinitely, even
        % though bwareaopen/bwareafilt just discarded it as a small
        % disconnected component (verified on HV197_4_19 frame 2015: a lone
        % stray pixel 4 rows from the tube's true edge, thickening the
        % border by ~1-2px over the last few columns before the crop edge).
        if weak_signal
            for k = 1:max(Pother(:))
                piece = Pother == k;
                % Proximity gate
                if ~any(U_grown(:) & piece(:)), continue; end
                % Temporal test: piece overlaps previous frame's mask → include unconditionally
                if ~isempty(U_prev_grown) && any(U_prev_grown(:) & piece(:))
                    U = U | piece;
                    continue;
                end
                % Fallback: orientation check (first frame or no U_prev overlap)
                ps = regionprops(piece, 'Centroid');
                v = ps.Centroid - Ustats.Centroid;
                ang = abs(mod(atan2d(-v(2), v(1)) - Ustats.Orientation + 90, 180) - 90);
                if ang <= 35
                    U = U | piece;
                end
            end
        end
    end
    U = bwmorph(U,'clean');
    U = medfilt2(U);
    % Re-apply the reference-mask rescue: medfilt2 can erode away thin,
    % single-pixel-wide connections just added above. Same coherent-
    % fragment-only, corridor-bridged approach as above, not a raw union.
    if ~isempty(U_ref_grown)
        candidates = bwlabel(P & U_ref_grown & ~U);
        for ci = 1:max(candidates(:))
            frag = candidates == ci;
            if nnz(frag) < round(100 * up_factor^2), continue; end
            if exist('diamo', 'var')
                corridor_r = max(1, round(diamo / 2));
            else
                rp = regionprops(frag, 'MinorAxisLength');
                corridor_r = max(up_factor, round(rp.MinorAxisLength / 2));
            end
            U = bridge_to_mask(U, frag, corridor_r);
        end
    end
    % Closing radius scaled to the tube's own measured width (diamo) rather
    % than a fixed pixel count: a fixed radius (originally disk(10), unchanged
    % since the very first commit) is only appropriate for whatever
    % magnification/binning produced that many pixels per tube-diameter --
    % on a narrower image (e.g. 40x + 1.6x vs 20x) the same radius is
    % disproportionately large relative to the tube and permanently fills in
    % concave bends during the dilate step (verified on HV197_4_19 frame
    % 2042: disk(10) added 81px at the tube's elbows vs 2px for disk(1)).
    % diamo isn't calibrated yet on the very first (smp) frame -- fall back
    % to a small constant for that one frame only.
    if exist('diamo','var')
        close_r = max(1, round(diamo * 0.15));
    else
        close_r = round(2 * up_factor);
    end
    U = imclose(U, strel('disk', close_r));
    % weak_signal only: erode small spikes/whiskers off the boundary the
    % same way imclose (just above) fills small bays/notches -- same
    % diamo-scaled radius, opposite morphological operation. Not applied
    % outside weak_signal since it changes the mask shape for datasets that
    % never asked for this smoothing.
    if weak_signal
        U = imopen(U, strel('disk', close_r));
    end
    % Final component selection: normally single-largest, same as always.
    % weak_signal only: also keep any component overlapping the reference
    % footprint, regardless of size -- a rescued fragment from the U_ref
    % block above isn't guaranteed to have actually merged into the main
    % blob by this point (imclose only bridges gaps up to ~close_r), so
    % plain bwareafilt(1) could still silently drop it right back out here.
    if weak_signal && ~isempty(U_ref_grown)
        lblU = bwlabel(U);
        ref_labels = setdiff(unique(lblU(U_ref_grown & U)), 0);
        keep_ref = ismember(lblU, ref_labels);
        U = bwareafilt(U, 1) | keep_ref;
    else
        U = bwareafilt(U, 1);
    end
    U_prev = U;
    if weak_signal && count == smp, U_smp = U; end

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

    % ---- DIAGNOSTIC BLOCK 1: binarisation pipeline (frame smp-1) ----
    % smp-1 is the SECOND frame processed (loop runs smp:-1:stp), so it
    % inherits U_prev/diamo/tip_final_last correctly primed by frame smp —
    % unlike frame smp itself, which always starts cold. To debug frame N,
    % set smp = N+1.
    if debug_mode && count == smp - 1
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
   
    % Skeletonizing and finding endpoints
    S = bwmorph(U,'skel',Inf);
    Se = bwmorph(S,'endpoints');
    [Ser,Sec] = find(Se > 0);
    Sel = [Ser Sec];
    
    % Skeltonizing and finding branchpoints
    Sb = bwmorph(S,'branchpoints');
    [Sbr,Sbc] = find(Sb > 0);
    Sbl = [Sbr Sbc];
    
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
                diamo_samples(end+1) = max(drows) - min(drows);
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
        if debug_mode
            fprintf('  diamo F%d: single-col=%.1fpx multi-col-median=%.1fpx (n=%d cols) samples=%s\n', ...
                count, diam, diamo, numel(diamo_samples), mat2str(diamo_samples));
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
                fprintf('  tip F%d: branchpt=%d branched choice=%d ellipsepos=%d NOT in [%d,%d] overshoot=%d last_flag=%d -> %s (ellipsedist=[%.1f %.1f])\n', ...
                    count, ~isempty(Sbl), choice, tip_ellipsepos, min(tip_choice), max(tip_choice), overshoot, last_flag, srclabel, tip_ellipsedist(1), tip_ellipsedist(2));
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
            frame_failed(count) = true;
            if debug_mode
                fprintf('  tip F%d: jump=%.2fum > max_tip_jump_um=%.1fum -- flagged, results NaN''d\n', ...
                    count, tip_jump_um, max_tip_jump_um);
            end
        end
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

    % ---- DIAGNOSTIC BLOCK 2: skeleton + geometry (frame smp-1, see BLOCK 1) ----
    if debug_mode && count == smp - 1
        dp  = fullfile(outpath, sprintf('diag_%d', count));
        sz1 = size(U,1); sz2 = size(U,2);

        imwrite(imdilate(Q,  strel('disk',1)), [dp '_10_Q_thin.png']);
        imwrite(imdilate(Q2, strel('disk',1)), [dp '_11_Q2_debranched.png']);

        Rch = uint8(U)*80; Gch = uint8(U)*80; Bch = uint8(U)*80;
        Qd  = imdilate(Q,  strel('disk',1)); Rch = Rch + uint8(Qd)*170;
        Q2d = imdilate(Q2, strel('disk',1)); Gch = Gch + uint8(Q2d)*170;
        if ~isempty(Qef)
            re = max(1,Qef(1,1)-4):min(sz1,Qef(1,1)+4);
            ce = max(1,Qef(1,2)-4):min(sz2,Qef(1,2)+4);
            Bch(re,ce) = 255;
        end
        imwrite(cat(3,Rch,Gch,Bch), [dp '_12_skeleton_overlay.png']);

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

    % DEBUG: save overlay for frame smp-1 (see DIAGNOSTIC BLOCK 1 above)
    if debug_mode && (count == smp - 1)
        dbg = zeros(size(U,1), size(U,2), 3);
        dbg(:,:,3) = double(U) * 0.4;   % tube mask: dark blue
        dbg(:,:,2) = double(Q) * 0.8;   % Q skeleton: green
        % traced path in white
        for di = 1:size(path,1)
            dbg(path(di,1), path(di,2), :) = [1 1 1];
        end
        % right anchor in cyan
        dbg(right_anchor(1), right_anchor(2), :) = [0 1 1];
        % tip_final in magenta
        dbg(tip_final(count,1), tip_final(count,2), :) = [1 0 1];
        imwrite(dbg, fullfile(outpath, [fname '_debug_skel.png']));
        disp(['DEBUG saved: ' fullfile(outpath, [fname '_debug_skel.png'])]);
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
    poscross1 = []; poscross2 = [];
    for n = 1:length(xc)
        nfitc = fit(vertcat(xc(n),(xc(n) - dy(n))),vertcat(yc(n),(yc(n) + dx(n))),'poly1');
    
        if (n == 1) start_nfitc(:,:) = [nfitc.p1 nfitc.p2]; end
        
        edge1 = total1(:,1) - nfitc.p1.*total1(:,2) - nfitc.p2;
        [tmp cross1] = min(abs(edge1));
        poscross1(n) = cross1;
        
        edge2 = total2(:,1) - nfitc.p1.*total2(:,2) - nfitc.p2;
        [tmp cross2] = min(abs(edge2));
        poscross2(n) = cross2;
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
        kymo_avg(:,count-stp+1) = vertcat(zeros((5 + npoints - kymo_len),1), mean(kymo,2));

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

    % Tip plot
    Splot = zeros(size(Q2));
    r1 = max(1,tip_final(count,1)-3); r2 = min(size(Splot,1),tip_final(count,1)+3);
    c1 = max(1,tip_final(count,2)-3); c2 = min(size(Splot,2),tip_final(count,2)+3);
    Splot(r1:r2,c1:c2) = 1;
 %   Splot(tip_ellipsef(1)-1:tip_ellipsef(1)+1,tip_ellipsef(2)-1:tip_ellipsef(2)+1) = 2;
 %   if (size(Sef,1) > 1) Splot(tip_mid(1)-3:tip_mid(1)+3,tip_mid(2)-3:tip_mid(2)+3) = 3; end
 %   Splot(tip_skel(1)-1:tip_skel(1)+1,(2)-1:tip_skel(2)+1) = 4;
    
    Cplot = zeros(size(Q2)); Cplot(sub2ind([size(Cplot,1) size(Cplot,2)],yctk,xctk)) = 2.*ones(size(xctk));
    %for j = 1:length(xy1) Cplot = drawline(Cplot,xy1(j,1),xy1(j,2),xy2(j,1),xy2(j,2),1); end
    Cplot(:,size(U,2)+1:end) = [];
    
    % Plot two images
    h = figure('visible', 'off');

    %subplot(1,2,2)
    image2 = U*20+Splot*40+Cplot*30;
    if (ROItype > 0) image2 = image2 + double(F1*60 + F2*80); end
    imagesc(image2);

    if (tip_plot)
        txtstr = strcat('Time(s): ',num2str((count*frame_rate)),'  Frame: ',num2str(count));
        text(10,10,txtstr,'color','white')
        set(gca,'xtick',[]);
        set(gca,'xticklabel',[]);
        set(gca,'ytick',[])
        set(gca,'yticklabel',[]);
        frame = getframe(gcf);
        writeVideo(V,frame);
        if isempty(V_frame_size), V_frame_size = size(frame.cdata); end
    end
    close(h);

    if roi_debug_video
        % O, not L: L is built once for the whole stack and is never
        % per-frame rotated, while O/U/F1/F2/Cplot all are (see the
        % imrotate block earlier in this loop) -- using L here would
        % misalign the overlay against the ROI geometry.
        Od = min(255, double(O)./Cmax.*255);
        % Reserve index 1 for pure black, same as video_processing.m's map --
        % without it, jet(256)'s own index-1 colour (dark blue, not black)
        % renders the zeroed background as a solid dark-blue field instead
        % of black, since O==0 always maps to index 1.
        jetmap = uint8(vertcat([0 0 0], jet(255)) .* 255);
        idx = uint8(Od) + 1;
        rgb = reshape(jetmap(idx(:),:), size(O,1), size(O,2), 3);
        rch = rgb(:,:,1); gch = rgb(:,:,2); bch = rgb(:,:,3);
        % Outline each ROI half (solid colour, not a blend) so the split is
        % visible regardless of the underlying jet colour -- a 50% blend was
        % nearly invisible against jet's own warm tip colours (verified:
        % the F2/blue blend against a near-zero-blue jet red pixel produced
        % [.,.,128], barely distinguishable from the unblended tip colour).
        % bwperim, not imerode-based edge detection, since it still returns
        % a usable boundary even when the ROI is only a few px wide.
        % bwperim/the traced skeleton are always exactly 1px wide regardless
        % of resolution -- at up_factor=2 that's half as visually prominent
        % relative to the (now 2x wider) tube as it was natively. Thicken
        % both by the same up_factor so the overlay stays equally visible
        % whether or not upsampling is on (verified: without this, the ROI
        % outline/centerline were still being drawn correctly at up_factor=2,
        % just too thin to notice against the tube at a normal viewing size).
        line_r = max(0, up_factor - 1);
        if (ROItype > 0)
            f1_edge = bwperim(logical(F1));
            f2_edge = bwperim(logical(F2));
            if line_r > 0
                f1_edge = imdilate(f1_edge, strel('disk', line_r));
                f2_edge = imdilate(f2_edge, strel('disk', line_r));
            end
            rch(f1_edge) = 255; gch(f1_edge) = 0;   bch(f1_edge) = 0;
            rch(f2_edge) = 0;   gch(f2_edge) = 0;   bch(f2_edge) = 255;
        end
        % Traced centerline as a bright white line on top of everything.
        clm = logical(Cplot);
        if line_r > 0, clm = imdilate(clm, strel('disk', line_r)); end
        rch(clm) = 255; gch(clm) = 255; bch(clm) = 255;
        rgb_roi = cat(3, rch, gch, bch);
        if exist('insertText','file')
            txtstr = ['Time(s): ' num2str(count*frame_rate) '  Frame: ' num2str(count)];
            rgb_roi = insertText(rgb_roi,[5 5],txtstr,'FontSize',8,'TextColor','white','BoxOpacity',0);
        end
        writeVideo(Vroi, rgb_roi);
        if isempty(Vroi_frame_size), Vroi_frame_size = size(rgb_roi); end
    end
    catch ME
        warning('TIGRMUM: frame %d failed — %s (%s:%d)', count, ME.message, ME.stack(1).name, ME.stack(1).line);
        frame_failed(count) = true;
        if tip_plot && ~isempty(V_frame_size)
            writeVideo(V, zeros(V_frame_size, 'uint8'));
        end
        if roi_debug_video && ~isempty(Vroi_frame_size)
            writeVideo(Vroi, zeros(Vroi_frame_size, 'uint8'));
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

if (tip_plot == 1) close(V); end
if roi_debug_video, close(Vroi); end

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
csv_time_s  = csv_frames .* frame_rate;
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