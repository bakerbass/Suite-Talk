% Parameters
filename = 'Noisy Speech.wav';  % Use any mono speech file
winLens = [1024 + 512, 2048, 4096, 8192, 8192 *2];
overlapRatios = [0, 0.25, 0.5, 0.66, 0.75];               % 50% overlap, change as desired

% Load audio
[x, fs] = audioread(filename);
if size(x,2) > 1
    x = mean(x,2); % Mono only for simplicity
end
x = x(:);
N = length(x);

% Window for COLA

for wIdx = 1:length(winLens)
    winLen = winLens(wIdx);
    for oIdx = 1:length(overlapRatios)
        overlapRatio = overlapRatios(oIdx);
        hop = round(winLen * (1-overlapRatio));
        w = hann(winLen, 'periodic');
        
        % Pad signal at start and end
        numFrames = ceil((N - winLen) / hop) + 1;
        padLen = (numFrames-1)*hop + winLen - N;
        xPad = [x; zeros(padLen,1)];
        
        % Output buffer
        y = zeros(size(xPad));
        
        for frame = 0:(numFrames-1)
            idx = (1:winLen) + frame*hop;
            frameIn = xPad(idx) .* w;
            frameOut = enhanceSpeech(frameIn, fs) .* w;
            y(idx) = y(idx) + frameOut; % Overlap-add
        end
        
        % Trim to original length
        y = y(1:N);
        
        t = (1:N)/fs;
        figure;
        plot(t, x, 'b'); hold on; plot(t, y, 'r');
        xlabel('Time (s)'); legend('Input','Enhanced');
        title('Original vs Enhanced Speech');
        
        audiowrite('temp.wav', y, fs);
        winLen
        overlapRatio
        evaluateMetrics('temp.wav')
    end
end