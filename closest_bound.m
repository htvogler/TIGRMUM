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
% An optional spatial radius constraint excludes boundary points that are
% more than 'radius' pixels from the centerline position before the
% normal-line search, preventing the far arm of a looping tube from being
% picked.  If no point lies within radius the constraint is relaxed
% (original behaviour).

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
if nargin >= 6
    dist1 = sqrt((total(:,1) - yctf(startpos)).^2 + (total(:,2) - xctf(startpos)).^2);
    if any(dist1 <= radius)
        edge1(dist1 > radius) = Inf;
    end
end
[~, cstart] = min(abs(edge1));

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
if nargin >= 6
    dist2 = sqrt((total(:,1) - yctf(stoppos)).^2 + (total(:,2) - xctf(stoppos)).^2);
    if any(dist2 <= radius)
        edge2(dist2 > radius) = Inf;
    end
end
[~, cstop] = min(abs(edge2));
