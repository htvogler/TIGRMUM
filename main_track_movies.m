clear all
close all

% Path to Mat file
path = '/Users/htv/Downloads/Claude_test/FRET-IBRA_results/HV202_1_7'; % Input folder path (ADD PATH TO FILE HERE)
fname = 'HV202_1_7'; % Filename 
stp = 1; % Start frame number
smp = 2402; % End frame number

% Options for analysis
tip_plot = 1; % Video tip detection
video_intensity = 1; % Video intensity
frame_rate = 0.3; % Number of seconds per frame of input video
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
pixelsize = 0.3225; % Pixel to um conversion

% Kymo, movie and measurements options
Cmin = 1.5; % Min pixel value in Ratio stack
Cmax = 3; % Max pixel value in Ratio stack
nkymo = 3; % Number of pixels line width average for kymograph (odd number) (0 means no kymo)
diamcutoff = 0; % In pixels if pixelsize is not given

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Detect input file and select analysis mode
pathf = path;
ratio_file = [pathf '/' fname '_ratio_back.h5'];
back_file  = [pathf '/' fname '_back.h5'];

% Build output path: {root}/TIGRMUM_results/{fname}/
% Assumes input is at {root}/FRET-IBRA_results/{fname}/
[fribra_dir, ~, ~] = fileparts(pathf);
[root_dir,   ~, ~] = fileparts(fribra_dir);
outpath = fullfile(root_dir, 'TIGRMUM_results', fname);
if ~exist(outpath, 'dir'), mkdir(outpath); end
figpath = fullfile(outpath, 'Figures');
if ~exist(figpath, 'dir'), mkdir(figpath); end

if exist(ratio_file, 'file')
    mode = 'ratio';
    M   = h5read(ratio_file, '/ratio_raw');
    BT1 = h5read(ratio_file, '/acceptor');
    BT2 = h5read(ratio_file, '/donor');
    disp('NOTE: Running analysis on ratio stack from _ratio_back.h5.');
    disp('      Ratio scaling for display and kymograph uses Cmin/Cmax as set in this script.');
    disp('      For custom registration, masking, or union parameters, run main_ratio_movies.m');
    disp('      first, then re-run main_track_movies.m.');
elseif exist(back_file, 'file')
    dnames = {h5info(back_file).Datasets.Name};
    if any(strcmp(dnames, 'donor'))
        mode = 'two_raw';
        BT1 = h5read(back_file, '/acceptor');
        BT2 = h5read(back_file, '/donor');
        disp('NOTE: Two-channel data found in _back.h5 but no ratio stack (_ratio_back.h5) available.');
        disp('      Tip tracking and diameter analysis will use the acceptor channel only.');
        disp('      For ratio analysis, run FRET-IBRA module 2 first, then re-run main_track_movies.m.');
    else
        mode = 'single';
        BT1 = h5read(back_file, '/acceptor');
        BT2 = [];
    end
    M = BT1;
    try
        bc = h5readatt(back_file, '/', 'bleach_corrected');
        if iscell(bc), bc = bc{1}; end
        if ischar(bc), bc = strcmpi(bc, 'true'); end
        bc = logical(bc);
    catch
        bc = false;
    end
    if ~bc
        warning('TIGRMUM: bleach_corrected attribute missing or false in %s. Run FRET-IBRA Module 4 first.', back_file);
    end
else
    error('No suitable HDF5 input file found for %s', fname);
end

% Zero background for non-ratio modes using per-frame Otsu thresholding
% (for ratio mode this was already done in main_ratio_movies / FRET-IBRA)
if ~strcmp(mode, 'ratio')
    for fc = 1:size(BT1,3)
        frm = BT1(:,:,fc);
        BT1(:,:,fc) = frm .* cast(imbinarize(mat2gray(frm)), class(BT1));
    end
    if ~isempty(BT2)
        for fc = 1:size(BT2,3)
            frm = BT2(:,:,fc);
            BT2(:,:,fc) = frm .* cast(imbinarize(mat2gray(frm)), class(BT2));
        end
    end
    M = BT1;
end

% Orient image
type = find_orient(M(:,:,1));
        
% Scaled plot of the growing tube with tip and ROI
if (tip_plot == 1)
    V = VideoWriter([outpath '/' fname '_growth.avi'], 'Uncompressed AVI');
    V.FrameRate = 100;
    open(V);
end

if (nkymo > 0 || video_intensity > 0)
    if strcmp(mode, 'ratio')
        K = M(:,:,:)./Cmax;
        K(isnan(K)) = 0;
        Cmin_tmp = Cmin;
        Cmin = Cmin/Cmax;
        L = bsxfun(@rdivide, bsxfun(@minus, K, Cmin), bsxfun(@minus, 1, Cmin));
        L(L<0) = 0;
        L = uint8(L.*255);
    else
        Mmax = double(max(M(:)));
        L = uint8(double(M)./Mmax.*255);
        Cmin_tmp = 0; Cmin = 0; Cmax = Mmax;
    end
end

% Make a movie and output min and max intensities of the whole stack
if (video_intensity) && ~strcmp(mode, 'two_raw')
    if strcmp(mode, 'single')
        video_processing(outpath,fname,stp,smp,frame_rate,L(:,:,stp:smp),Cmin,Cmin_tmp,Cmax,'_intensity');
    else
        video_processing(outpath,fname,stp,smp,frame_rate,L(:,:,stp:smp),Cmin,Cmin_tmp,Cmax);
    end
end

% Loop backwards over stack
if (distributions), d = 1; end
for count = smp:-1:stp
    disp(['Image Analysis:' num2str(count)]);
    O = M(:,:,count);
    
    if (type == 1) O = imrotate(O,-90); 
    elseif (type == 3) O = imrotate(O,90); 
    elseif (type == 4) O = imrotate(O,180);
    end
    
    if strcmp(mode, 'ratio')
        P = imbinarize(O, 0.2);
    else
        P = imbinarize(O);
    end
    se = strel('disk',10);
    se2 = strel('disk',1);
    U = imopen(P,se);
    U = bwareaopen(U,100);
    U = bwareafilt(P,1);
    U = bwmorph(U,'clean');
    U = medfilt2(U);
    U = imclose(U,se);
    
    if (count == smp) Ub = logical(ones(size(P)));
    else Ub = U;
    end
        
    Urat = and(U,Ub);
    Ucount(count) = nnz(Urat)/nnz(U);
    if (Ucount(count) < 0.95 || count == smp) last_flag = 0;
    else last_flag = 1;
    end
    
    Umax = max(find(U(:,end)==1)); Umin = min(find(U(:,end)==1));
    U = imfill(drawline(U,Umin,size(U,2),Umax,size(U,2),1),'holes');

    % ---- DIAGNOSTIC BLOCK 1: binarisation pipeline (frame smp only) ----
    if count == smp
        dp = fullfile(outpath, sprintf('diag_%d', count));
        imwrite(mat2gray(double(O)),            [dp '_01_O_raw.png']);
        imwrite(mat2gray(double(L(:,:,count))), [dp '_02_L_display.png']);
        imwrite(P,                              [dp '_03_P_otsu.png']);
        Ud1 = imopen(P, se);
        imwrite(Ud1,                            [dp '_04_U_imopen.png']);
        Ud2 = bwareaopen(Ud1, 100);
        imwrite(Ud2,                            [dp '_05_U_bwareaopen.png']);
        Ud3 = bwareafilt(P, 1);
        imwrite(Ud3,                            [dp '_06_U_bwareafilt_P.png']);
        Ud4 = bwmorph(Ud3, 'clean');
        imwrite(Ud4,                            [dp '_07_U_clean.png']);
        Ud5 = medfilt2(Ud4);
        imwrite(Ud5,                            [dp '_08_U_medfilt.png']);
        Ud6 = imclose(Ud5, se);
        imwrite(Ud6,                            [dp '_09_U_imclose.png']);
        imwrite(U,                              [dp '_10_U_final.png']);
        disp(['DIAG block 1 saved to ' dp]);
    end
    % ---- END DIAGNOSTIC BLOCK 1 ----

    % Removing branches from thinned image
    Q = bwmorph(U,'thin',Inf);    
    
    Qe = bwmorph(Q,'endpoints');
    [Qer,Qec] = find(Qe > 0);
    Qel = [Qer Qec];
        
    Qb = bwmorph(Q,'branchpoints');       
    [Qbr,Qbc] = find(Qb > 0);
    if (Qbr > 0)
        Qbf = [Qbr Qbc];
        [Q2, Qef, tmp] = branch_removal(Q,Qbf,Qel,0,1);
    else 
        Q2 = Q;
        [tmp,Qepos] = max(Qec);
        Qef = Qel;
        Qef(Qepos,:) = [];
    end
   
    % Finding the radius for ellipse fitting
    tols = 0; rad=1;
    while (tols == 0)
        sides = false; connect = false;
        try
            K = U(Qef(1)-rad:Qef(1)+rad,Qef(2)-rad:Qef(2)+rad);
        catch
            rad = 100;
            tols = 40;
            break;
        end
        Ke = [K(:,1)' K(end,2:end) K(end-1:-1:1,end)' K(1,end-1:-1:2)];
        Kd = diff(Ke);
        Kd(end+1) = Ke(1) - Ke(end);
        if (nnz(Kd) == 2) connect = true; end
        Ks = [sum(K(:,1)) sum(K(1,:)) sum(K(:,end)) sum(K(end,:))];
        if (nnz(Ks) <= 2)
            bou = bwboundaries(K); Kb = bou{1};
            Kbl = [find(Kb(:,1) == 1); find(Kb(:,2) == 1); find(Kb(:,1) == size(K,1)); find(Kb(:,2) == size(K,1))];
            if (size(Kbl,1) < size(K,1)) sides = true; end
        end
        if(connect == true && sides == true) tols = rad; end
        rad = rad + 1;
    end

    [boundb, tip_ellipse, tip_new, tip_check, diam, maxy, center, phin, axes, stats, edges] = locate_tip(U, tols, Qef);
    tip_ellipsepos = dsearchn(boundb,tip_ellipse);
    tip_ellipsef = boundb(tip_ellipsepos,:);
   
    % Skeletonizing and finding endpoints
    S = bwmorph(U,'skel',Inf);
    Se = bwmorph(S,'endpoints');
    [Ser,Sec] = find(Se > 0);
    Sel = [Ser Sec];
    
    % Skeltonizing and finding branchpoints
    Sb = bwmorph(S,'branchpoints');
    [Sbr,Sbc] = find(Sb > 0);
    Sbl = [Sbr Sbc];
    
    % Find branch point closest to thin edge
    if (last_flag == 0) Sbf = Sbl(dsearchn(Sbl,Qef),:);
    else [tmp, Sbmin] = min(pdist2(Sbl,tip_final_last) + pdist2(Sbl,Qef));
        Sbf = Sbl(Sbmin,:);
    end
    
    % Try and remove branches within some parameters
    close_dist = 0; 
    if (count == smp) diamo = diam; end
    if (pdist2(Qef,Sbf) > weight*diamo) close_dist = 1; end
    if (weight == 0) kill_angle = 0;
    else kill_angle = 75;
    end
    [S2,Sef,S2area] = branch_removal(S,Sbf,Sel,kill_angle,close_dist);
        
    % If more than 2 branches, further evaluation is needed
    if (size(Sef,1) > 1)
        % Voting to decide which branch to be chosen as closer to the tip
        [tmp, skel_ellipsepos] = min(pdist2(Sef,tip_ellipsef));
        if (last_flag == 1)
            [tmp, skel_lastpos] = min(pdist2(Sef,tip_final_last));
            if ((skel_lastpos+skel_ellipsepos+1) > 4) choice = 2; else choice = 1; end
        else 
            choice = skel_ellipsepos;       
        end
    
        tip_choice = [dsearchn(boundb,Sef(1,:));dsearchn(boundb,Sef(2,:))];
        if (min(tip_choice) == tip_choice(2)) S2area = 1/S2area; end
        tip_skelpos = tip_choice(choice);
        tip_skel = boundb(tip_skelpos,:);
   
        % Finding the middle of both branches if they exist
        cn = 0; tip_angle = [];
        for i = min(tip_choice):max(tip_choice)
            cn = cn+1;
            tip_angle(cn) = atan2((boundb(i,2) - Sbf(2)),(boundb(i,1) - Sbf(1)));
            if (pi - abs(max(tip_angle)) < abs(min(tip_angle)))
                if (tip_angle(cn) < 0) tip_angle(cn) = 2*pi + tip_angle(cn); end
            end
        end
        target_angle = (tip_angle(1) + tip_angle(end)*S2area)/(S2area+1);

        tip_anglediff = abs(tip_angle - target_angle);
        [tmp, tip_anglepos] = min(tip_anglediff);
        tip_midpos = tip_anglepos+min(tip_choice)-1;
        tip_mid = boundb(tip_midpos,:);
        
        test = [];
        if (tip_ellipsepos>min(tip_choice) && tip_ellipsepos<max(tip_choice))
            tip_final(count,:) = tip_ellipsef;
        else
            tip_ellipsedist = [pdist2(tip_ellipsef,tip_mid) pdist2(tip_ellipsef,tip_skel)];
            if (last_flag)            
                tip_finaldist = [pdist2(tip_final_last,tip_mid) pdist2(tip_final_last,tip_skel)];             
                [tmp, tip_finalpos] = min([(1-0.33)*tip_finaldist(1)+0.33*tip_ellipsedist(1) (1-0.33)*tip_finaldist(2)+0.33*tip_ellipsedist(2)]);
            else
                [tmp, tip_finalpos] = min(tip_ellipsedist);
            end
            if (tip_finalpos == 1) tip_final(count,:) = tip_mid; else tip_final(count,:) = tip_skel; end
            test = [test count];
        end
    else
        tip_skel = boundb(dsearchn(boundb,Sef(1,:)),:);
        if (last_flag) [tmp, tip_finaldistpos] = min([pdist2(tip_final_last,tip_ellipsef) pdist2(tip_final_last,tip_skel)]);   
        else tip_finaldistpos = 2;
        end
        if (tip_finaldistpos == 1) tip_final(count,:) = tip_ellipsef; else tip_final(count,:) = tip_skel; end
    end
        
    % Update tip_final for the next frame
    tip_final_last(:,:) = tip_final(count,:);
    
    % Find the curves along the sides of the tubes
    total1 = []; total2 = [];
    range1 = ceil(length(boundb)*0.5):length(boundb);
    dist1 = pdist2(boundb(range1,:),tip_final(count,:));
    postotal1 = find(dist1 > diamo*0.75)+range1(1)-1;
    if (~isempty(find(diff(postotal1(1:floor(length(postotal1)/2))>1))))
        postotal1(1:find(diff(postotal1(1:floor(length(postotal1)/2))>1))) = [];
    end
    total1(:,:) = boundb(postotal1,:);
    
    range2 = ceil(length(boundb)*0.5)-1:-1:1;
    dist2 = pdist2(boundb(range2,:),tip_final(count,:));
    postotal2 = range2(1)-find(dist2 > diamo*0.75)+1;
    if (~isempty(find(diff(postotal2(1:floor(length(postotal2)/2))>1))))
        postotal2(1:find(diff(postotal2(1:floor(length(postotal2)/2))>1))) = [];
    end
    total2(:,:) = boundb(postotal2,:);
    
    % Ensure that both curves reach maxy
    if isempty(total1) || isempty(total2)
        dist_all = pdist2(boundb, tip_final(count,:));
        postotal_all = find(dist_all > diamo*0.75);
        half = ceil(length(postotal_all)*0.5);
        total1 = boundb(postotal_all(1:half),:);
        total2 = boundb(postotal_all(half+1:end),:);
    end
    if ~isempty(total1) && ~isempty(total2)
        if (max(total1(:,2)) < (maxy-1))
            while(max(total1(:,2)) < (maxy-1) && ~isempty(total2))
                total1 = vertcat(total1,total2(end,:));
                total2(end,:) = [];
            end
        elseif (max(total2(:,2)) < (maxy-1))
            while(max(total2(:,2)) < (maxy-1) && ~isempty(total1))
                total2 = vertcat(total2, total1(end,:));
                total1(end,:) = [];
            end
        end
    end
    if isempty(total1) || isempty(total2)
        dist_all = pdist2(boundb, tip_final(count,:));
        postotal_all = find(dist_all > diamo*0.75);
        if ~isempty(postotal_all)
            half = ceil(length(postotal_all)*0.5);
            total1 = boundb(postotal_all(1:half),:);
            total2 = boundb(postotal_all(half+1:end),:);
        end
    end

    if ~isempty(total1) && ~isempty(total2) && (abs(total1(end,1) - total2(end,1)) < 0.75*diam)
        total1(find(total1(:,2) >= max(total1(:,2))),:) = [];
        total2(find(total2(:,2) >= max(total2(:,2))),:) = [];
    end

    % ---- DIAGNOSTIC BLOCK 2: skeleton + geometry (frame smp only) ----
    if count == smp
        dp  = fullfile(outpath, sprintf('diag_%d', count));
        sz1 = size(U,1); sz2 = size(U,2);

        imwrite(imdilate(Q,  strel('disk',1)), [dp '_11_Q_thin.png']);
        imwrite(imdilate(Q2, strel('disk',1)), [dp '_12_Q2_debranched.png']);

        Rch = uint8(U)*80; Gch = uint8(U)*80; Bch = uint8(U)*80;
        Qd  = imdilate(Q,  strel('disk',1)); Rch = Rch + uint8(Qd)*170;
        Q2d = imdilate(Q2, strel('disk',1)); Gch = Gch + uint8(Q2d)*170;
        if ~isempty(Qef)
            re = max(1,Qef(1,1)-4):min(sz1,Qef(1,1)+4);
            ce = max(1,Qef(1,2)-4):min(sz2,Qef(1,2)+4);
            Bch(re,ce) = 255;
        end
        imwrite(cat(3,Rch,Gch,Bch), [dp '_13_skeleton_overlay.png']);

        Rch = uint8(U)*60; Gch = uint8(U)*60; Bch = uint8(U)*60;
        brows = max(1,min(sz1,boundb(:,1))); bcols = max(1,min(sz2,boundb(:,2)));
        for pi=1:size(boundb,1), Rch(brows(pi),bcols(pi))=255; Gch(brows(pi),bcols(pi))=255; end
        if ~isempty(total1)
            tr=max(1,min(sz1,total1(:,1))); tc=max(1,min(sz2,total1(:,2)));
            for pi=1:size(total1,1), Gch(tr(pi),tc(pi))=255; end
        end
        if ~isempty(total2)
            tr=max(1,min(sz1,total2(:,1))); tc=max(1,min(sz2,total2(:,2)));
            for pi=1:size(total2,1), Bch(tr(pi),tc(pi))=255; end
        end
        re=max(1,tip_final(count,1)-3):min(sz1,tip_final(count,1)+3);
        ce=max(1,tip_final(count,2)-3):min(sz2,tip_final(count,2)+3);
        Rch(re,ce)=255; Gch(re,ce)=0; Bch(re,ce)=0;
        imwrite(cat(3,Rch,Gch,Bch), [dp '_14_geometry_overlay.png']);
        disp(['DIAG block 2 saved to ' dp]);
    end
    % ---- END DIAGNOSTIC BLOCK 2 ----

    % Centerline: minimum-cost path through tube, weighted by distance from
    % wall — paths near the tube centre are cheap, so the optimal path
    % naturally follows the medial axis regardless of bends or branches.
    right_col = size(U,2) - 1;
    right_pix = find(U(:, right_col));
    if isempty(right_pix)
        right_col = right_col - 1;
        right_pix = find(U(:, right_col));
    end
    % If mean of right_pix falls in a gap, snap to nearest actual U pixel
    ra_row = round(mean(right_pix));
    if ~U(ra_row, right_col)
        [~, snap] = min(abs(right_pix - ra_row));
        ra_row = right_pix(snap);
    end
    right_anchor = [ra_row, right_col];

    % Weight: inversely proportional to distance from tube boundary
    D_tube = bwdist(~U);
    W_tube = Inf(size(U));
    W_tube(U) = 1 ./ (D_tube(U) + 1);

    % Geodesic cost from right_anchor (low cost = centre of tube)
    GD = graydist(W_tube, right_anchor(2), right_anchor(1));
    GD(~U) = Inf;

    % Nearest U pixel to tip_final as trace start
    [Ur_all, Uc_all] = find(U);
    [~, tpos] = min(pdist2([Ur_all Uc_all], tip_final(count,:)));
    r = Ur_all(tpos); c = Uc_all(tpos);

    % Safety: if GD at start is Inf the tube is disconnected — fall back to Q endpoint
    if ~isfinite(GD(r,c))
        [~, epos] = max(Qec);
        r = Qel(epos,1); c = Qel(epos,2);
    end

    % Gradient descent from tip to right_anchor; visited mask prevents loops
    max_path = 3*nnz(U);
    path = zeros(max_path, 2);
    path(1,:) = [r c];
    n_path = 1;
    visited = false(size(U));
    visited(r,c) = true;
    for step = 1:max_path-1
        if GD(r,c) == 0, break; end
        r0 = max(1,r-1); r1 = min(size(U,1),r+1);
        c0 = max(1,c-1); c1 = min(size(U,2),c+1);
        nbhd = GD(r0:r1, c0:c1);
        nbhd(visited(r0:r1, c0:c1)) = Inf;
        [min_val, idx] = min(nbhd(:));
        if min_val >= GD(r,c), break; end
        [dr, dc] = ind2sub(size(nbhd), idx);
        r = r0+dr-1; c = c0+dc-1;
        n_path = n_path + 1;
        path(n_path,:) = [r c];
        visited(r,c) = true;
    end
    path = path(1:n_path,:);
    yctk = path(:,1); xctk = path(:,2);

    % Cumulative arc length along path (0 at tip, max at base)
    path_dist = [0; cumsum(sqrt(sum(diff(path).^2, 2)))];

    % DEBUG: save overlay for the last frame only
    if (count == smp)
        dbg = zeros(size(U,1), size(U,2), 3);
        dbg(:,:,3) = double(U) * 0.4;   % tube mask: dark blue
        dbg(:,:,2) = double(Q) * 0.8;   % Q skeleton: green
        % traced path in white
        for di = 1:size(path,1)
            dbg(path(di,1), path(di,2), :) = [1 1 1];
        end
        % right anchor in cyan
        dbg(right_anchor(1), right_anchor(2), :) = [0 1 1];
        % tip_final in magenta
        dbg(tip_final(count,1), tip_final(count,2), :) = [1 0 1];
        imwrite(dbg, fullfile(outpath, [fname '_debug_skel.png']));
        disp(['DEBUG saved: ' fullfile(outpath, [fname '_debug_skel.png'])]);
    end

    % Subsample to 100 evenly-spaced points and smooth
    if (count == smp) npoints = ceil(path_dist(end)*1.1); end
    nline = 1:100; norder = floor(nline*path_dist(end)/100);
    nfinal = dsearchn(path_dist, norder');
    yct = yctk(nfinal); xct = xctk(nfinal); distct = path_dist(nfinal);
    xct = round(sgolayfilt(double(xct),3,15)); yct = round(sgolayfilt(double(yct),3,15));
    xct = max(1, min(xct, size(U,2))); yct = max(1, min(yct, size(U,1)));

    distc_t = pdist2(tip_final(count,:), Qef);
    [tmp, cut] = min(abs(distct - distc_t));
    xc = xct(cut:end); yc = yct(cut:end); distc = distct(cut:end);
    
    % Calculate the gradient of the center line to get the normals
    dx = gradient(xc); dx(find(dx == 0)) = 0.01;
    dy = gradient(yc); dy(find(dy == 0)) = 0.01;

    % Finding the points where the normals hit the edge curves
    poscross1 = []; poscross2 = [];
    for n = 1:length(xc)
        nfitc = fit(vertcat(xc(n),(xc(n) - dy(n))),vertcat(yc(n),(yc(n) + dx(n))),'poly1');
    
        if (n == 1) start_nfitc(:,:) = [nfitc.p1 nfitc.p2]; end
        
        edge1 = total1(:,1) - nfitc.p1.*total1(:,2) - nfitc.p2;
        [tmp cross1] = min(abs(edge1));
        poscross1(n) = cross1;
        
        edge2 = total2(:,1) - nfitc.p1.*total2(:,2) - nfitc.p2;
        [tmp cross2] = min(abs(edge2));
        poscross2(n) = cross2;
    end
    
    % Ensure that all overlapping diameter lines are shifted backwards to
    % ensure continuity     
    [poscross1, poscross2, distcf] = line_continuity(poscross1,poscross2,1,distc);
    [poscross1, poscross2, distcf] = line_continuity(poscross1,poscross2,2,distcf);
     
    xy1 = []; xy2 = []; xy1 = total1(poscross1,:); xy2 = total2(poscross2,:); 
    if (length(xy1) > 20)
        xy1 = floor(sgolayfilt(xy1,3,15)); xy2 = floor(sgolayfilt(xy2,3,15));
    end
    xyout = vertcat(find(xy1(:,2) > size(U,2)), find(xy2(:,2) > size(U,2)));
    xy1(xyout,:) = []; xy2(xyout,:) = []; distcf(xyout) = [];
    
    % Cutoff the tip 
    [tmp, distpos, tmp] = intersect(distc,distcf);
    distctf = [distct(1:cut-1); distc(distpos)]; xctf = [xct(1:cut-1); xc(distpos)]; yctf = [yct(1:cut-1); yc(distpos)]; 
    linectf = [yctf xctf];

    if (ROItype > 0)
        Esize = size(U);
        % Find ROI from centerline distance using percentages or distance
        if (pixelsize == 0)
            percent = (100*distctf)./(distctf(end));
            start_length = abs(percent - starti); [tmp startpos] = min(start_length);
            stop_length = abs(percent - stopi); [tmp stoppos] = min(stop_length);
            distc_t = (100*distc_t)/max(distctf);
        else
            start_length = abs(distctf*pixelsize - starti); [tmp startpos] = min(start_length);
            stop_length = abs(distctf*pixelsize - stopi); [tmp stoppos] = min(stop_length);
            distc_t = distc_t*pixelsize;
        end
        
        % Project ROI length onto the side curves
        [startc1,stopc1] = closest_bound(total1,xctf,yctf,max(startpos,1),max(stoppos,1));
        [startc2,stopc2] = closest_bound(total2,xctf,yctf,max(startpos,1),max(stoppos,1));
        
        % Create masks for rectangles and circles, and include whether they are
        % normal, split or stationary
        if (ROItype ~= 2 | count == smp)
            if (circle == 0)
                roi = vertcat(total1(startc1:stopc1,:), total2(stopc2:-1:startc2,:));
                if (starti < distc_t) roi = vertcat(boundb(postotal2(1):postotal1(2),:),roi); end
                F = poly2mask(roi(:,2),roi(:,1),Esize(1),Esize(2));
            else
                mask = zeros(Esize(1),Esize(2));
                roi = [linectf(stoppos,1) linectf(stoppos,2)];
                mask(roi(1),roi(2)) = 1;
                F = bwdist(mask) >= 0.5*circle.*diamo;
                F = imcomplement(F);
            end
            
            if (split == 1)
                if (circle > 0)
                    stoppos = length(linectf); stopc1 = length(total1); stopc2 = length(total2);
                end
                roi1 = vertcat(total1(startc1:stopc1,:), linectf(stoppos:-1:startpos,:));
                roi2 = vertcat(total2(startc2:stopc2,:), linectf(stoppos:-1:startpos,:));
                if (starti < distc_t)
                    roi1 = vertcat(boundb(range2(1):postotal1(2),:),roi1,boundb(range2(1),:));
                    roi2 = vertcat(boundb(range2(1):-1:postotal2(1),:),roi2,boundb(range2(1),:));
                end
                F1 = F.*poly2mask(roi1(:,2),roi1(:,1),Esize(1),Esize(2));
                F2 = F.*poly2mask(roi2(:,2),roi2(:,1),Esize(1),Esize(2));
            end
        end
    
    
        % Rotate BT1 and BT2
        if (type == 1)
            BT1r = imrotate(BT1(:,:,count),-90);
            if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),-90); end
        elseif (type == 3)
            BT1r = imrotate(BT1(:,:,count),90);
            if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),90); end
        elseif (type == 4)
            BT1r = imrotate(BT1(:,:,count),180);
            if ~isempty(BT2), BT2r = imrotate(BT2(:,:,count),180); end
        else
            BT1r = BT1(:,:,count);
            if ~isempty(BT2), BT2r = BT2(:,:,count); end
        end
        
        
        % Calculate average intensities and pixel numbers
        if (max(O(:)) <= 255) FO = uint8(F);
        else FO = uint16(F);    
        end
        F = uint16(F);
        
        Fpixelnum(count) = nnz(O.*FO);
        intensityM(count) = sum(O(:))/nnz(O);
        if ~strcmp(mode, 'two_raw')
            intensityM_F(count) = sum(sum(O.*FO))/Fpixelnum(count);
            intensityB1_F(count) = sum(sum(BT1r.*F))/Fpixelnum(count);
            if ~isempty(BT2), intensityB2_F(count) = sum(sum(BT2r.*F))/Fpixelnum(count); end
        end

        if (split)
            if (max(O(:)) <= 255) F1O = uint8(F1); F2O = uint8(F2);
            else F1O = uint16(F1); F2O = uint16(F2);
            end

            F1 = uint16(F1);
            F2 = uint16(F2);

            F1pixelnum(count) = nnz(O.*F1O);
            F2pixelnum(count) = nnz(O.*F2O);
            if ~strcmp(mode, 'two_raw')
                intensityM_F1(count) = sum(sum(O.*F1O))/F1pixelnum(count);
                intensityB1_F1(count) = sum(sum(BT1r.*F1))/F1pixelnum(count);
                if ~isempty(BT2), intensityB2_F1(count) = sum(sum(BT2r.*F1))/F1pixelnum(count); end
                intensityM_F2(count) = sum(sum(O.*F2O))/F2pixelnum(count);
                intensityB1_F2(count) = sum(sum(BT1r.*F2))/F2pixelnum(count);
                if ~isempty(BT2), intensityB2_F2(count) = sum(sum(BT2r.*F2))/F2pixelnum(count); end
            end
        end
        
        % Histogram of first and last frame (smp=col1, stp=col2)
        if (distributions)
            if (count == stp || count == smp)
                Msize = [numel(O),1]; BT1size = [numel(BT1r),1];
                Mhist(:,d) = reshape(O,Msize);
                B1hist(:,d) = reshape(BT1r,BT1size);
                MhistF(:,d) = reshape(O.*FO,Msize);
                B1histF(:,d) = reshape(BT1r.*F,BT1size);
                if ~isempty(BT2)
                    BT2size = [numel(BT2r),1];
                    B2hist(:,d) = reshape(BT2r,BT2size);
                    B2histF(:,d) = reshape(BT2r.*F,BT2size);
                end
                d = d+1;
            end
        end
    end
    
    % Cut off the tip part of the diameter calculation if necessary
    if (pixelsize > 0) cutoffp = dsearchn(distcf',diamcutoff/pixelsize);
    else cutoffp = dsearchn(distcf',diamcutoff);
    end
    if (cutoffp > 1) xy1(cutoffp-1,:) = []; xy2(cutoffp-1,:) = []; end

    % Diameter of tube
    diamf = diag(pdist2(xy1,xy2));
    diamf_avg(count) = sum(diamf)/length(diamf);
    
    % Kymograph
    if (nkymo > 0)
        kymo_len = ceil(path_dist(end));

        % Save smp centerline for the fixed-line kymograph
        if (count == smp)
            yctk_smp = yctk; xctk_smp = xctk;
            kymo_len_smp = kymo_len;
            start_nfitc_smp = start_nfitc;
        end

        % Rotate L frame to match the rotated coordinate frame used for centerline
        Lframe = L(:,:,count);
        if (type == 1) Lframe = imrotate(Lframe,-90);
        elseif (type == 3) Lframe = imrotate(Lframe,90);
        elseif (type == 4) Lframe = imrotate(Lframe,180);
        end

        % Per-frame centerline kymograph
        linecte = []; linecte(:,:,1) = [yctk, xctk];
        for a = 2:nkymo
            if (mod(a,2) == 0), ind = floor(a*0.5);
            else, ind = -floor(a*0.5); end
            if (start_nfitc(1) < 0)
                if (mod(a,2) == 0), linecte(:,:,a) = [yctk+ind, xctk-ind];
                else, linecte(:,:,a) = [yctk-ind, xctk+ind]; end
            else
                if (mod(a,2) == 0), linecte(:,:,a) = [yctk+ind, xctk+ind];
                else, linecte(:,:,a) = [yctk-ind, xctk-ind]; end
            end
        end
        kymo = [];
        for a = 1:nkymo
            kymo(:,a) = improfile(imgaussfilt(Lframe,1.5), linecte(:,2,a), linecte(:,1,a), double(kymo_len));
        end
        kymo(isnan(kymo)) = 0;
        kymo_avg(:,count-stp+1) = vertcat(zeros((5 + npoints - kymo_len),1), mean(kymo,2));

        % Fixed-line kymograph using smp centerline for all frames
        linecte_f = []; linecte_f(:,:,1) = [yctk_smp, xctk_smp];
        for a = 2:nkymo
            if (mod(a,2) == 0), ind = floor(a*0.5);
            else, ind = -floor(a*0.5); end
            if (start_nfitc_smp(1) < 0)
                if (mod(a,2) == 0), linecte_f(:,:,a) = [yctk_smp+ind, xctk_smp-ind];
                else, linecte_f(:,:,a) = [yctk_smp-ind, xctk_smp+ind]; end
            else
                if (mod(a,2) == 0), linecte_f(:,:,a) = [yctk_smp+ind, xctk_smp+ind];
                else, linecte_f(:,:,a) = [yctk_smp-ind, xctk_smp-ind]; end
            end
        end
        kymo_f = [];
        for a = 1:nkymo
            kymo_f(:,a) = improfile(imgaussfilt(Lframe,1.5), linecte_f(:,2,a), linecte_f(:,1,a), double(kymo_len_smp));
        end
        kymo_f(isnan(kymo_f)) = 0;
        kymo_avg_fixed(:,count-stp+1) = vertcat(zeros((5 + npoints - kymo_len_smp),1), mean(kymo_f,2));
    end

    % Tip plot
    Splot = zeros(size(Q2));
    r1 = max(1,tip_final(count,1)-3); r2 = min(size(Splot,1),tip_final(count,1)+3);
    c1 = max(1,tip_final(count,2)-3); c2 = min(size(Splot,2),tip_final(count,2)+3);
    Splot(r1:r2,c1:c2) = 1;
 %   Splot(tip_ellipsef(1)-1:tip_ellipsef(1)+1,tip_ellipsef(2)-1:tip_ellipsef(2)+1) = 2;
 %   if (size(Sef,1) > 1) Splot(tip_mid(1)-3:tip_mid(1)+3,tip_mid(2)-3:tip_mid(2)+3) = 3; end
 %   Splot(tip_skel(1)-1:tip_skel(1)+1,(2)-1:tip_skel(2)+1) = 4;
    
    Cplot = zeros(size(Q2)); Cplot(sub2ind([size(Cplot,1) size(Cplot,2)],yctk,xctk)) = 2.*ones(size(xctk));
    %for j = 1:length(xy1) Cplot = drawline(Cplot,xy1(j,1),xy1(j,2),xy2(j,1),xy2(j,2),1); end
    Cplot(:,size(U,2)+1:end) = [];
    
    % Plot two images
    if (tip_plot) h = figure('visible', 'off');
    else h = figure;
    end
    
    %subplot(1,2,2)
    image2 = U*20+Splot*40+Cplot*30;
    if (ROItype > 0) image2 = image2 + double(F1*60 + F2*80); end
    imagesc(image2);
    
    if (tip_plot)
        txtstr = strcat('Time(s): ',num2str((count*frame_rate)));
        text(10,10,txtstr,'color','white')
        set(gca,'xtick',[]);
        set(gca,'xticklabel',[]);
        set(gca,'ytick',[])
        set(gca,'yticklabel',[]);
        frame = getframe(gcf);
        writeVideo(V,frame);
        close(h);
    end
end

if (tip_plot == 1) close(V); end

% Final tip movement/diameter/pixel number on a per frame basis
fig1 = figure;
if strcmp(mode, 'two_raw')
    nsp = 2;
else
    nsp = 3;
end
subplot(nsp,1,1)
plot(tip_final(stp:smp,2),tip_final(stp:smp,1),'b')
axis([min(tip_final(stp:smp,2))-5  max(tip_final(stp:smp,2))+5 min(tip_final(stp:smp,1))-5 max(tip_final(stp:smp,1))+5]);
title('Tip Final Position', 'FontSize',16);

subplot(nsp,1,2)
if (pixelsize > 0)
    plot(stp:smp, diamf_avg(stp:smp)*pixelsize, 'b')
    ylabel('µm', 'FontSize',12);
    axis([stp-1 smp+1 0.5*max(diamf_avg)*pixelsize 1.25*max(diamf_avg)*pixelsize])
else
    plot(stp:smp, diamf_avg(stp:smp), 'b')
    ylabel('pixels', 'FontSize',12);
    axis([stp-1 smp+1 0.5*max(diamf_avg) 1.25*max(diamf_avg)])
end
xlabel('Frame', 'FontSize',12);
title('Average Diameter','FontSize',16)

if ~strcmp(mode, 'two_raw')
    subplot(nsp,1,3)
    plot(stp:smp,intensityM(stp:smp),'k') % whole-image intensity
    hold on
    plot(stp:smp,intensityM_F(stp:smp),'r') % full ROI
    if (split)
        plot(stp:smp,intensityM_F1(stp:smp),'b*') % split ROI 1
        plot(stp:smp,intensityM_F2(stp:smp),'g*') % split ROI 2
    end
    xlabel('Frame', 'FontSize',12);
    if strcmp(mode, 'ratio')
        title('Intensity Ratio', 'FontSize',16)
    else
        title('Intensity (Acceptor)', 'FontSize',16)
    end
    % Scale axis to include all plotted values (whole-tube + ROI)
    all_vals = [intensityM(stp:smp), intensityM_F(stp:smp)];
    if (split), all_vals = [all_vals, intensityM_F1(stp:smp), intensityM_F2(stp:smp)]; end
    all_vals = all_vals(isfinite(all_vals) & all_vals > 0);
    if ~isempty(all_vals)
        axis([stp-1 smp+1 min(all_vals)*0.75 max(all_vals)*1.25]);
    end
end
savefig(fig1, fullfile(figpath, [fname '_tip_diam_intensity.fig']));
exportgraphics(fig1, fullfile(figpath, [fname '_tip_diam_intensity.png']));

% Kymograph (per-frame centerline)
if (nkymo > 0)
    kymo_avg(find(kymo_avg<0)) = 0;
    fig2 = figure;
    map = colormap(jet(255));
    map = vertcat([0 0 0],map);
    kymo_img = uint8(kymo_avg.*255/max(kymo_avg(:)));
    imshow(kymo_img, map);
    savefig(fig2, fullfile(figpath, [fname '_kymograph.fig']));
    imwrite(ind2rgb(kymo_img, map), fullfile(figpath, [fname '_kymograph.png']));

    % Fixed-line kymograph (smp centerline applied to all frames)
    kymo_avg_fixed(find(kymo_avg_fixed<0)) = 0;
    fig2b = figure;
    map = colormap(jet(255));
    map = vertcat([0 0 0],map);
    kymo_img_f = uint8(kymo_avg_fixed.*255/max(kymo_avg_fixed(:)));
    imshow(kymo_img_f, map);
    savefig(fig2b, fullfile(figpath, [fname '_kymograph_fixed_line.fig']));
    imwrite(ind2rgb(kymo_img_f, map), fullfile(figpath, [fname '_kymograph_fixed_line.png']));
end

% Total intensity plots (ratio trace only available with ratio stack)
if (ROItype > 0) && strcmp(mode, 'ratio')
    fig3 = figure;
    if (split)
        F1ratio = intensityB1_F1(stp:smp)./intensityB2_F1(stp:smp);
        subplot(1,3,2)
        hold on
        plot(stp:smp,F1ratio,'b')
        axis([stp-1 smp+1 0.8 max(F1ratio(:))*1.25]);
        title('Intensity F1 (split ROI 1)'); xlabel('Frame');
       
        F2ratio = intensityB1_F2(stp:smp)./intensityB2_F2(stp:smp);
        subplot(1,3,3)
        hold on
        plot(stp:smp,F2ratio,'b')
        axis([stp-1 smp+1 0.8 max(F1ratio(:))*1.25]);
        title('Intensity F2 (split ROI 2)'); xlabel('Frame');
       
        subplot(1,3,1); 
        plot(stp:smp,F2ratio./F1ratio,'b')
        axis([stp-1 smp+1 0.5 2]);
        title('Intensity ratio between split ROIs'); xlabel('Frame');
    else
        Fratio = intensityB1_F(stp:smp)./intensityB2_F(stp:smp);
        hold on
        plot(stp:smp,Fratio,'b');
        axis([stp-1 smp+1 0.8 max(Fratio(:))*1.25]);
        title('Intensity F'); xlabel('Frame');
    end
    savefig(fig3, fullfile(figpath, [fname '_intensity_ratio.fig']));
    exportgraphics(fig3, fullfile(figpath, [fname '_intensity_ratio.png']));
end

% ROI intensity figure for single-channel and two_raw modes
if (ROItype > 0) && ~strcmp(mode, 'ratio')
    fig3 = figure;
    F1v = intensityM_F1(stp:smp); F2v = intensityM_F2(stp:smp); Fv = intensityM_F(stp:smp);
    if (split)
        subplot(1,2,1)
        hold on
        plot(stp:smp, Fv,  'k'); plot(stp:smp, F1v, 'b'); plot(stp:smp, F2v, 'g');
        legend('Full ROI','Half 1','Half 2','Location','best');
        xlabel('Frame'); title('ROI Intensity (Acceptor)', 'FontSize',14);
        all_v = [Fv, F1v, F2v]; all_v = all_v(isfinite(all_v) & all_v > 0);
        if ~isempty(all_v), axis([stp-1 smp+1 min(all_v)*0.85 max(all_v)*1.15]); end

        subplot(1,2,2)
        ratio_12 = F2v ./ F1v;
        plot(stp:smp, ratio_12, 'k');
        xlabel('Frame'); title('Intensity Ratio Half2/Half1', 'FontSize',14);
        rv = ratio_12(isfinite(ratio_12) & ratio_12 > 0);
        if ~isempty(rv), axis([stp-1 smp+1 min(rv)*0.85 max(rv)*1.15]); end
    else
        plot(stp:smp, Fv, 'r');
        xlabel('Frame'); title('ROI Intensity (Acceptor)', 'FontSize',14);
        all_v = Fv(isfinite(Fv) & Fv > 0);
        if ~isempty(all_v), axis([stp-1 smp+1 min(all_v)*0.85 max(all_v)*1.15]); end
    end
    savefig(fig3, fullfile(figpath, [fname '_roi_intensity.fig']));
    exportgraphics(fig3, fullfile(figpath, [fname '_roi_intensity.png']));
end

% CSV export of per-frame measurements
% Intensities are mean per non-zero pixel inside each mask.
% Total signal = mean × pixel_count.
csv_frames  = (stp:smp)';
csv_time_s  = csv_frames .* frame_rate;
csv_tip_row = tip_final(stp:smp, 1);
csv_tip_col = tip_final(stp:smp, 2);
csv_diam_px = diamf_avg(stp:smp)';
csv_diam_um = csv_diam_px .* pixelsize;
csv_wtmean  = intensityM(stp:smp)';
csv_overlap = Ucount(stp:smp)';

if (ROItype > 0)
    csv_roi_npx   = Fpixelnum(stp:smp)';
    csv_roi_mean  = intensityM_F(stp:smp)';
    csv_roi_total = csv_roi_mean .* csv_roi_npx;

    if (split)
        csv_h1_npx   = F1pixelnum(stp:smp)';
        csv_h1_mean  = intensityM_F1(stp:smp)';
        csv_h1_total = csv_h1_mean .* csv_h1_npx;
        csv_h2_npx   = F2pixelnum(stp:smp)';
        csv_h2_mean  = intensityM_F2(stp:smp)';
        csv_h2_total = csv_h2_mean .* csv_h2_npx;
        csv_ratio_h2h1 = csv_h2_mean ./ csv_h1_mean;

        T = table(csv_frames, csv_time_s, csv_tip_row, csv_tip_col, ...
                  csv_diam_px, csv_diam_um, csv_overlap, csv_wtmean, ...
                  csv_roi_npx, csv_roi_mean, csv_roi_total, ...
                  csv_h1_npx, csv_h1_mean, csv_h1_total, ...
                  csv_h2_npx, csv_h2_mean, csv_h2_total, csv_ratio_h2h1, ...
                  'VariableNames', { ...
                  'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
                  'Diameter_px', 'Diameter_um', 'Frame_overlap_ratio', 'WholeTube_mean_intensity', ...
                  'ROI_pixel_count', 'ROI_mean_intensity', 'ROI_total_signal', ...
                  'Half1_pixel_count', 'Half1_mean_intensity', 'Half1_total_signal', ...
                  'Half2_pixel_count', 'Half2_mean_intensity', 'Half2_total_signal', ...
                  'Ratio_Half2_Half1'});
    else
        T = table(csv_frames, csv_time_s, csv_tip_row, csv_tip_col, ...
                  csv_diam_px, csv_diam_um, csv_overlap, csv_wtmean, ...
                  csv_roi_npx, csv_roi_mean, csv_roi_total, ...
                  'VariableNames', { ...
                  'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
                  'Diameter_px', 'Diameter_um', 'Frame_overlap_ratio', 'WholeTube_mean_intensity', ...
                  'ROI_pixel_count', 'ROI_mean_intensity', 'ROI_total_signal'});
    end
else
    T = table(csv_frames, csv_time_s, csv_tip_row, csv_tip_col, ...
              csv_diam_px, csv_diam_um, csv_overlap, csv_wtmean, ...
              'VariableNames', { ...
              'Frame', 'Time_s', 'Tip_row_px', 'Tip_col_px', ...
              'Diameter_px', 'Diameter_um', 'Frame_overlap_ratio', 'WholeTube_mean_intensity'});
end
writetable(T, fullfile(outpath, [fname '_measurements.csv']));
disp(['CSV saved: ' fullfile(outpath, [fname '_measurements.csv'])]);

% Distributions of intensity on the first and last frames (col1=smp, col2=stp)
if (distributions == 1)
    Mhist = double(Mhist); MhistF = double(MhistF);
    B1hist = double(B1hist); B1histF = double(B1histF);

    figd1 = figure;
    subplot(1,2,1)
    histogram(Mhist(Mhist(:,1)>0.1,1)); hold on; histogram(Mhist(Mhist(:,2)>0.1,2))
    title('Histogram C')
    subplot(1,2,2)
    histogram(MhistF(MhistF(:,1)>0.1,1)); hold on; histogram(MhistF(MhistF(:,2)>0.1,2))
    title('Histogram CF')
    savefig(figd1, fullfile(figpath, [fname '_hist_C.fig']));
    exportgraphics(figd1, fullfile(figpath, [fname '_hist_C.png']));

    figd2 = figure;
    subplot(1,2,1)
    histogram(B1hist(B1hist(:,1)>0.1,1)); hold on; histogram(B1hist(B1hist(:,2)>0.1,2))
    title('Histogram B1')
    subplot(1,2,2)
    histogram(B1histF(B1histF(:,1)>0.1,1)); hold on; histogram(B1histF(B1histF(:,2)>0.1,2))
    title('Histogram B1F')
    savefig(figd2, fullfile(figpath, [fname '_hist_B1.fig']));
    exportgraphics(figd2, fullfile(figpath, [fname '_hist_B1.png']));

    if ~isempty(BT2)
        B2hist = double(B2hist); B2histF = double(B2histF);
        figd3 = figure;
        subplot(1,2,1)
        histogram(B2hist(B2hist(:,1)>0.1,1)); hold on; histogram(B2hist(B2hist(:,2)>0.1,2))
        title('Histogram B2')
        subplot(1,2,2)
        histogram(B2histF(B2histF(:,1)>0.1,1)); hold on; histogram(B2histF(B2histF(:,2)>0.1,2))
        title('Histogram B2F')
        savefig(figd3, fullfile(figpath, [fname '_hist_B2.fig']));
        exportgraphics(figd3, fullfile(figpath, [fname '_hist_B2.png']));
    end
end

if (workspace) save([outpath '/' fname '_result.mat']); end