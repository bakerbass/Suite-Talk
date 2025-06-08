classdef voiceSuite < audioPlugin & matlab.System
    % Combined VoiceGate and 3-band Compressor plugin
    % Voice activity detection and gating followed by a compressor

    properties
        % VoiceGate parameters
        AttackTime     = 0.01        % Attack smoothing time (s)
        ReleaseTime    = 0.35        % Release smoothing time (s)
        ClosedGain_dB  = -60         % Attenuation when gate is closed (dB)

        % Compressor parameters
        Ratio          = 4           % Compression ratio

        combAmount     = -13
    end

    properties (Constant)
        PluginInterface = audioPluginInterface( ...
            ...% VoiceGate controls
            audioPluginParameter('AttackTime', DisplayName='Attack Time', Mapping={'log',0.001,1}), ...
            audioPluginParameter('ReleaseTime', DisplayName='Release Time', Mapping={'log',0.001,1}), ...
            audioPluginParameter('ClosedGain_dB', DisplayName='Gate Floor (dB)', Mapping={'lin',-120,-20}), ...
            audioPluginParameter('combAmount', DisplayName='Hum reducer amount (dB)', Mapping={'lin',-24,-6}), ...
            ...% Ratio control
            audioPluginParameter('Ratio', DisplayName='Compression Ratio',Mapping={'lin',1,10}), ...
            ...% Plugin name
            'PluginName','VoiceSuite Enhancer' ...
        );
        FFTLength  = 2048    % Buffer length for VAD
    end

    properties (Access=private)
        % VoiceGate internal state
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

        % Compressor internal state
        SampleRate
        crossover  % crossoverFilter object
        
        Compressor  = compressor;

        mPEQ
        hpf_Fc = 90 % rumble blocking high-pass filter
        hpf_Slope = 24 % steep slope
        dp_Q = 0.5
        dp_Fc = 60
        lmBoost_Fc = 600 % low mid speech range enhancment
        lmBoost_Q = 0.9
        lmBoost_G = 3
        hmBoost_Fc = 3000 % high mid speech range enhancement
        hmBoost_Q = 0.6
        hmBoost_G = 4
        ds_Q = 0.4 % de-esser dyn-eq Q
        ds_maxG = 0 % highest de-ess gain
        ds_minG = -3 % lowest de-ess gain
        ds_Fc = 7500 % center of de-ess bell
        
        FcLow = 6300 % low end of de-ess detector
        FcHigh = 9800 % high end of de-ess detector

        % Comb filter state (notch at 60Hz and harmonics)
        combDelaySamples
        combBuffer    % delay line
        combIdx       % write index per channel

    end

    methods
        function plugin = voiceSuite()
            plugin.SampleRate = 44100;
            % Constructor: initialize VAD, buffers, and compressors
            plugin.vadObj       = voiceActivityDetector('FFTLength', plugin.FFTLength);
            plugin.ring         = zeros(plugin.FFTLength,1);
            plugin.frameBuffer  = zeros(plugin.FFTLength,1);
            plugin.gateMask     = ones(plugin.FFTLength,1,'single');
            plugin.audioHistory = zeros(plugin.historyLen,1);
            plugin.gateHistory  = zeros(plugin.historyLen,1);

            % Multiband compressor setup
            plugin.crossover    = crossoverFilter;
            plugin.crossover.NumCrossovers = 3;
            
            plugin.Compressor = compressor;

            plugin.mPEQ = multibandParametricEQ('Oversample',true, ...
                'NumEQBands', 4, ...
                'HasHighpassFilter', true, ...
                'HighpassCutoff', plugin.hpf_Fc, ...
                'HighpassSlope', plugin.hpf_Slope, ...
                'Frequencies', [plugin.dp_Fc, plugin.lmBoost_Fc, plugin.hmBoost_Fc, plugin.ds_Fc], ...
                'QualityFactors', [plugin.dp_Q, plugin.lmBoost_Q, plugin.hmBoost_Q, plugin.ds_Q], ...
                'PeakGains', [0, plugin.lmBoost_G, plugin.hmBoost_G, plugin.ds_maxG]);
        end
    end

    methods (Access=protected)
        function resetImpl(plugin)
            % Reset VoiceGate state
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

            % Reset and configure compressor
            plugin.SampleRate = getSampleRate(plugin);
            plugin.crossover.SampleRate = plugin.SampleRate;
            plugin.crossover.CrossoverFrequencies = [150, plugin.FcLow, plugin.FcHigh];
            % reset(plugin.Compressor);


            plugin.Compressor.SampleRate  = plugin.SampleRate;
            plugin.Compressor.Threshold   = -10;
            plugin.Compressor.Ratio       = plugin.Ratio;

            reset(plugin.mPEQ);

            plugin.combDelaySamples = round(plugin.SampleRate / 60);
            plugin.combBuffer       = zeros(plugin.combDelaySamples, 2);
            plugin.combIdx          = ones(1,2);
        end

        function out = stepImpl(plugin, in)
            [frameLen, nCh] = size(in);

            %--- VoiceGate Processing ---
            % Prepare mono input for VAD
            if nCh == 1
                inMono = in;
            else
                inMono = mean(in,2);
            end
            % Fill ring buffer
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
            % Run VAD when buffer is full
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
            % Envelope smoothing
            fs    = getSampleRate(plugin);
            aAtt  = exp(-1/(plugin.AttackTime*fs));
            aRel  = exp(-1/(plugin.ReleaseTime*fs));
            closed = db2mag(plugin.ClosedGain_dB);
            g     = plugin.envState;
            env   = zeros(frameLen,1,'like',in);
            gainVec = zeros(frameLen,1,'like',in);
            for n = 1:frameLen
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
            % Apply gating
            gatedOut = zeros(size(in),'like',in);
            for ch = 1:nCh
                gatedOut(:,ch) = in(:,ch) .* gainVec;
            end
            %--- Comb Filter for 60Hz notch ---
            combOut = zeros(size(gatedOut),'like',gatedOut);
            N = plugin.combDelaySamples;
            for ch = 1:min(nCh,2)
                for n = 1:frameLen
                    delayed    = plugin.combBuffer(plugin.combIdx(ch), ch);
                    combOut(n,ch) = (1 - db2mag(plugin.combAmount)) * gatedOut(n,ch) - db2mag(plugin.combAmount) * delayed;
                    plugin.combBuffer(plugin.combIdx(ch), ch) = gatedOut(n,ch);
                    plugin.combIdx(ch) = plugin.combIdx(ch) + 1;
                    if plugin.combIdx(ch) > N, plugin.combIdx(ch) = 1; end
                end
            end
            %--- Silibance Detection ---

            [plosiveBand, lowBand, sillyBand, highBand] = plugin.crossover(gatedOut(:,1:2));
            ds = (rms(abs(sillyBand))) * -24;
            if ds > 0
                ds = 0;
            end
            dp = rms(abs(plosiveBand)) * -5;
            plugin.mPEQ.PeakGains = [dp(1), plugin.lmBoost_G, plugin.hmBoost_G, ds(1)];
            out = plugin.mPEQ(combOut(:,1:2));
            %--- Visualization buffer update ---
            newAudio = inMono(:);
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
            % Plot audio waveform and gate state history
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
