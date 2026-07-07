function merged = bridge_to_mask(base, frag, up_factor)
% Connect frag to base with a minimal fixed-width corridor between their
% nearest points, instead of a plain union -- a straight union doesn't
% guarantee the two end up in the same connected component, which leaves
% downstream skeleton/branch-point code (built assuming a single connected
% tube) looking at two separate blobs instead (verified on HV198_1_16
% frame 3254: a 3854px real fragment unioned in directly, without this,
% pushed the skeleton's endpoint count from 11 to 25 and crashed
% branch_removal's assumptions on several nearby frames).
[D, IDX] = bwdist(base);
frag_idx = find(frag);
[~, rel] = min(D(frag_idx));
[rf, cf] = ind2sub(size(base), frag_idx(rel));
[rb, cb] = ind2sub(size(base), IDX(rf, cf));
corridor = false(size(base));
corridor = drawline(corridor, rb, cb, rf, cf, true);
corridor = imdilate(corridor, strel('disk', up_factor));
merged = base | frag | corridor;
end
