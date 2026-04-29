function L = video_processing(pathf,fname,stp,smp,timestep,L,Cmin,Cmin_tmp,Cmax,suffix)

if nargin < 10 || isempty(suffix), suffix = '_ratio'; end
movie = [pathf '/' fname suffix '.avi'];

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
    idx     = blurred + 1;                        % shift: 0->idx1(black)
    rgb     = reshape(map(idx(:),:), nrows, size(L,2), 3);

    % Append colourbar
    frame_rgb = cat(2, rgb, cb_strip);

    % Burn timestamp text (simple pixel-level not needed — use insertText if
    % available, otherwise skip to avoid figure overhead)
    if exist('insertText','file')
        txtstr = ['Time(s): ' num2str((count+stp-1)*timestep)];
        frame_rgb = insertText(frame_rgb,[5 5],txtstr,'FontSize',12, ...
            'TextColor','white','BoxOpacity',0);
    end

    writeVideo(V, frame_rgb);
    disp(['Video Processing:' num2str((count+stp-1))]);
end

close(V);
disp(['Cmax:' num2str(Cmax)]);
disp(['Cmin:' num2str(Cmin*Cmax)]);
