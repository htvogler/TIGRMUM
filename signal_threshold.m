function mask = signal_threshold(frm, method, up_factor, weak_signal, otsu_sensitivity)
% Per-frame binary foreground mask, method selectable via threshold_method
% (see run_config.m). Which one to use depends on the signal's intensity
% distribution along the tube, not the imaging mode:
%
%   'otsu'     - per-frame Otsu (mat2gray-normalised), biased by
%                otsu_sensitivity (see below). DEFAULT for GCaMP (bright tip
%                next to a dimmer-but-still-clearly-above-background shank),
%                given otsu_sensitivity=0.7 -- reversing an earlier
%                recommendation to use 'triangle' for this case. Compared
%                directly against 'triangle' on a real GCaMP dataset
%                (HV207_9): once otsu_sensitivity is relaxed enough to stop
%                severing the mask on real per-frame signal dips (~0.7 was
%                sufficient there), otsu comes out ahead on every axis
%                checked -- closer to the true diameter (measured
%                independently via cross-sectional FWHM: otsu ~14% over vs.
%                triangle ~36% over), visibly smoother/less spiky mask
%                boundary (confirmed directly in real pipeline diagnostic
%                images, not just a proxy metric), and ~3x more stable
%                frame-to-frame diameter (jitter std 0.16px vs 0.52px over
%                600 real consecutive frames). Mechanism: triangle's cutoff
%                sits close to the background noise floor to catch the dim
%                shank, which is exactly the regime most exposed to
%                per-frame noise fluctuation and most prone to small
%                boundary speckle; otsu's (even relaxed) cutoff sits well
%                clear of that floor.
%   'triangle' - per-frame Triangle/Zack thresholding, eroded by 1px. Now
%                reserved for GENUINELY weak signal specifically -- the tip
%                still bright, but the shank barely above the background
%                noise floor at all (not just dimmer than the tip). In that
%                regime otsu_sensitivity has no good setting: relaxed enough
%                to admit the barely-visible shank, it also admits
%                background noise broadly (there's no longer a comfortable
%                margin between "real dim shank" and "noise" for a fixed
%                fraction-of-Otsu-level cut to exploit). Triangle finds
%                where the histogram departs from the background peak's own
%                shape instead of applying a fixed offset, so it can still
%                separate real-but-faint signal from noise here. That low
%                cutoff also reaches into the PSF blur skirt around the
%                whole tube, not just along the dim shank, so the raw mask
%                is eroded by 1px to trim it back toward the visible edge
%                (tested on HV197_4_19: kept the dim shank connected while
%                removing stray background speckle and tightening the
%                outline -- see session notes).
%   'bgsigma2' - background-mean-plus-2-sigma. Estimates the background
%   'bgsigma3'   peak's own mean/std directly from the histogram (not a
%                geometric line-distance criterion like Triangle), then
%                thresholds at mean + k*std (k=2 or 3). Verified on
%                HV198_1_16: Triangle's own threshold sits ~7 background-
%                sigma out -- needlessly strict for a roughly-Gaussian
%                noise floor (measured std ~1 count, consistent across
%                the stack), and undercounts real tube width by roughly
%                half (~3.7um measured vs the ~5.3um an Arabidopsis PT
%                should be, cross-checked against a generous "anything
%                clearly above background" threshold on the raw,
%                pre-upsampling input). k=2 matches that ~5.3um width
%                most closely but pulls in more scattered background
%                speckle before bwareaopen/keep_and_bridge_blobs cleans
%                it up (verified: ~2-3x more raw connected components
%                than Triangle); k=3 is a middle ground, still a clear
%                accuracy improvement over Triangle with cleanliness
%                closer to Triangle's own. Experimental -- not yet the
%                default for any dataset, added specifically to compare
%                side by side against Triangle/Otsu on real data. Not
%                re-benchmarked against the otsu_sensitivity findings above.
%
% otsu_sensitivity: multiplier on the raw Otsu level (graythresh), otsu
% method only. Default 1.0 (unbiased Otsu) when not passed -- run_config.m
% should set 0.7 for GCaMP-style signals (see 'otsu' above). <1.0 lowers the
% effective cutoff, admitting more of the dim-but-real signal as
% foreground. There isn't a universally-correct value -- it's the point
% where per-frame severing on real signal dips stops (too high) without yet
% admitting broad background speckle (too low); 0.7 was sufficient on
% HV207_9 and 0.8 was not, but this hasn't been swept on other datasets.
%
% up_factor: spatial upsampling factor applied upstream (see run_config.m's
% `upsample` and main_track_movies.m). Default 1 (no upsampling). The
% erosion radius and area-opening threshold below are calibrated in native-
% resolution pixels -- a linear distance (erosion) scales by up_factor, an
% area (bwareaopen) scales by up_factor^2, so both still correspond to the
% same physical size regardless of how finely the frame has been resampled.

if nargin < 3 || isempty(up_factor), up_factor = 1; end
if nargin < 4 || isempty(weak_signal), weak_signal = false; end
if nargin < 5 || isempty(otsu_sensitivity), otsu_sensitivity = 1.0; end

switch method
    case 'otsu'
        % See otsu_sensitivity doc above. NOTE: imbinarize's own
        % 'Sensitivity' name-value pair only applies to its 'adaptive'
        % method, not global Otsu (confirmed via a real runtime error --
        % 'global'/plain imbinarize doesn't accept it) -- this multiplies
        % graythresh's own level directly instead, which is the actual
        % equivalent knob for global Otsu.
        normfrm = mat2gray(frm);
        mask = normfrm > (otsu_sensitivity * graythresh(normfrm));
    case 'triangle'
        mask = double(frm) > triangle_threshold(frm);
        mask = imerode(mask, strel('disk', up_factor));
    case {'bgsigma2', 'bgsigma3'}
        if strcmp(method, 'bgsigma2'), k = 2; else, k = 3; end
        mask = double(frm) > background_sigma_threshold(frm, k);
    otherwise
        error('signal_threshold: unknown threshold_method "%s" (use ''otsu'', ''triangle'', ''bgsigma2'', or ''bgsigma3'')', method);
end

% Strip small disconnected noise specks here, at the source, not just in the
% tracking mask U (which already does this via bwareaopen+bwareafilt further
% downstream in main_track_movies.m). This mask also feeds BT1/BT2/M/L
% directly -- without this, M (and the intensity video built from it) shows
% every stray speck that survives per-pixel thresholding, even though the
% tracking pipeline discards them. Verified on HV197_4_19 frame 2042: 38
% separate connected components in the raw per-pixel mask (one real tube at
% 2930px, 37 noise blobs, 32 of them under 10px) -- bwareaopen+bwareafilt
% here reduces that to the single real component, matching what U already
% gets downstream.
% weak_signal only: don't let bwareaopen discard a small-but-real component
% just because it's small, if it touches the crop's edge -- a fragment
% reaching the field boundary is far more likely to be the tube's own
% base/attachment point (which main_track_movies.m later assumes reaches
% one particular border, to close off the tracked shape there) than
% scattered noise, which has no reason to specifically hug an edge. Found
% on HV198_1_16 3185-3301: 18 of 48 frames where the tracking mask failed
% to reach that border had a real, connected fragment sitting right at the
% edge that bwareaopen discarded purely for being smaller than the area
% floor -- not because it wasn't real signal.
if weak_signal
    lbl0 = bwlabel(mask);
    edge_mask = false(size(mask));
    edge_mask([1 end], :) = true; edge_mask(:, [1 end]) = true;
    edge_labels = setdiff(unique(lbl0(edge_mask & mask)), 0);
    edge_frags = ismember(lbl0, edge_labels);
else
    edge_frags = false(size(mask));
end
mask = bwareaopen(mask, round(100 * up_factor^2)) | edge_frags;

% Component selection: normally keep only the single largest piece (a real
% tube is one connected object; anything else surviving bwareaopen this far
% is noise). weak_signal only: if the tube's own signal has a real, but
% transient, dip below threshold at one point, the mask can genuinely sever
% into two large, comparable-sized, adjacent pieces instead of many small
% noise flecks -- bwareafilt(1) would then silently discard HALF THE REAL
% TUBE (verified on HV198_1_16 frame 3068: 4137px/3814px split, a near-even
% 52/48, at a completely unremarkable per-pixel threshold level -- not an
% outlier threshold, just an unlucky per-frame signal dip). Bridge the top
% two components into one instead of picking a "winner" when they look like
% fragments of the same object: both substantial (2nd piece >= 25% the size
% of the 1st -- comfortably above bwareaopen's own noise floor, so this only
% fires for two real blobs, not a real blob plus a noise fleck) and close
% enough that bridging the gap is itself smaller than the smaller piece
% (gap <= 3*sqrt(area2), i.e. the gap is at most a few tube-widths).
bridged = false;
if weak_signal
    lbl = bwlabel(mask);
    ncomp = max(lbl(:));
    if ncomp >= 2
        areas = zeros(ncomp, 1);
        for ci = 1:ncomp, areas(ci) = nnz(lbl == ci); end
        [areas_sorted, order] = sort(areas, 'descend');
        comp1 = lbl == order(1);
        comp2 = lbl == order(2);
        [D, IDX] = bwdist(comp1);
        gap = double(min(D(comp2)));
        if areas_sorted(2) >= 0.25 * areas_sorted(1) && gap <= 3 * sqrt(areas_sorted(2))
            % Connect the two components with a corridor instead of dilating
            % the whole union by bridge_r -- dilating both full components
            % inflates the entire mask, not just the seam (found on
            % HV198_1_16 3185-3301: 31% of frames bridged, some with gaps up
            % to ~29px, so bridge_r up to 16 -- fattening the WHOLE tube 3x+
            % over its normal pixel count). comp1/comp2 keep their exact
            % original shape; only a corridor gets added between them.
            % Corridor width matches the smaller piece's own local width --
            % estimated as Area/MajorAxisLength (average cross-section along
            % its length), NOT regionprops MinorAxisLength. MinorAxisLength
            % comes from an ellipse fit to the WHOLE region's second moments,
            % which is only a sane width proxy for a straight blob -- for a
            % bent/curved fragment (this dataset's tube has a visible zigzag)
            % it reflects the bend's overall perpendicular spread instead,
            % wildly overestimating local width. Verified on HV198_1_16
            % frame 3267: comp1 (a genuine, otherwise-normal ~16px-wide tube
            % segment) had MinorAxisLength=82.6px; comp2 had 66.1px -- using
            % either as corridor_r produced a "balloon" several times the
            % real tube width. Area/MajorAxisLength gave 17.7 and 16.7 for
            % the same two components -- matching this frame's real diamo
            % (~15-16px) closely.
            rp = regionprops(comp2, 'MajorAxisLength');
            if rp.MajorAxisLength > 0
                corridor_r = max(up_factor, round((areas_sorted(2) / rp.MajorAxisLength) / 2));
            else
                corridor_r = up_factor; % degenerate (near-point) component -- no width to estimate
            end
            mask = bridge_to_mask(comp1, comp2, corridor_r);
            bridged = true;
            fprintf('  signal_threshold: bridged 2 components (%d px + %d px, gap %.1f px, corridor width %d)\n', ...
                areas_sorted(1), areas_sorted(2), gap, corridor_r);
        end
    end
end
if ~bridged
    mask = bwareafilt(mask, 1);
end

% weak_signal only: reconnect any edge fragment kept above (specifically so
% it wouldn't be silently discarded here) that the component-selection step
% just above didn't already include -- bwareafilt(1) keeps only the single
% largest piece, and the two-component bridge only looks at the top 2 by
% area, so a small edge fragment is usually neither. Same thin-corridor
% technique as that bridge: connect each stranded fragment to whichever
% piece ended up as the final mask, rather than leaving it disconnected and
% then implicitly losing it anyway.
if weak_signal && any(edge_frags(:))
    lbl_e = bwlabel(edge_frags);
    for ei = 1:max(lbl_e(:))
        frag = lbl_e == ei;
        if any(frag(:) & mask(:)), continue; end
        rp = regionprops(frag, 'MajorAxisLength', 'Area');
        if rp.MajorAxisLength > 0
            corridor_r = max(up_factor, round((rp.Area / rp.MajorAxisLength) / 2));
        else
            corridor_r = up_factor; % degenerate (near-point) fragment -- no width to estimate
        end
        % Same gap sanity check as the two-component bridge above -- an
        % edge-touching fragment far from the main mask is far more likely
        % unrelated debris than a real gap in the tube's own signal.
        % Without this, a small far-away fragment gets bridged with a long,
        % arbitrary corridor unrelated to the tube (confirmed on
        % HV200_2_24_cropped: ~148px corridor to a 1-8px far-corner speck;
        % recurred on 20260327_2: a corridor down to a fragment near the
        % opposite crop edge, which then fed into diamo and cascaded into
        % oversized close_r/ws_smooth_r on later frames).
        D = bwdist(mask);
        gap = double(min(D(frag)));
        if gap > 3 * sqrt(rp.Area)
            continue;
        end
        mask = bridge_to_mask(mask, frag, corridor_r);
    end
end

% Modest boundary smoothing (bgsigma methods only): this mask becomes
% M/BT1/L, which feeds the intensity video and kymograph DIRECTLY --
% unlike the tracking mask U (built fresh, frame by frame, inside
% main_track_movies.m's own loop), nothing downstream ever smooths this
% one, so any per-pixel jaggedness right at the true edge (expected and
% harmless for a looser threshold like bgsigma2 -- confirmed the tracking
% pipeline's own bwareaopen/imclose/keep_and_bridge_blobs already cleans
% it up fine for tracking purposes) was going straight into the displayed
% video looking rough. Scoped to bgsigma2/bgsigma3 only -- confirmed on
% HV198_1_16 that applying this to 'triangle' too regresses its valid-
% frame count (13/20 -> 7/20 on a 20-frame test): triangle already has
% its own erosion step suited to its narrower profile, and stacking this
% imopen on top over-thins it. bgsigma2/bgsigma3 were unaffected by the
% same test (21/21 both before and after, diameters within noise).
if ismember(method, {'bgsigma2', 'bgsigma3'})
    mask = imopen(imclose(mask, strel('disk', up_factor)), strel('disk', up_factor));
    mask = bwareafilt(mask, 1); % smoothing can occasionally pinch off a sliver -- keep just the main piece
end
end

function thr = background_sigma_threshold(frm, k)
% Threshold at k standard deviations above the background peak's own
% mean, estimated directly from the histogram rather than assumed at a
% fixed absolute value -- scale-independent, so it works the same whether
% frm is raw camera counts or already bit-depth-rescaled/upsampled.
vals = double(frm(:));
nbins = 256;
[counts, edges] = histcounts(vals, nbins);
centers = (edges(1:end-1) + edges(2:end)) / 2;
[peak_count, peak_bin] = max(counts);
% Background population: bins from the peak up to the first point where
% the count drops below half the peak count -- the same "departure from
% the background peak" idea triangle_threshold.m is built on, used here
% to characterise the peak's own spread instead of finding a geometric
% line-distance point along the whole histogram.
half_peak = peak_count / 2;
bg_cutoff_bin = peak_bin;
for bi = peak_bin:nbins
    if counts(bi) < half_peak
        bg_cutoff_bin = bi;
        break;
    end
end
bg_vals = vals(vals <= centers(bg_cutoff_bin));
if numel(bg_vals) < 10
    bg_vals = vals(vals <= centers(peak_bin));
end
thr = mean(bg_vals) + k * std(bg_vals);
end
