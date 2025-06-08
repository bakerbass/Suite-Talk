classdef VoiceGate < audioPlugin
    % VoiceGate – passes speech detected by VADNet and mutes everything else.
    % Tunable parameters:
    %   AttackTime     – attack smoothing time (0.001–1 s)
    %   ReleaseTime    – release smoothing time (0.001–1 s)
    %   ClosedGain_dB  – attenuation level when gate is closed

    properties
        AttackTime    = 0.01
        ReleaseTime   = 0.05
        ClosedGain_dB = -80
    end
    
    properties (Constant)
        PluginInterface = audioPluginInterface( ...
            audioPluginParameter("AttackTime", ...
                DisplayName = "Attack Time", ...
                Mapping = {'log', 0.001, 1}), ...
            audioPluginParameter("ReleaseTime", ...
                DisplayName = "Release Time", ...
                Mapping = {'log', 0.001, 1}), ...
            audioPluginParameter("ClosedGain_dB", ...
                DisplayName = "Gate Floor (dB)", ...
                Mapping = {'lin', -120, -20}) ...
        );
    end
    
    properties (Access = private)
        vnet
        ring = zeros(8192, 2)
        startIdx       = 1
        stopIdx       = 8193
        samplesSinceHop = 0
        envState    = 0
        fsCached    = 48000
        closedLin
        vadFrame = 8192;   % analysis window length (samples)
        vadHop   = 4096;   % hop length (samples)
        prevIsSpeech = false;

        gateFrame   % stores sample-wise gate vector from last VAD hop
        gateIdx     = 1; % sliding index through gateFrame

        lookaheadSamples = 2048;    % e.g., 40 ms @ 48 kHz
        delayBuf = zeros(2048, 2);                        % [lookaheadSamples x nCh] audio delay buffer
        delayIdx = 1;                   % circular buffer index

        % visualize properties
        historyLen = 4096   % Number of samples to show in the plot
        audioHistory            % Stores input waveform
        gateHistory             % Stores isSpeech (1 or 0)


    end
    
    methods
        function plugin = VoiceGate()
            % audio
            plugin.vnet      = audioPretrainedNetwork("vadnet");
            plugin.closedLin = db2mag(plugin.ClosedGain_dB);
            % visualize
            plugin.audioHistory = zeros(plugin.historyLen, 1);
            plugin.gateHistory  = zeros(plugin.historyLen, 1);
            setLatencyInSamples(plugin, plugin.lookaheadSamples); % might need to add a callback for parameterized lookahead
        end
            
        function out = process(plugin, in)
            fs = plugin.getSampleRate();
            [numSamp, nCh] = size(in);
            out = zeros(size(in), 'like', in);
        
            % Recalculate smoothing coefficients
            aAtt   = exp(-1 / (plugin.AttackTime  * fs));
            aRel   = exp(-1 / (plugin.ReleaseTime * fs));
            plugin.closedLin = db2mag(plugin.ClosedGain_dB);
            closed = plugin.closedLin;
        
            % Allocate buffers if needed
            if isempty(plugin.ring) || size(plugin.ring, 2) ~= nCh
                plugin.ring = zeros(plugin.vadFrame, nCh);
                plugin.startIdx = 1;
                plugin.samplesSinceHop = 0;
                plugin.gateFrame = zeros(plugin.vadFrame, 1);
                plugin.gateIdx = 1;
            end
            if isempty(plugin.delayBuf) || size(plugin.delayBuf, 2) ~= nCh
                plugin.delayBuf = zeros(plugin.lookaheadSamples, nCh);
                plugin.delayIdx = 1;
            end
        
            % === Fill VAD Ring Buffer ===
            for ch = 1:nCh
                for n = 1:numSamp
                    plugin.ring(plugin.startIdx, ch) = in(n, ch);
                    plugin.startIdx = plugin.startIdx + 1;
                    if plugin.startIdx > plugin.vadFrame
                        plugin.startIdx = 1;
                    end
                end
            end
        
            % === Update hop counter ===
            plugin.samplesSinceHop = plugin.samplesSinceHop + numSamp;
        
            % === Run VAD if needed ===
            if plugin.samplesSinceHop >= plugin.vadHop
                stopIdx_ = mod(plugin.startIdx - 2, plugin.vadFrame) + 1;
                startIdx_ = mod(stopIdx_ - plugin.vadFrame, plugin.vadFrame) + 1;
        
                if stopIdx_ >= startIdx_
                    frame = plugin.ring(startIdx_:stopIdx_, 1);
                else
                    frame = [plugin.ring(startIdx_:end, 1); plugin.ring(1:stopIdx_, 1)];
                end

                feats = dlarray(vadnetPreprocess(frame, fs));
                probs = predict(plugin.vnet, feats);
                probs = extractdata(probs);
                roi = vadnetPostprocess(frame, fs, probs);
        
                gateMaskFrame = false(plugin.vadFrame, 1);
                for k = 1:size(roi,1)
                    s = max(1, roi(k,1));
                    e = min(plugin.vadFrame, roi(k,2));
                    gateMaskFrame(s:e) = true;
                end
        
                plugin.gateFrame = gateMaskFrame;
                plugin.gateIdx = 1;
                plugin.samplesSinceHop = 0;
            end
        
            % === Apply smoothed gating ===
            env = zeros(numSamp, 1);
            g   = plugin.envState;
        
            for n = 1:numSamp
                if isempty(plugin.gateFrame)
                    tgt = 0;
                else
                    idx = mod(plugin.gateIdx - 1, length(plugin.gateFrame)) + 1;
                    tgt = plugin.gateFrame(idx);
                    plugin.gateIdx = plugin.gateIdx + 1;
                end
        
                if tgt > g
                    g = aAtt * g + (1 - aAtt) * tgt;
                else
                    g = aRel * g + (1 - aRel) * tgt;
                end
                env(n) = g;
            end
        
            plugin.envState = g;
        
            % === Delay audio for lookahead ===
            delayed = zeros(size(in));
            for ch = 1:nCh
                for n = 1:numSamp
                    plugin.delayBuf(plugin.delayIdx, ch) = in(n, ch);
                    readIdx = mod(plugin.delayIdx - plugin.lookaheadSamples - 1, ...
                                  plugin.lookaheadSamples) + 1;
                    delayed(n, ch) = plugin.delayBuf(readIdx, ch);
                end
            end
            plugin.delayIdx = mod(plugin.delayIdx + numSamp - 1, plugin.lookaheadSamples) + 1;
        
            % === Apply gain to delayed audio ===
            gainVec = closed + (1 - closed) * env;
            out = delayed .* gainVec;
        
            % === Update visualizer ===
            audioMono = mean(in, 2);   % use original (non-delayed) input for display
            gateVec   = env > 0.5;     % binary gate history
        
            plugin.audioHistory = [plugin.audioHistory(numel(audioMono)+1:end); audioMono];
            plugin.gateHistory  = [plugin.gateHistory(numel(audioMono)+1:end);  gateVec];
        end

        function visualize(plugin)
            % Reuse figure if already exists
            figTag = 'VoiceGateVisualization';
            fig = findall(0, 'Type', 'Figure', 'Tag', figTag);
            if isempty(fig) || ~isvalid(fig)
                fig = figure('Name', 'VoiceGate - Real-Time Visualization', ...
                             'Tag', figTag, 'NumberTitle', 'off');
            else
                figure(fig);
            end
            clf(fig);
        
            % Guard against unfilled buffer
            if length(plugin.audioHistory) ~= plugin.historyLen
                title('Waiting for data...');
                return
            end
        
            t = linspace(-1, 0, plugin.historyLen);
            audio = plugin.audioHistory;
            gate  = plugin.gateHistory;
            % Mask audio using NaNs to match size of t
            speechAudio    = abs(audio);
            speechAudio(gate == 0) = NaN;
            
            nonSpeechAudio = abs(audio);
            nonSpeechAudio(gate == 1) = NaN;
            
            % Plot filled areas using masked vectors
            area(t, nonSpeechAudio, ...
                 'FaceColor', [0.7, 0.7, 0.7], 'EdgeColor', 'none', 'BaseValue', 0);
            hold on;
            
            area(t, speechAudio, ...
                 'FaceColor', [0.3 0.3 0.8], 'EdgeColor', 'none', 'BaseValue', 0);

            plot(t, abs(audio), 'k', 'LineWidth', 0.8);
        
            xlabel('Time (s)');
            ylabel('Amplitude');
            title('Gate Activity (Gray = Closed, Blue = Open)');
            ylim([0 1]);
            xlim([-1 0]);
            grid on;
            drawnow limitrate;
        end

    end
end
