function level = triangle_threshold(I)
% Triangle/Zack thresholding: finds the histogram bin with the maximum
% perpendicular distance from the line connecting the peak (background)
% bin to the far tail-end bin. Suited to images with one dominant
% background peak and a weak, possibly long, signal tail -- unlike Otsu
% (maximises between-class variance), it does not get pulled off-target
% by a small, extremely bright outlier cluster (e.g. a saturated tip in
% a sensor with a large dynamic range).

nbins = 256;
vals = double(I(:));
[counts, edges] = histcounts(vals, nbins);
centers = (edges(1:end-1) + edges(2:end)) / 2;

[~, peak] = max(counts);
nz = find(counts > 0);
tail = nz(end);

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
