function [cstart,cstop] = closest_bound(total,xctf,yctf,startpos,stoppos,radius)

% Find the boundary points corresponding to the centerline at startpos
% and stoppos using a normal-line (perpendicular projection) approach.
%
% The normal at each position is computed from the LOCAL centerline
% direction (neighbouring indices in xctf/yctf), not the global vector
% between startpos and stoppos.  This is essential for S-shaped or looping
% tubes where the two positions can be geometrically close even though they
% are far apart along the arc.
%
% Two-stage search (same principle as the diameter cross-section fix in
% main_track_movies.m's nearest_crossing_to_sample -- see that function's
% own comment for the full geometric writeup): a plain "smallest
% perpendicular distance to the line" search has no idea how far a
% candidate actually is from the query position, and a bent (non-convex)
% boundary can cross a single line more than once. Restricting to `radius`
% alone isn't enough either -- two genuine near-zero crossings can both
% fall inside the same radius right at a sharp bend. Confirmed on real
% data (HV207_24_left frame 1134): this produced a 24px jump in the
% resulting ROI polygon (a full tube-diameter's worth of discontinuity),
% because the old code took whichever of two real candidates had the
% marginally smaller residual, not whichever was actually close to the
% query point. Fix: restrict to `radius` first (as before), then within
% that restricted set further restrict to genuine LOCAL MINIMA of the
% residual (points where the line actually crosses/nearly crosses the
% boundary), and only then pick whichever of those is physically nearest
% to the query point.

% --- local direction at startpos ---
n = length(xctf);
if startpos < n
    dx1 = xctf(startpos+1) - xctf(startpos);
    dy1 = yctf(startpos+1) - yctf(startpos);
else
    dx1 = xctf(startpos) - xctf(startpos-1);
    dy1 = yctf(startpos) - yctf(startpos-1);
end
if dx1 == 0, dx1 = 0.01; end
if dy1 == 0, dy1 = 0.01; end

nfitc1 = fit(vertcat(xctf(startpos),(xctf(startpos) - dy1)), ...
             vertcat(yctf(startpos),(yctf(startpos) + dx1)), 'poly1');
edge1 = total(:,1) - nfitc1.p1.*total(:,2) - nfitc1.p2;
dist1 = sqrt((total(:,1) - yctf(startpos)).^2 + (total(:,2) - xctf(startpos)).^2);
if nargin < 6, radius = Inf; end
cstart = nearest_crossing_local(edge1, dist1, radius);

% --- local direction at stoppos ---
if stoppos < n
    dx2 = xctf(stoppos+1) - xctf(stoppos);
    dy2 = yctf(stoppos+1) - yctf(stoppos);
elseif stoppos > 1
    dx2 = xctf(stoppos) - xctf(stoppos-1);
    dy2 = yctf(stoppos) - yctf(stoppos-1);
else
    dx2 = dx1; dy2 = dy1;
end
if dx2 == 0, dx2 = 0.01; end
if dy2 == 0, dy2 = 0.01; end

nfitc2 = fit(vertcat(xctf(stoppos),(xctf(stoppos) - dy2)), ...
             vertcat(yctf(stoppos),(yctf(stoppos) + dx2)), 'poly1');
edge2 = total(:,1) - nfitc2.p1.*total(:,2) - nfitc2.p2;
dist2 = sqrt((total(:,1) - yctf(stoppos)).^2 + (total(:,2) - xctf(stoppos)).^2);
cstop = nearest_crossing_local(edge2, dist2, radius);

end

function idx = nearest_crossing_local(edge, dist, radius)
% Restrict to `radius` (if any point is within it -- relax to unrestricted
% otherwise, matching the original behaviour), then to genuine local
% minima of |edge| within that restricted set, then pick whichever is
% closest (by `dist`) to the query point. See closest_bound's own header
% comment for why each stage is needed.
edge_c = edge;
within = dist <= radius;
if any(within)
    edge_c(~within) = Inf;
end
a = abs(edge_c);
n = numel(a);
is_min = false(n,1);
if n == 1
    is_min(1) = true;
else
    is_min(2:end-1) = a(2:end-1) <= a(1:end-2) & a(2:end-1) <= a(3:end);
    is_min(1) = a(1) <= a(2);
    is_min(end) = a(end) <= a(end-1);
end
is_min = is_min & isfinite(a);
cand = find(is_min);
if isempty(cand)
    [~, idx] = min(a); % degenerate fallback: nothing within radius at all
    return;
end
[~, rel] = min(dist(cand));
idx = cand(rel);
end
