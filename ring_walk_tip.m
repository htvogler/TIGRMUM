function [tip_final, walk_path] = ring_walk_tip(U, anchor, varargin)
% RING_WALK_TIP  Trace from a base anchor point outward along a tube mask
% to its tip via a sequence of expanding ring-intersection centroids --
% an alternative to skeleton+branch_removal tip-finding that never builds
% a skeleton graph, so it can't inherit branch_removal.m's specific
% failure mode (a single stray pixel flipping which endpoint survives
% pruning at a sharp bend -- confirmed via console-log evidence on
% HV200_2_24_cropped frames 1482/1500 this session: garbled fprintf
% output from a 2-element Qef, and a visibly wandering traced tip).
%
% Mechanism (after Zhu et al. 2025, Adv. Sci., doi:10.1002/advs.202507434
% -- github.com/HeyyFrank/Automated-LoC-Approach-for-Pollen-Tube-Growth-
% Manipulation, bg_tracker.py's fluo_track/ring_mask/outer_mask -- adapted
% here with a T-junction/side-branch safeguard their algorithm didn't
% need, since they only ever handle unbranched tubes): starting at
% `anchor`, repeatedly draw a ring sized to the local tube width around
% the current point, take the centroid of wherever the ring crosses the
% not-yet-visited mask, and move there. Stop when a ring crosses nothing
% (end of tube) or when the crossing's own width collapses to less than
% half the previous step's (their signal for "this is the tip").
%
% U:      binary tube mask for this frame (post weak_signal repair if on
%         -- this function only ever reads U, same as branch_removal.m's
%         skeleton did; mask-building is a separate, upstream concern)
% anchor: [row col], on U's own border -- pass the same point
%         main_track_movies.m already computes as `right_anchor`, don't
%         recompute it here
%
% Name-value options (all optional):
%   k_ring         ring radius = k_ring * local_width/2 (default 1.3)
%   k_cut          consumed-region radius = k_cut * local_width/2, must be
%                  > k_ring so the NEXT ring always has a fresh buffer
%                  beyond what was just marked consumed (default 1.7)
%   thickness      ring thickness in px (default 3)
%   width_collapse stop when new width < this * previous width (default 0.5)
%   max_steps      hard cap, safety against runaway loops (default 500)
%   prev_tip       [row col], the PREVIOUS FRAME's tip_final, if available
%                  (pass tip_final_last, gated behind last_flag, same as
%                  the skeleton method already does). Used only as the
%                  cold-start tiebreak (the first ring off the anchor,
%                  before any within-walk direction exists) when a real
%                  fork sits right at the anchor -- prefer whichever
%                  candidate is closer to where the tip actually was last
%                  frame, instead of pure nearest-by-raw-distance,  which
%                  has no way to prefer the historically-correct branch
%                  over a coincidentally-closer wrong one. Verified needed
%                  on HV200_3_23: a persistent real fork near the base
%                  made the walk flip-flop between two branches frame to
%                  frame (mean step 17px, max 193px vs skeleton's 4px/15px
%                  on the same stack) -- skeleton avoids this because its
%                  own branch-choice voting already uses tip_final_last;
%                  ring_walk_tip had no cross-frame memory at all before
%                  this parameter existed.
%
% Returns tip_final ([row col], the last valid point before stopping) and
% the full walk_path (Nx2, base to tip) for optional debug/comparison
% against the skeleton-based tip_final.
%
% Verified (Python prototype, this session) on: a straight tube (0.3px
% error), a moderate real-shaped zigzag bend (~6px error, well under one
% tube-width), and that same zigzag with a spurious weak_signal-style
% corridor to a stray edge fragment ~150px away (0.3px error, stayed
% 67px clear of the corridor -- the T-junction guard held). Known,
% expected limitation: an artificially sharp near-180-degree cusp (well
% past any bend seen in real data, bordering on the self-touching
% fold-back case already excluded from scope) caused an early stop.

p = inputParser;
addParameter(p, 'k_ring', 1.3);
addParameter(p, 'k_cut', 1.7);
addParameter(p, 'thickness', 3);
addParameter(p, 'width_collapse', 0.5);
addParameter(p, 'max_steps', 500);
addParameter(p, 'prev_tip', []);
parse(p, varargin{:});
k_ring = p.Results.k_ring; k_cut = p.Results.k_cut;
thickness = p.Results.thickness; width_collapse = p.Results.width_collapse;
max_steps = p.Results.max_steps; prev_tip = p.Results.prev_tip;

[rows, cols] = size(U);
remaining = U;

r = anchor(1); c = anchor(2);

% Initial width: the anchor sits ON the mask's own border edge, where
% bwdist-to-background is tiny by construction (a boundary point, not a
% cross-section centre) -- take the local MAX of bwdist in a small window
% instead, which lands inside the tube's true middle. Verified needed:
% sampling bwdist directly at the anchor gives ~1px, which triggered an
% immediate false "width collapse" on the very first step.
D0 = bwdist(~U);
win0 = 15;
r0 = max(1, round(r)-win0); r1 = min(rows, round(r)+win0);
c0 = max(1, round(c)-win0); c1 = min(cols, round(c)+win0);
init_w = max(4, 2 * max(D0(r0:r1, c0:c1), [], 'all'));

% Recent-width history (median of up to the last 3 accepted widths) --
% used for ring sizing and the collapse threshold INSTEAD OF the raw
% immediately-previous reading. Needed because a ring crossing a curved
% boundary AT AN ANGLE (not perpendicular, i.e. right at a bend) produces
% an elongated, not-true-width intersection footprint -- a single such
% spike, trusted directly, oversizes the NEXT ring, which then undershoots
% into a genuinely narrower area and false-triggers the collapse check.
% Verified needed on HV198_1_32_cropped frame 1287: widths 16.28 -> 12.81
% -> 19.10 (spike, at a bend) -> next ring sized from 19.10 alone -> new
% width 9.22 vs threshold 9.55 -> false stop, 130px short of the real tip.
% A 3-step median absorbs one bad crossing angle without hiding a real,
% sustained taper (which stays low across multiple steps, not just one).
w_hist = init_w;

walk_path = [r c];
prev_dir = [];

for step = 1:max_steps
    ref_w = median(w_hist);
    ring_r = max(2, ref_w * k_ring / 2);
    cut_r  = max(ring_r + 1, ref_w * k_cut / 2);
    win = ceil(cut_r) + 3;
    r0 = max(1, round(r)-win); r1 = min(rows, round(r)+win);
    c0 = max(1, round(c)-win); c1 = min(cols, round(c)+win);
    [xx, yy] = meshgrid(c0:c1, r0:r1);
    dist = hypot(yy - r, xx - c);

    ring_mask = dist >= ring_r & dist < ring_r + thickness;
    hit = ring_mask & remaining(r0:r1, c0:c1);

    if ~any(hit(:))
        tip_final = walk_path(end,:);
        return;
    end

    lbl = bwlabel(hit, 8);

    % Discard degenerate components before any distance/direction scoring
    % -- a real ring crossing spans roughly `thickness` px along the ring's
    % circumference; a stray 1-2px noise speck is not a candidate at all,
    % just noise, and must not be left to compete on a razor-thin distance
    % margin against the real crossing. Verified needed: on a real frame
    % (HV203_1_11 F4) a 1px speck's cold-start "nearest" score beat a
    % genuine 68px crossing by a 0.03px margin -- pure noise, not a
    % meaningful tie -- which picked the speck, collapsed the width check
    % immediately, and stopped the walk after a single step.
    min_comp_px = max(3, thickness);
    keep = false(1, max(lbl(:)));
    for k = 1:max(lbl(:))
        if nnz(lbl == k) >= min_comp_px, keep(k) = true; end
    end
    lbl(~ismember(lbl, find(keep))) = 0;
    comp_ids = find(keep);
    ncomp = numel(comp_ids);

    if ncomp == 0
        tip_final = walk_path(end,:);
        return;
    end

    % Precompute each candidate's centroid and width up front -- selection
    % below needs both, not just distance/direction.
    cy_list = zeros(1, ncomp); cx_list = zeros(1, ncomp); w_list = zeros(1, ncomp);
    for ci = 1:ncomp
        k = comp_ids(ci);
        [ys, xs] = find(lbl == k);
        cy_list(ci) = mean(ys) + r0 - 1; cx_list(ci) = mean(xs) + c0 - 1;
        if numel(ys) > 1
            w_list(ci) = hypot(max(ys)-min(ys), max(xs)-min(xs));
        else
            w_list(ci) = 1;
        end
    end
    viable = w_list >= width_collapse * ref_w;

    if ncomp > 1
        % T-junction guard: keep the component continuing the walk
        % direction, not just nearest in distance -- every component sits
        % at ~ring_r from the centre by construction, so distance alone
        % can't tell a real forward path from a side branch (this is
        % exactly what a weak_signal-repaired corridor to a stray edge
        % fragment looks like to a ring -- see HV200_2_24_cropped frame
        % 414 session notes).
        %
        % Prefer candidates that don't immediately fail the width-collapse
        % check over ones that do, when there's a genuine choice -- two
        % substantial (non-noise) crossings both sitting at ~ring_r can
        % occur when the mask hooks back sharply right at the anchor
        % (verified on HV197_4_22 frame 1298: two real components, 19px
        % and 13px, picked between by a 0.16px cold-start distance margin
        % -- picked the one that immediately collapsed the walk instead of
        % the one that would have continued). Only fall back to
        % non-viable candidates if every candidate is non-viable (genuinely
        % stuck either way).
        candidate_idx = find(viable);
        if isempty(candidate_idx), candidate_idx = 1:ncomp; end

        is_direction_score = ~isempty(prev_dir);
        local_score = -Inf(1, numel(candidate_idx));
        for idx = 1:numel(candidate_idx)
            ci = candidate_idx(idx);
            if is_direction_score
                vec = [cy_list(ci) - r, cx_list(ci) - c];
                n = norm(vec);
                if n > 0, local_score(idx) = dot(vec, prev_dir) / n; end
            else
                local_score(idx) = -hypot(cy_list(ci) - r, cx_list(ci) - c); % nearest to anchor
            end
        end
        [sorted_score, sort_idx] = sort(local_score, 'descend');
        best_ci = candidate_idx(sort_idx(1));

        % Cross-frame continuity tiebreak: a persistent real fork can
        % recur every frame with near-identical local geometry, so the
        % LOCAL score alone (direction continuity, or nearest-to-anchor at
        % cold start) can be a genuine near-tie between two real branches
        % -- tiny per-frame noise then flips which one "wins", frame to
        % frame, forever (verified on HV200_3_23: mean step 17px, max
        % 193px vs skeleton's 4px/15px on the same stack, because
        % skeleton's own branch voting already uses tip_final_last and
        % ring_walk_tip previously had no cross-frame memory at all). When
        % the top two local scores are a near-tie AND the previous frame's
        % actual tip is known, prefer whichever candidate is closer to
        % that -- real, historical continuity beats a coin-flip-thin local
        % margin.
        if numel(candidate_idx) > 1 && ~isempty(prev_tip)
            margin = sorted_score(1) - sorted_score(2);
            if is_direction_score
                is_near_tie = margin < 0.15; % dot-product units, [-1,1]
            else
                is_near_tie = margin < 0.3 * ref_w; % px, scaled to local tube width
            end
            if is_near_tie
                dist_to_prev = Inf(1, numel(candidate_idx));
                for idx = 1:numel(candidate_idx)
                    ci = candidate_idx(idx);
                    dist_to_prev(idx) = hypot(cy_list(ci) - prev_tip(1), cx_list(ci) - prev_tip(2));
                end
                [~, pidx] = min(dist_to_prev);
                best_ci = candidate_idx(pidx);
            end
        end
    else
        best_ci = 1;
    end

    cy = cy_list(best_ci); cx = cx_list(best_ci); new_w = w_list(best_ci);

    if ~viable(best_ci)
        tip_final = walk_path(end,:);
        return;
    end

    cmask = dist < cut_r;
    sub = remaining(r0:r1, c0:c1);
    sub(cmask) = false;
    remaining(r0:r1, c0:c1) = sub;

    new_dir = [cy - r, cx - c];
    n = norm(new_dir);
    if n > 0, prev_dir = new_dir / n; end
    r = cy; c = cx;
    w_hist(end+1) = new_w; %#ok<AGROW>
    if numel(w_hist) > 3, w_hist = w_hist(end-2:end); end
    % Store a rounded copy for walk_path/tip_final -- callers index images
    % with this (e.g. U(tip_final(1)-rad:tip_final(1)+rad, ...)), which
    % requires integer subscripts; r/c themselves stay float so the ring
    % geometry above keeps sub-pixel precision between steps.
    walk_path(end+1,:) = round([r c]); %#ok<AGROW>
end

tip_final = walk_path(end,:);
end
