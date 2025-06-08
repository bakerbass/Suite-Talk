classdef suiteTalk < audioPlugin & matlab.System
    properties
        AttackTime     = 0.01
        ReleaseTime    = 0.35
        ClosedGain_dB  = -60
        Ratio          = 4
        combAmount     = -13
        EnhanceLevel   = -12
        ToggleComb = 'Off'
        ToggleEnhance = 'On'
        ToggleLimiter = 'On'
    end

    properties (Constant)
        PluginInterface = audioPluginInterface( ...
        ...% Gate section
        audioPluginParameter('AttackTime', ...
            'DisplayName', 'Attack Time', ...
            'Mapping', {'log', 0.001, 1}, ...
            'Style', 'rotaryknob',...
            'Layout', [2 1; 3 1]), ...
        audioPluginParameter('ReleaseTime', ...
            'DisplayName', 'Release Time', ...
            'Style', 'rotaryknob',...
            'Mapping', {'log', 0.001, 1}, ...
            Layout=[2 2; 3 2]), ...
        audioPluginParameter('ClosedGain_dB', ...
            'DisplayName', 'Gate Floor (dB)', ...
            'Mapping', {'lin', -120, -20}, ...
            'Style', 'rotaryknob',...
            Layout=[2 3; 3 3]), ...
        ...
        ...% Enhancer section
        audioPluginParameter('EnhanceLevel', ...
            'DisplayName', 'Enhancer Level (dB)', ...
            'Mapping', {'lin', -12, 0}, ...
            'Style', 'rotaryknob',...
            Layout=[5 1; 6 1]), ...
        audioPluginParameter('ToggleEnhance', ...
            'DisplayName', 'Enhancer On/Off', ...
            'Style', 'vtoggle', ...
            'Mapping', {'enum', 'On', 'Off'}, ...
            Layout=[5 2; 6 2]), ...
        ...
        ...% Comb/Hum Reducer section
        audioPluginParameter('combAmount', ...
            'DisplayName', 'Hum reducer amount (dB)', ...
            'Mapping', {'lin', -24, -6}, ...
            'Style', 'rotaryknob',...
            Layout=[5 3; 6 3]), ...
        audioPluginParameter('ToggleComb', ...
            'DisplayName', 'Hum Reducer On/Off', ...
            'Style', 'vtoggle', ...
            'Mapping', {'enum', 'On', 'Off'}, ...
            Layout=[5 4; 6 4]), ...
        ...
        ...% Compression / Limiter section
        audioPluginParameter('Ratio', ...
            'DisplayName', 'Compression Ratio', ...
            'Mapping', {'lin', 1, 10}, ...
            'Style', 'rotaryknob',...
            'Layout',[8 1; 9 1]),...
        audioPluginParameter('ToggleLimiter', ...
            'DisplayName', 'Limiter On/Off', ...
            'Style', 'vtoggle', ...
            'Mapping', {'enum', 'On', 'Off'}, ...
            'Layout',[8 2; 9 2]),...
            'PluginName','Suite Talk', ...
        audioPluginGridLayout( ...
            RowHeight=[50 50 50 50 50 50 50 50, 50, 50], ...
            ColumnWidth=[125 125 125 125], ...
            Padding=[10 10 10 30])...
        );
        FFTLength  = 2048
        bufSize    = 1024
    end

    properties (Access=private)
        vadObj
        ring
        frameBuffer
        gateMask
        ringIdx   = 1
        gateIdx   = 1
        bufferFill= 0
        envState  = 0
        historyLen = 4096
        audioHistory
        gateHistory

        SampleRate
        crossover
        Compressor  = compressor
        Limiter = compressor
        mPEQ
        hpf_Fc = 90
        hpf_Slope = 24
        dp_Q = 0.5
        dp_Fc = 60
        lmBoost_Fc = 600
        lmBoost_Q = 0.9
        lmBoost_G = 3
        hmBoost_Fc = 3000
        hmBoost_Q = 0.6
        hmBoost_G = 4
        ds_Q = 0.4
        ds_maxG = 0
        ds_minG = -3
        ds_Fc = 7500
        FcLow = 6300
        FcHigh = 9800

        combDelaySamples
        combBuffer
        combIdx

        circBuf
        circIdx
        circFill
        outputBuffer
        fsOrig
        dsFactor = 6
        lastOut
        xfadeLength = 16
        tailBuffer
        isFirstBuffer = true
    end

    methods
        function plugin = suiteTalk()
            plugin.SampleRate = 44100;
            plugin.vadObj       = voiceActivityDetector('FFTLength', plugin.FFTLength);
            plugin.ring         = zeros(plugin.FFTLength,1);
            plugin.frameBuffer  = zeros(plugin.FFTLength,1);
            plugin.gateMask     = ones(plugin.FFTLength,1,'single');
            plugin.audioHistory = zeros(plugin.historyLen,1);
            plugin.gateHistory  = zeros(plugin.historyLen,1);
            plugin.crossover    = crossoverFilter;
            plugin.crossover.NumCrossovers = 3;
            plugin.Compressor = compressor(-12, 4);
            plugin.Limiter = compressor(-1.5, 100);
            plugin.mPEQ = multibandParametricEQ('Oversample',true, ...
                'NumEQBands', 4, ...
                'HasHighpassFilter', true, ...
                'HighpassCutoff', plugin.hpf_Fc, ...
                'HighpassSlope', plugin.hpf_Slope, ...
                'Frequencies', [plugin.dp_Fc, plugin.lmBoost_Fc, plugin.hmBoost_Fc, plugin.ds_Fc], ...
                'QualityFactors', [plugin.dp_Q, plugin.lmBoost_Q, plugin.hmBoost_Q, plugin.ds_Q], ...
                'PeakGains', [0, plugin.lmBoost_G, plugin.hmBoost_G, plugin.ds_maxG]);
            plugin.circBuf = zeros(plugin.bufSize,1);
            plugin.circIdx = 1;
            plugin.circFill = 0;
            plugin.outputBuffer = [];
            plugin.fsOrig = 48000;
            plugin.tailBuffer = zeros(plugin.xfadeLength,1);
        end
    end

    methods (Access=protected)
        function resetImpl(plugin)
            reset(plugin.vadObj);
            plugin.ring(:)         = 0;
            plugin.frameBuffer(:)  = 0;
            plugin.gateMask(:)     = 1;
            plugin.ringIdx         = 1;
            plugin.gateIdx         = 1;
            plugin.bufferFill      = 0;
            plugin.envState        = 0;
            plugin.audioHistory(:) = 0;
            plugin.gateHistory(:)  = 1;
            plugin.SampleRate = getSampleRate(plugin);
            plugin.crossover.SampleRate = plugin.SampleRate;
            plugin.crossover.CrossoverFrequencies = [150, plugin.FcLow, plugin.FcHigh];
            reset(plugin.Compressor);
            plugin.Compressor.SampleRate  = plugin.SampleRate;
            plugin.Compressor.Threshold   = -10;
            plugin.Compressor.Ratio       = plugin.Ratio;
            reset(plugin.Limiter);
            reset(plugin.mPEQ);
            plugin.combDelaySamples = round(plugin.SampleRate / 60);
            plugin.combBuffer       = zeros(plugin.combDelaySamples, 2);
            plugin.combIdx          = ones(1,2);
            plugin.circBuf(:) = 0;
            plugin.circIdx = 1;
            plugin.circFill = 0;
            plugin.outputBuffer = [];
            plugin.fsOrig = 48000;
            plugin.lastOut = 0;
            plugin.tailBuffer = zeros(plugin.xfadeLength, 1);
            plugin.isFirstBuffer = true;
        end

        function out = stepImpl(plugin, in)
            fs = plugin.getSampleRate();
            if mod(fs, plugin.dsFactor) ~= 0
                if plugin.dsFactor == 6 
                    plugin.dsFactor = 4;
                else
                    plugin.dsFactor = 6;
                end
            end
            N = size(in,1);
            nCh = size(in, 2);
            if plugin.fsOrig ~= fs
                plugin.fsOrig = fs;
            end
            if nCh > 1
                inM = mean(in,2);
            else
                inM = in;
            end

            % === VAD and gating on original input ===
            frameLen = N;
            inMono = inM;
            for n = 1:frameLen
                plugin.ring(plugin.ringIdx) = inMono(n);
                plugin.ringIdx = plugin.ringIdx + 1;
                if plugin.ringIdx > plugin.FFTLength
                    plugin.ringIdx = 1;
                end
                if plugin.bufferFill < plugin.FFTLength
                    plugin.bufferFill = plugin.bufferFill + 1;
                end
            end
            if plugin.bufferFill == plugin.FFTLength
                for k = 1:plugin.FFTLength
                    idx = mod(plugin.ringIdx + k - 2, plugin.FFTLength) + 1;
                    plugin.frameBuffer(k) = plugin.ring(idx);
                end
                [prob,~] = plugin.vadObj(plugin.frameBuffer);
                probThreshold = 0.75;
                if isscalar(prob)
                    plugin.gateMask = repmat(single(prob > probThreshold), plugin.FFTLength,1);
                else
                    plugin.gateMask = single(prob > probThreshold);
                    if numel(plugin.gateMask) ~= plugin.FFTLength
                        plugin.gateMask = repmat(single(mean(plugin.gateMask)>probThreshold), plugin.FFTLength,1);
                    end
                end
                plugin.gateIdx = 1;
            end
            fs    = plugin.fsOrig;
            aAtt  = exp(-1/(plugin.AttackTime*fs));
            aRel  = exp(-1/(plugin.ReleaseTime*fs));
            closed = db2mag(plugin.ClosedGain_dB);
            g     = plugin.envState;
            env   = zeros(N,1,'like',in);
            gainVec = zeros(N,1,'like',in);
            for n = 1:N
                idx = plugin.gateIdx;
                if idx > plugin.FFTLength, idx = 1; end
                tgt = double(plugin.gateMask(idx));
                if tgt > g
                    g = aAtt*g + (1-aAtt)*tgt;
                else
                    g = aRel*g + (1-aRel)*tgt;
                end
                env(n)      = g;
                gainVec(n)  = closed + (1-closed)*g;
                plugin.gateIdx = plugin.gateIdx + 1;
                if plugin.gateIdx > plugin.FFTLength
                    plugin.gateIdx = 1;
                end
            end
            plugin.envState = g;

            % === Downsample and enhance ===
            x_ds = resample(inM, 1, plugin.dsFactor);
            n_ds = length(x_ds);
            enh_ds = [];
            for n = 1:n_ds
                plugin.circBuf(plugin.circIdx) = x_ds(n);
                plugin.circIdx = plugin.circIdx + 1;
                if plugin.circIdx > plugin.bufSize
                    plugin.circIdx = 1;
                end
                if plugin.circFill < plugin.bufSize
                    plugin.circFill = plugin.circFill + 1;
                end
                if plugin.circFill == plugin.bufSize
                    idxs = mod((plugin.circIdx-1:plugin.circIdx+plugin.bufSize-2), plugin.bufSize) + 1;
                    frame = plugin.circBuf(idxs);
                    enh = enhanceSpeech(frame, plugin.fsOrig/plugin.dsFactor);
                    enh_ds = [enh_ds; enh];
                    plugin.circFill = 0;
                end
            end
            if isempty(enh_ds)
                y = double(resample(x_ds, plugin.dsFactor, 1));
            else
                y = double(resample(enh_ds, plugin.dsFactor, 1));
            end
            y = y(:);
            % === Mixing enhanced speech onto original (mono) signal ===
            yPad = zeros(N,1,'like',in);
            M = min(length(y), N);
            yPad(1:M) = y(1:M);
            % Optionally: user-facing control could be a gain for yPad

            % === Stereo output: process gating, EQ, etc. per channel, then add enhanced speech ===
            out = zeros(N,nCh,'like',in);
            for ch = 1:nCh
                out(:,ch) = in(:,ch) .* gainVec;
            end
            % Comb filter
            Ncomb = plugin.combDelaySamples;
            for ch = 1:min(nCh,2)
                for n = 1:N
                    delayed    = plugin.combBuffer(plugin.combIdx(ch), ch);
                    out(n,ch) = (1 - db2mag(plugin.combAmount)) * out(n,ch) - db2mag(plugin.combAmount) * delayed;
                    plugin.combBuffer(plugin.combIdx(ch), ch) = out(n,ch);
                    plugin.combIdx(ch) = plugin.combIdx(ch) + 1;
                    if plugin.combIdx(ch) > Ncomb, plugin.combIdx(ch) = 1; end
                end
            end
            [plosiveBand, lowBand, sillyBand, highBand] = plugin.crossover(out(:,1:2));
            ds = (rms(abs(sillyBand))) * -24;
            if ds > 0
                ds = 0;
            end
            dp = rms(abs(plosiveBand)) * -5;
            plugin.mPEQ.PeakGains = [dp(1), plugin.lmBoost_G, plugin.hmBoost_G, ds(1)];
            eqOut = plugin.mPEQ(out(:,1:2));
            % === Crossfade smoothing at buffer edge (specifically for speech enhancer) ===
            if N > 31
                if plugin.isFirstBuffer
                    % nothing to blend
                else
                    win = hann(2*plugin.xfadeLength, 'periodic');
                    fadeOut = win(1:plugin.xfadeLength);
                    fadeIn  = win(plugin.xfadeLength+1:end);
                    len = min(plugin.xfadeLength, N);
                    for ch = 1:size(eqOut,2)
                        yPad(1:len) = plugin.tailBuffer(end-len+1:end) .* fadeOut(end-len+1:end) + ...
                            yPad(1:len) .* fadeIn(1:len);
                    end
                end
                if N >= plugin.xfadeLength
                    plugin.tailBuffer = yPad(end-plugin.xfadeLength+1:end, 1);
                else
                    plugin.tailBuffer = yPad(:,1);
                end
            end
            % === Add enhanced speech (mono) to both channels ===
            if strcmp(plugin.ToggleEnhance, 'On')
                for ch = 1:nCh
                    eqOut(:,ch) = eqOut(:,ch) + yPad * db2mag(plugin.EnhanceLevel - 6);
                end
            end
            plugin.isFirstBuffer = false;
            % === Compressor Stage ===
            compOut  = zeros(N, nCh, 'like', in);
            for ch = 1:nCh
                compOut(:,ch) = plugin.Compressor(eqOut(:,ch));
                if strcmp(plugin.ToggleLimiter, 'On')
                    compOut(:,ch) = plugin.Limiter(compOut(:,ch));
                end
            end
            % === Output ===
            out = compOut;
            % Visualization buffer update
            newAudio = inM(:);
            newGate  = env(:);
            L = numel(newAudio);
            if L < plugin.historyLen
                plugin.audioHistory = [plugin.audioHistory(L+1:end); newAudio];
                plugin.gateHistory  = [plugin.gateHistory(L+1:end);  newGate];
            else
                plugin.audioHistory = newAudio(end-plugin.historyLen+1:end);
                plugin.gateHistory  = newGate(end-plugin.historyLen+1:end);
            end
        end

        function updateRatio(plugin)
            plugin.Compressor.Ratio  = plugin.Ratio;
        end
    end

    methods
        function set.Ratio(plugin,val)
            plugin.Ratio = val;
            plugin.updateRatio;
        end

        function visualize(plugin)
            figTag = 'VoiceSuiteMBComp Visualization';
            fig = findall(0,'Type','Figure','Tag',figTag);
            if isempty(fig) || ~isvalid(fig)
                fig = figure('Name','VoiceSuite Multi-Band Visualization', ...
                    'Tag',figTag,'NumberTitle','off');
            else
                figure(fig);
            end
            clf(fig);
            audio = plugin.audioHistory;
            env   = plugin.gateHistory;
            t = linspace(-plugin.historyLen,0,plugin.historyLen);
            probThreshold = 0.75;
            openMask = env >= probThreshold;
            speechAudio    = abs(audio);
            speechAudio(~openMask) = NaN;
            nonSpeechAudio = abs(audio);
            nonSpeechAudio(openMask) = NaN;
            area(t, nonSpeechAudio, 'FaceColor',[0.7,0.7,0.7],'EdgeColor','none','BaseValue',0);
            hold on;
            area(t, speechAudio,   'FaceColor',[0.3,0.3,0.8],'EdgeColor','none','BaseValue',0);
            plot(t, audio, 'k','LineWidth',1);
            plot(t, env,   'r','LineWidth',1);
            xlabel('Samples (relative)'); ylabel('Amplitude / Gate');
            title('Gated Audio & Envelope');
            ylim([-1 1]); xlim([-plugin.historyLen 0]); grid on;
            legend({'Closed','Open','Audio','Envelope'},'Location','northeast');
            drawnow limitrate;
        end
    end
end
