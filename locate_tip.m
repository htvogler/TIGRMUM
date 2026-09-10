function [boundb, tip_final, tip_new, tip_check, diam, maxy, center, phin, axes, stats, edges] = locate_tip(H, tol, major, toln_cap, fallback_pt, max_jump_px)

% toln_cap: ceiling on how far the tolerance-growth loop below is allowed
% to search for a fittable point cloud, in px (default: unbounded, i.e.
% the previous behaviour -- the loop can grow all the way to the image
% diagonal). Pass e.g. 2*diamo so the ellipse fit stays anchored to the
% tip's own local cross-section instead of silently sliding into a
% whole-mask-scale search.
%
% fallback_pt: point returned (instead of `major`, the raw seed) if even
% toln_cap isn't enough to get a valid fit. Pass e.g. tip_final_last (the
% previous frame's tip) when available -- more trustworthy than the seed
% itself in exactly the cases that trigger this fallback (the seed sits on
% an ambiguous/flattened local region, which is why the fit kept failing).
%
% Both optional, defaulting to the original behaviour, so existing callers
% (tip_track_ratio.m) are unaffected.
if nargin < 4 || isempty(toln_cap), toln_cap = norm(size(H)); end
if nargin < 5 || isempty(fallback_pt), fallback_pt = major(1,:); end
if nargin < 6 || isempty(max_jump_px), max_jump_px = Inf; end
% max_jump_px: passed straight through to ellipse_data.m -- see its own doc.

% Extract image boundary (longest boundary)
I = bwboundaries(H,'holes');
for x = 1:numel(I)
    tempbw(x) = size(I{x},1);
end
[tmp posI] = max(tempbw);
bound = I{posI};

stats = regionprops(H,'Orientation','MajorAxisLength', 'BoundingBox', ...
    'MinorAxisLength', 'Eccentricity', 'Centroid','Area','FilledImage');

% Fit an ellipse to the entire image and get the maximum point
%major = [stats.Centroid(2) + stats.MajorAxisLength*0.5 * sin(pi*stats.Orientation/180) ...
%    stats.Centroid(1) - stats.MajorAxisLength*0.5 * cos(pi*stats.Orientation/180)];

% Remove points on the extreme right
maxy = size(H,2);
rem = find(bound(:,2) == maxy); bound(rem,:) = [];

% Find points on the convex hull
hullo = convhull(bound(:,1),bound(:,2));
ver = [bound(hullo,1) bound(hullo,2)];

% Find the diameter, midpoint at the cutoff along with the positions along
% the entire boundary
yedge = find(ver(:,2) == maxy-1);
if isempty(yedge)
    [~, ri] = max(ver(:,2));
    yedge = find(ver(:,2) == ver(ri,2));
end
[diam start edges] = edge_quant(ver,yedge);

% Tip finding algorithm
ybound = find(bound(:,2) == maxy-1);
if isempty(ybound)
    [~, ybound] = max(bound(:,2));
end
boundc = circshift(bound,-ybound(1));

toln = tol*1.25; tip_final = [0 0];
toln_max = toln_cap;
while (nnz(tip_final) == 0)
    tip_new = [];
    for i = 1:length(bound)
        dist_val = pdist2(boundc(i,:),major(1,:));
        if (dist_val < toln) tip_new = [tip_new; boundc(i,:)]; end
    end
    [tip_final,center,phin,axes,tip_check] = ellipse_data(tip_new, fallback_pt, max_jump_px);
    if toln > toln_max
        tip_final = fallback_pt;
        break;
    end
    toln = toln + 5;
end

% Shift the entire boundary vector center at final tip
posxf = []; posyf = []; boundb = [];
posxf = find(boundc(:,1) == tip_final(1));
posyf = find(boundc(:,2) == tip_final(2));
interf = intersect(posxf,posyf);
if isempty(interf)
    [~, interf] = min(pdist2(boundc, tip_final));
    tip_final = boundc(interf,:);
end

boundb = circshift(boundc,(-ceil(length(boundc)*0.5)-interf(1)));
