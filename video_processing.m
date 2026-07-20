function L = video_processing(pathf,fname,stp,smp,timestep,L,Cmin,Cmin_tmp,Cmax,suffix)

if nargin < 10 || isempty(suffix), suffix = '_ratio'; end
movie = [pathf '/' fname suffix '.avi'];

% Uncompressed AVI, not MPEG-4: even at Quality=100, H.264's fixed 4:2:0
% chroma subsampling mangles a thin, saturated, high-contrast feature (the
% tube) against a mostly-black background at this small frame size --
% confirmed by decoding real MPEG-4 output frames: the tube broke up into
% scattered near-grayscale "ghost" pixels between real jet-colour pixels
% (chroma-subsampling/block artifacts), not leftover segmentation noise.
% Quality only controls DCT quantization, not chroma subsampling, so it
% reduced but never eliminated the effect. These clips are short/small
% enough that uncompressed size isn't a concern.
V = VideoWriter(movie, 'Uncompressed AVI');
V.FrameRate = 50;
open(V);

% Build colourmap: index 1 = black (background), 2-256 = jet
map = uint8(vertcat([0 0 0], jet(255)) .* 255);  % 256x3 uint8

% Colourbar strip: 10px wide, full height of frame, jet top-to-bottom
nrows = size(L,1);
cb_w  = 10;
cb_vals = uint8(linspace(255,0,nrows)');          % bright at top
cb_rgb  = reshape(map(cb_vals+1,:), nrows, 1, 3); % nrows x 1 x 3
cb_strip = repmat(cb_rgb, 1, cb_w, 1);            % nrows x cb_w x 3

for count = 1:size(L,3)
    % Apply gaussian blur then map to RGB via colourmap
    blurred = imgaussfilt(L(:,:,count), 1.5);
    blurred(L(:,:,count) == 0) = 0;              % restore zeroed background (prevent halo)
    idx     = blurred + 1;                        % shift: 0->idx1(black)
    rgb     = reshape(map(idx(:),:), nrows, size(L,2), 3);

    % Append colourbar
    frame_rgb = cat(2, rgb, cb_strip);

    % Burn timestamp text (simple pixel-level not needed — use insertText if
    % available, otherwise skip to avoid figure overhead). Time and Frame are
    % two SEPARATE insertText calls, not one concatenated string -- Time's
    % own digit count changes over the course of a run (e.g. "0.5" ->
    % "125.0"), which shifted a single combined string's "Frame: N" left/right
    % frame to frame. Frame is right-anchored (AnchorPoint 'RightTop') against
    % the IMAGE width specifically (size(rgb,2), before the colourbar strip
    % is appended below), so it stays pinned clear of the colourbar and its
    % own position never depends on Time's width.
    if exist('insertText','file')
        timestr = ['Time(s): ' num2str((count+stp-2)*timestep)];
        framestr = ['Frame: ' num2str(count+stp-1)];
        frame_rgb = insertText(frame_rgb,[5 5],timestr,'FontSize',12, ...
            'TextColor','white','BoxOpacity',0);
        frame_rgb = insertText(frame_rgb,[size(rgb,2)-5 5],framestr,'FontSize',12, ...
            'TextColor','white','BoxOpacity',0,'AnchorPoint','RightTop');
    end

    writeVideo(V, frame_rgb);
    disp(['Video Processing:' num2str((count+stp-1))]);
end

close(V);
disp(['Cmax:' num2str(Cmax)]);
disp(['Cmin:' num2str(Cmin*Cmax)]);
