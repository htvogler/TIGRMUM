function [Q2, Qe,Qarea] = branch_removal(Q,Qbf,Qel,angdiff,close_dist,side_info)
% side_info (2026-09-30, optional, default [] = old behaviour): struct('c',...,'n',...,
% 'side',...) -- the shank-axis guard's own axis (see side_memory_axis_find's doc near the
% top of main_track_movies.m). The angle+area heuristic below picks which of (up to) 3
% locally-competing skeleton arms at a branch point is the spurious one purely from local
% orientation/size -- it has no notion of which side of the tube's own known axis is
% correct, so at a genuine apical fork it can keep the WRONG arm whenever local conditions
% (noise, a stub angled favourably) make the wrong one look like the "real" continuation.
% When side_info is given and exactly one of the (up to) 3 local arms disagrees with it
% while the angle-heuristic's current discard choice (Q3min) is NOT that arm (i.e. it would
% keep the wrong-side arm and discard a correct-side one), the choice is overridden to
% discard the disagreeing arm instead. Never fires when the side test is ambiguous (0 or 2+
% of the arms disagree) or side_info wasn't provided, so it only acts on a genuine,
% unambiguous mismatch -- see main_track_movies.m's doc near the top for why this matters
% (prevents the tip jumping to the wrong side of the apical region).
if nargin < 6, side_info = []; end
Q2 = Q;
Qbr = Qbf(:,1);
Qbc = Qbf(:,2);
Qarea = 1;

while(length(Qbr) > 0)
    Qtmp = Q2;
    Q2(Qbr(1)-1:Qbr(1)+1,Qbc(1)-1:Qbc(1)+1) = 0;
    Q2label = bwlabel(Q2);
    Q2stat = regionprops(Q2label,'Area','PixelList','Centroid');   
    Q2area = []; Q2cen = [];
    for i = 1:length(Q2stat)
        Q2area = [Q2area Q2stat(i).Area];
        Q2cen = [Q2cen Q2stat(i).Centroid(1)];
    end
    
    Qea = [];
    if (length(Q2stat) < 3)
        [tmp Q2pos] = min(Q2cen);
        Qea = intersect(circshift(Qel,1,2),Q2stat(Q2pos).PixelList,'rows');
        
        Q2m = zeros(size(Q2)); Q2m = createcircles(Q2m,[Qbc(1) Qbr(1)],3);
        Q3label = Q2m.*Q2;
        Q4bridge = Q3label;
        
        Q4bridge(Qbr(1),Qbc(1)) = 1;
        Q4bridge = bwmorph(Q4bridge,'bridge');
        Q4bridge = bwmorph(Q4bridge,'clean');
        Q4bridge = bwmorph(Q4bridge,'thin');
        Q4extra = Q4bridge - Q3label;
        Q2 = Q2 + Q4extra;
        Q2(find(Q2 > 0 )) = 1;   

        Qbr(1) = []; Qbc(1) = [];
    else
        [tmp, Q2ci] = sort(Q2cen);
        Q2a1 = Q2stat(Q2ci(1)).PixelList;
        Q2a2 = Q2stat(Q2ci(2)).PixelList;
        Qea = [intersect(circshift(Qel,1,2),Q2a1,'rows'); intersect(circshift(Qel,1,2),Q2a2,'rows')];
        
        Q2m = zeros(size(Q2)); Q2m = createcircles(Q2m,[Qbc(1) Qbr(1)],20);
        Q3label = Q2m.*Q2label;
        Q3stat = regionprops(Q3label,'Orientation','Area');
            
        Q3area = [];
        for i = 1:length(Q3stat)
            Q3area = [Q3area Q3stat(i).Area];
        end
        [Q3areamin Q3ai] = min(Q3area);

        if (Q3areamin < 4) 
            Q3min = Q3ai;
            Q3diffs = [1 2 1];
        else
            % Angle check
            Q3ang = [Q3stat(1).Orientation Q3stat(2).Orientation Q3stat(3).Orientation];
            Q3diff = diff(Q3ang); Q3diff(3) = Q3ang(1)-Q3ang(3);
            u = Q3diff >= 90;
            Q3diff(u) = 180 - Q3diff(u);
            l = Q3diff <= -90;
            Q3diff(l) = 180 + Q3diff(l);
            Q3diff = abs(circshift(Q3diff,2));
            [Q3diffs, Q3di] = sort(Q3diff);
            Q3min = Q3di(1);
            if (close_dist == 2)
                Q3cdiff = diff(Q2cen); Q3cdiff(3) = Q2cen(1)-Q2cen(3);
                Q3cdiff = abs(circshift(Q3cdiff,2));
                [tmp,Q3cdi] = min(abs(Q3cdiff));
                if (Q3cdi == Q3di(1)) Q3min = Q3di(2); end
            elseif (close_dist == 1)
                if (Q2ci(1) == Q3di(1)) Q3min = Q3di(2); end
            end
        end

        % Safety override: never discard the arm that's actually the
        % LARGEST of the three by true (unclipped) size. Q3area above is
        % deliberately clipped to a 20px disk around the branch point, to
        % keep the angle comparison local/fair -- but that clipping throws
        % away exactly the signal (true arm length) that would otherwise
        % make a long continuous tube obviously distinguishable from a
        % short spurious stub. Confirmed on HV209_116 frame 2297: the
        % angle heuristic picked the ~700px main shaft as the "odd one
        % out" relative to a ~15px stub and a ~25px side-arm (all three
        % look comparable within just the local 20px disk), discarded the
        % real tube, and left only the stub+side-arm reconnected as S2 --
        % see diag_2297_11_Q2_debranched.png / _15_S2_debranched.png.
        Q2area3 = Q2area(1:3);
        [~, Q2_largest] = max(Q2area3);
        if Q3min == Q2_largest
            [~, Q3min] = min(Q2area3);
        end

        % Shank-axis side override (2026-09-30) -- see this function's own doc above.
        if ~isempty(side_info)
            n_arms = min(3, length(Q2stat));
            arm_side = zeros(1, n_arms);
            bpt = [Qbr(1), Qbc(1)];
            for ai = 1:n_arms
                pix = Q2stat(ai).PixelList; % [col row]
                pix_rc = [pix(:,2), pix(:,1)];
                [~, nearest_i] = min(sum((pix_rc - bpt).^2, 2));
                rep_pt = pix_rc(nearest_i, :);
                off = dot(rep_pt - side_info.c, side_info.n);
                arm_side(ai) = sign(off);
            end
            disagree = find(arm_side ~= side_info.side);
            if numel(disagree) == 1 && Q3min ~= disagree
                Q3min = disagree;
            end
        end

        if (angdiff > 0)
            [tmp, Q2ai] = sort(Q2area);
            Qarea = bwarea(Q2label(Q2label == Q2ai(1)))/bwarea(Q2label(Q2label == Q2ai(2)));
        end
    
        % Find edges
        Q2ci(find(Q2ci == Q3min)) = [];
        Q3a1 = Q2stat(Q2ci(1)).PixelList;
        Q3a2 = Q2stat(Q2ci(2)).PixelList;
        
        % Compare areas of 2 main branches
        Qeb1 = intersect(Qea,Q3a1,'rows');
        Qeb2 = intersect(Qea,Q3a2,'rows');
        [tmp,Qep1] = intersect(Qea,Qeb1,'rows');
        [tmp,Qep2] = intersect(Qea,Qeb2,'rows');
        if (Qep1 == 2)
            Qea = circshift(Qea,1,1);
            Qarea = 1/Qarea;
        elseif (Qep2 == 2)
            Qea = circshift(Qea,1,1);
            Qarea = 1/Qarea;
        end
        
        if(Q3diffs(2) - Q3diffs(1) >= angdiff*0.25 && Q3diffs(3) > angdiff && close_dist > 0)
            Q3label(find(Q3label == Q3min)) = 0;
            Q3label(find(Q3label > 0 )) = 1;
            Q4bridge = Q3label;

            Q4bridge(Qbr(1),Qbc(1)) = 1;
            Q4bridge = bwmorph(Q4bridge,'bridge');
            Q4bridge = bwmorph(Q4bridge,'clean');
            Q4bridge = bwmorph(Q4bridge,'thin');
            Q4extra = Q4bridge - Q3label;
            Q2label(find(Q2label == Q3min)) = 0;
            Q2 = Q2label + Q4extra;
            Q2(find(Q2 > 0 )) = 1;
            if (size(Qea,1) > 1) Qea(2,:) = []; end
        else
            Q2 = Qtmp;
        end
        Qbr(1) = []; Qbc(1) = [];
    end
end
if (angdiff == 0)
    Qei = bwmorph(Q2,'endpoints');
    [Qer,Qec] = find(Qei > 0);
    Qe = [Qer Qec];
    [tmp,Qepos] = max(Qec);
    Qe(Qepos,:) = [];
else    
    Qe = circshift(Qea,1,2);
end