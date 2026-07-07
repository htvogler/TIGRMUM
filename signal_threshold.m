function mask = signal_threshold(frm, method, up_factor, weak_signal)
% Per-frame binary foreground mask, method selectable via threshold_method
% (see run_config.m). Which one to use depends on the signal's intensity
% distribution along the tube, not the imaging mode:
%
%   'otsu'     - per-frame Otsu (mat2gray-normalised). Best when signal
%                intensity is fairly uniform along the tube's length, e.g.
%                yellow cameleon CFP/YFP, where tip and shank are
%                comparably bright. Otsu maximises between-class variance,
%                which assumes roughly two comparable populations
%                (background vs. signal) -- true here.
%   'triangle' - per-frame Triangle/Zack thresholding, eroded by 1px. Best
%                when a small, very bright region sits next to much dimmer
%                but still-real signal, e.g. a saturated GCaMP tip next to
%                a dim shank. Otsu's variance criterion gets pulled toward
%                isolating the rare bright outlier and throws the dim-but-
%                real shank signal away as "background"; Triangle finds
%                where the histogram departs from the background peak
%                instead, regardless of how far the bright tail extends.
%                That low cutoff also reaches into the PSF blur skirt
%                around the whole tube, not just along the dim shank, so
%                the raw mask is eroded by 1px to trim it back toward the
%                visible edge (tested on HV197_4_19: kept the dim shank
%                connected while removing stray background speckle and
%                tightening the outline -- see session notes).
%
% up_factor: spatial upsampling factor applied upstream (see run_config.m's
% `upsample` and main_track_movies.m). Default 1 (no upsampling). The
% erosion radius and area-opening threshold below are calibrated in native-
% resolution pixels -- a linear distance (erosion) scales by up_factor, an
% area (bwareaopen) scales by up_factor^2, so both still correspond to the
% same physical size regardless of how finely the frame has been resampled.

if nargin < 3 || isempty(up_factor), up_factor = 1; end
if nargin < 4 || isempty(weak_signal), weak_signal = false; end

switch method
    case 'otsu'
        mask = imbinarize(mat2gray(frm));
    case 'triangle'
        mask = double(frm) > triangle_threshold(frm);
        mask = imerode(mask, strel('disk', up_factor));
    otherwise
        error('signal_threshold: unknown threshold_method "%s" (use ''otsu'' or ''triangle'')', method);
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
            % Corridor width matches the smaller piece's own local width
            % (regionprops MinorAxisLength), not a thin fixed value -- a
            % corridor much thinner than the real tube creates a visible
            % "dumbbell" pinch that confuses the tip-detection/branch-
            % removal logic downstream even once the pieces are technically
            % one connected component (verified on HV198_1_16 frame 3224).
            rp = regionprops(comp2, 'MinorAxisLength');
            corridor_r = max(up_factor, round(rp.MinorAxisLength / 2));
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
        rp = regionprops(frag, 'MinorAxisLength');
        corridor_r = max(up_factor, round(rp.MinorAxisLength / 2));
        mask = bridge_to_mask(mask, frag, corridor_r);
    end
end
end
