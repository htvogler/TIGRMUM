function level = triangle_threshold(I, tail_pct)
% Triangle/Zack thresholding: finds the histogram bin with the maximum
% perpendicular distance from the line connecting the peak (background)
% bin to the tail-end bin. Suited to images with one dominant background
% peak and a weak, possibly long, signal tail -- unlike Otsu (maximises
% between-class variance), it does not get pulled off-target by a small,
% extremely bright outlier cluster (e.g. a saturated tip in a sensor with
% a large dynamic range).
%
% tail_pct (default 0.99): the tail anchor is the bin where the cumulative
% histogram first reaches this fraction, not literally the single
% brightest pixel. With GCaMP, only 1-2 pixels ever populate the top bin,
% so anchoring there makes the threshold swing with whichever single hot
% pixel happens to be marginally brighter or dimmer that frame -- verified
% on HV197_4_19 frames 2042/2015 (nearly identical brightness stats, max
% differing by ~3%): the raw-max anchor gave thresholds 18% apart (1608 vs
% 1323), the 99th-percentile anchor converges them to ~3% apart (1113 vs
% 1083), matching how similar the frames actually are.

if nargin < 2
    tail_pct = 0.99;
end

nbins = 256;
vals = double(I(:));
[counts, edges] = histcounts(vals, nbins);
centers = (edges(1:end-1) + edges(2:end)) / 2;

[~, peak] = max(counts);
cumc = cumsum(counts);
tail = find(cumc >= tail_pct * cumc(end), 1);

if tail <= peak
    level = centers(peak);
    return;
end

x1 = peak; y1 = counts(peak);
x2 = tail; y2 = counts(tail);
seg = [x2 - x1, y2 - y1];
segnorm = hypot(seg(1), seg(2));

best_d = -1; best_i = peak;
for i = peak:tail
    d = abs(seg(1)*(y1 - counts(i)) - seg(2)*(x1 - i)) / segnorm;
    if d > best_d
        best_d = d;
        best_i = i;
    end
end
level = centers(best_i);
end
