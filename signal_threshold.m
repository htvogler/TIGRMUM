function mask = signal_threshold(frm, method)
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

switch method
    case 'otsu'
        mask = imbinarize(mat2gray(frm));
    case 'triangle'
        mask = double(frm) > triangle_threshold(frm);
        mask = imerode(mask, strel('disk', 1));
    otherwise
        error('signal_threshold: unknown threshold_method "%s" (use ''otsu'' or ''triangle'')', method);
end
end
