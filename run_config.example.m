% run_config.m — per-run analysis parameters.
% Copy this file to run_config.m (gitignored) and edit freely — that file
% will never show up in `git status`, so per-dataset/per-run changes stay
% local. main_track_movies.m loads it via run('run_config.m').

% Path to Mat file
path = '/Users/htv/Downloads/20260417/movies/tiff/FRET-IBRA_results/HV197_1_17'; % Input folder path (ADD PATH TO FILE HERE)
fname = 'HV197_1_17'; % Filename
stp = 1; % Start frame number
smp = 2010; % End frame number

% Options for analysis
tip_plot = 0; % Video tip detection, has no effect if video_intensity = 2
video_intensity = 1; % Intensity video: 0 = off, 1 = on + analysis, 2 = video only
frame_rate = 0.150; % Number of seconds per frame of input video
distributions = 0;  % Show histogram of results in the end
workspace = 0; % Save workspace

% Tip detection parameters
weight = 0.5; % Distance to eliminate branches (Higher means more reliance on the tip ellipse), 0 follows only the thinned edge.

% ROI options
ROItype = 1; % No ROI = 0; Moving ROI = 1; Stationary ROI = 2
split = 1; % Split ROI along center line
circle = 0; % Circle ROI as fraction of diameter
starti = 0; % Rectangle ROI Start length / no pixelsize means percentage as a fraction of length of tube
stopi = 10; % Rectangle/Circle ROI Stop length / no pixelsize means percentage as a fraction of length of tube
pixelsize = 0.645; % Pixel to um conversion

% Kymo, movie and measurements options
Cmin = 1.5; % Min pixel value in Ratio stack
Cmax = 3; % Max pixel value in Ratio stack
nkymo = 3; % Number of pixels line width average for kymograph (odd number) (0 means no kymo)
diamcutoff = 0; % In pixels if pixelsize is not given
bit_depth = 12; % Camera bit depth (12 or 16) — must match FRET-IBRA config
bg_thresh_frac = 0.018;  % Background zeroing threshold as fraction of full 16-bit range (always
                        % applied after rescaling, so camera-independent: 0.02 = ~1311 cts;
                        % lower for weak-signal stacks, e.g. 0.008 = ~524 cts)
