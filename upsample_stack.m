function out = upsample_stack(stack, factor)
% Per-frame bicubic upsampling of a grayscale image stack (rows x cols x
% frames). Used by the optional `upsample` config flag to test whether
% increasing spatial sampling density reduces segmentation/centerline bias
% on tubes that are only ~10px wide at native resolution -- a 1px error is
% a much bigger fraction of a 10px-wide object than of e.g. a 40px-wide one.
%
% Looped per frame rather than handing the whole 3-D stack to imresize in
% one call: imresize treats a trailing dimension of exactly 3 as an RGB
% image, which would silently misprocess a stack that happened to have
% exactly 3 frames.
if factor <= 1
    out = stack;
    return;
end
[h, w, n] = size(stack);
out = zeros(h * factor, w * factor, n, class(stack));
for k = 1:n
    out(:,:,k) = imresize(stack(:,:,k), factor, 'bicubic');
end
end
