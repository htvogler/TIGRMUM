function merged = bridge_to_mask(base, frag, radius)
% Connect frag to base with a corridor between their nearest points,
% instead of a plain union -- a straight union doesn't guarantee the two
% end up in the same connected component, which leaves downstream
% skeleton/branch-point code (built assuming a single connected tube)
% looking at two separate blobs instead (verified on HV198_1_16 frame 3254:
% a 3854px real fragment unioned in directly, without this, pushed the
% skeleton's endpoint count from 11 to 25 and crashed branch_removal's
% assumptions on several nearby frames).
%
% radius: corridor half-width. Pass the tube's own local width -- diamo/2
% once available, or Area/MajorAxisLength/2 as an estimate before that
% (NOT regionprops MinorAxisLength/2: MinorAxisLength comes from an ellipse
% fit to the whole region's second moments, which badly overestimates local
% width for anything bent/curved rather than straight -- verified on
% HV198_1_16 frame 3267, where MinorAxisLength gave 66-82px against a real
% ~16px diameter and produced a multi-hundred-px "balloon"). A corridor
% much thinner than the real tube creates a "dumbbell" pinch that visibly
% looks wrong (still-separate-looking "connections only 2-3px wide") and
% confuses the tip-detection/branch-removal logic downstream even when the
% two pieces are technically one connected component (verified on
% HV198_1_16 frame 3224: a thin corridor left the traced centerline
% stopping at the pinch and the tip getting placed at that junction instead
% of the real, further-out tip).
if ~isequal(size(base), size(frag))
    error('bridge_to_mask: base %s and frag %s are different sizes going in', ...
        mat2str(size(base)), mat2str(size(frag)));
end
[D, IDX] = bwdist(base);
frag_idx = find(frag);
[~, rel] = min(D(frag_idx));
[rf, cf] = ind2sub(size(base), frag_idx(rel));
[rb, cb] = ind2sub(size(base), IDX(rf, cf));
corridor = false(size(base));
corridor = drawline(corridor, rb, cb, rf, cf, true);
if ~isequal(size(corridor), size(base))
    error(['bridge_to_mask: drawline grew corridor to %s (base %s) -- ' ...
        'endpoints (rb,cb)=(%d,%d) (rf,cf)=(%d,%d), radius=%g'], ...
        mat2str(size(corridor)), mat2str(size(base)), rb, cb, rf, cf, radius);
end
corridor = imdilate(corridor, strel('disk', max(1, round(radius))));
merged = base | frag | corridor;
end
