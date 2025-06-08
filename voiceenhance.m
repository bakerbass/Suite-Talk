classdef voiceenhance < audioPlugin & matlab.System
    % vadnet_template
    % - Voice Activity Detection (VAD) sidechains gating of enhanced speech (stereo).
    % - Uses ring buffer (codegen-safe) for both VAD and enhanceSpeech.
    % - User params: Attack, Release, Gate Floor (dB).
    % - Internal: probThreshold (VAD probability threshold).

    properties
        AttackTime    = 0.01
        ReleaseTime   = 0.05
        ClosedGain_dB = 0
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
                Mapping = {'lin', -120, 0}), ...
            'PluginName', 'My Vocal Enhancer');
        FFTLength = 4096
    end

    properties (Access = private)
        vadObj               % System object for VAD
        ring                 % Stereo ring buffer [8192 x 2]
        frameBuffer          % [8192 x 2] fixed buffer for enhanceSpeech input
        vadFrameBuffer       % [8192 x 1] fixed buffer for VAD input (mono)
        ringIdx = 1          % Next write index
        gateMask             % Gating mask for the last 8192 samples
        gateIdx = 1          % Index through gateMask for output
        bufferFill = 0       % Number of valid samples in the ring

        envState = 0         % Last gate envelope value
        probThreshold = 0.6  % Internal VAD threshold for "speech present" (tunable in code)

        % Visualization buffers
        historyLen = 2048
        audioHistory
        gateHistory
    end

    methods
        function plugin = voiceenhance()
            plugin.vadObj = voiceActivityDetector( ...
                'FFTLength', plugin.FFTLength);
            plugin.ring = zeros(plugin.FFTLength, 2);
            plugin.frameBuffer = zeros(plugin.FFTLength, 2);
            plugin.vadFrameBuffer = zeros(plugin.FFTLength, 1);
            plugin.gateMask = ones(plugin.FFTLength, 1, 'single');
            plugin.gateIdx = 1;
            plugin.ringIdx = 1;
            plugin.bufferFill = 0;
            plugin.envState = 0;
            % Use MATLAB's built-in enhanceSpeech (assume function call)
            plugin.audioHistory = zeros(plugin.historyLen, 1);
            plugin.gateHistory  = zeros(plugin.historyLen, 1);
        end
    end

    methods (Access = protected)
        function resetImpl(plugin)
            reset(plugin.vadObj);
            plugin.ring(:) = 0;
            plugin.frameBuffer(:) = 0;
            plugin.vadFrameBuffer(:) = 0;
            plugin.gateMask(:) = 1;
            plugin.gateIdx = 1;
            plugin.ringIdx = 1;
            plugin.bufferFill = 0;
            plugin.envState = 0;
            plugin.audioHistory(:) = 0;
            plugin.gateHistory(:) = 1;
        end

        function out = stepImpl(plugin, in)
            origLen = size(in,1);
            origFs = getSampleRate(plugin);
            fs = origFs;            
            targetFs = 192000;
            [frameLen, nCh] = size(in);
            % If sample rate is above 48kHz, resample input to 48k
            resampled = false;
            if fs > targetFs
                outLen = size(in,1); % <-- always output this many frames
                % Compute the target number of frames after resample:
                resampLen = round(outLen * targetFs / fs);
                in_resampled = zeros(resampLen, size(in,2), 'like', in);
                for ch = 1:size(in,2)
                    resamp = resample(in(:,ch), targetFs, fs);
                    if length(resamp) >= resampLen
                        in_resampled(:,ch) = resamp(1:resampLen);
                    else
                        in_resampled(:,ch) = [resamp; zeros(resampLen-length(resamp),1)];
                    end
                end
                % Now, resample *back up* to original block size so output shape matches DAW/host
                in_block = zeros(outLen, size(in,2), 'like', in);
                for ch = 1:size(in,2)
                    resamp_up = resample(in_resampled(:,ch), fs, targetFs);
                    if isempty(resamp_up)
                        in_block(:,ch) = zeros(outLen,1,'like',in);
                    else
                        % Force column vector shape for safe concatenation
                        resamp_up = resamp_up(:);
                        if length(resamp_up) >= outLen
                            in_block(:,ch) = resamp_up(1:outLen);
                        else
                            in_block(:,ch) = [resamp_up; zeros(outLen-length(resamp_up),1)];
                        end
                    end
                end
                fs = targetFs;   % all downstream code uses this new fs
                in = in_block;
                resampled = true;
            end

            % -- Stereo ring buffer fill --
            for n = 1:frameLen
                if nCh == 1
                    plugin.ring(plugin.ringIdx,1) = in(n,1);
                    plugin.ring(plugin.ringIdx,2) = in(n,1); % duplicate mono to both chans
                else
                    plugin.ring(plugin.ringIdx,1) = in(n,1);
                    plugin.ring(plugin.ringIdx,2) = in(n,2);
                end
                plugin.ringIdx = plugin.ringIdx + 1;
                if plugin.ringIdx > plugin.FFTLength
                    plugin.ringIdx = 1;
                end
                if plugin.bufferFill < plugin.FFTLength
                    plugin.bufferFill = plugin.bufferFill + 1;
                end
            end
        
            % -- VAD/enhanceSpeech runs only when ring buffer is full --
            runEnh = false;
            if plugin.bufferFill == plugin.FFTLength
                runEnh = true;
            end
        
            if runEnh
                % -- Prepare fixed-size buffers for VAD and enhanceSpeech (codegen safe) --
                for k = 1:plugin.FFTLength
                    ringIdxLogical = mod(plugin.ringIdx + k - 2, plugin.FFTLength) + 1;
                    % For enhanceSpeech (stereo)
                    plugin.frameBuffer(k,1) = plugin.ring(ringIdxLogical,1);
                    plugin.frameBuffer(k,2) = plugin.ring(ringIdxLogical,2);
                    % For VAD (mono sum/avg, from original signal)
                    plugin.vadFrameBuffer(k) = 0.5 * (plugin.ring(ringIdxLogical,1) + plugin.ring(ringIdxLogical,2));
                end
        
                % --- Voice Activity Detection on mono original ---
                [prob, ~] = plugin.vadObj(plugin.vadFrameBuffer);
        
                % --- Enhance speech for stereo ---
                enhanced = zeros(plugin.FFTLength, nCh, 'like', in);
                for ch = 1:nCh
                    enhanced(:,ch) = enhanceSpeech(plugin.frameBuffer(:,ch), fs);
                end
                % --- Compute gating mask from VAD ---
                threshold = plugin.probThreshold; % internal threshold
                if isscalar(prob)
                    plugin.gateMask = repmat(single(prob > threshold), plugin.FFTLength, 1);
                else
                    plugin.gateMask = single(prob > threshold);
                    if length(plugin.gateMask) ~= plugin.FFTLength
                        plugin.gateMask = repmat(single(mean(plugin.gateMask) > threshold), plugin.FFTLength, 1);
                    end
                end
        
                % Store enhanced signal for gating
                plugin.frameBuffer(:,:) = enhanced; % Reuse frameBuffer for storing enhanced audio
                plugin.gateIdx = 1;
            end
        
            % --- Envelope gating with attack, release, gain floor ---
            aAtt = exp(-1 / (plugin.AttackTime  * fs));
            aRel = exp(-1 / (plugin.ReleaseTime * fs));
            closed = db2mag(plugin.ClosedGain_dB);
        
            env = zeros(frameLen,1,'like',in);
            g = plugin.envState;
            gateVec = zeros(frameLen,1);
            out = zeros(frameLen,2,'like',in);
        
            for n = 1:frameLen
                idx = plugin.gateIdx;
                if idx > plugin.FFTLength
                    idx = 1;
                end
                tgt = double(plugin.gateMask(idx));
                if tgt > g
                    g = aAtt * g + (1 - aAtt) * tgt;
                else
                    g = aRel * g + (1 - aRel) * tgt;
                end
                env(n) = g;
                gateVec(n) = tgt;
        
                % --- Output: gate the enhanced speech ---
                for ch = 1:nCh
                    out(n,ch) = plugin.frameBuffer(idx,ch) * (closed + (1-closed)*g);
                end
                plugin.gateIdx = plugin.gateIdx + 1;
                if plugin.gateIdx > plugin.FFTLength
                    plugin.gateIdx = 1;
                end
            end
            plugin.envState = g;
            if resampled
                out_resampled = zeros(origLen, size(out,2), 'like', out);
                for ch = 1:size(out,2)
                    out_resamp = resample(out(:,ch), origFs, fs);
                    if length(out_resamp) >= origLen
                        out_resampled(:,ch) = out_resamp(1:origLen);
                    else
                        out_resampled(:,ch) = [out_resamp; zeros(origLen-length(out_resamp),1)];
                    end
                end
                out = out_resampled;   
            end
            % --- Visualization ---
            % Visualize envelope on original input (for user feedback)
            inMono = mean(in,2);
            newAudio = inMono(:);
            newGate = env(:);
            L = length(newAudio);
            if L < plugin.historyLen
                plugin.audioHistory = [plugin.audioHistory(L+1:end); newAudio];
                plugin.gateHistory  = [plugin.gateHistory(L+1:end);  newGate];
            else
                plugin.audioHistory = newAudio(end-plugin.historyLen+1:end);
                plugin.gateHistory  = newGate(end-plugin.historyLen+1:end);
            end
        end
    end

    methods
        function visualize(plugin)
            figTag = 'VADNetPluginVisualization';
            fig = findall(0, 'Type', 'Figure', 'Tag', figTag);
            if isempty(fig) || ~isvalid(fig)
                fig = figure('Name', 'VADNet VoiceGate Visualization', ...
                             'Tag', figTag, 'NumberTitle', 'off');
            else
                figure(fig);
            end
            clf(fig);

            audio = plugin.audioHistory;
            env   = plugin.gateHistory;
            t = linspace(-plugin.historyLen, 0, plugin.historyLen);

            openMask = env >= 0.5;
            speechAudio    = abs(audio);
            speechAudio(~openMask) = NaN;

            nonSpeechAudio = abs(audio);
            nonSpeechAudio(openMask) = NaN;

            area(t, nonSpeechAudio, ...
                 'FaceColor', [0.7, 0.7, 0.7], 'EdgeColor', 'none', 'BaseValue', 0);
            hold on;
            area(t, speechAudio, ...
                 'FaceColor', [0.3 0.3 0.8], 'EdgeColor', 'none', 'BaseValue', 0);

            plot(t, audio, 'k', 'LineWidth', 1);
            plot(t, env, 'r', 'LineWidth', 1);

            xlabel('Samples (relative)');
            ylabel('Amplitude / Gate');
            title('VoiceGate: Audio (Black), Gate State (Gray/Blue), Envelope (Red)');
            ylim([-1 1]);
            xlim([-plugin.historyLen 0]);
            grid on;
            legend({'Gated (Closed)', 'Open', 'Audio', 'Envelope'}, 'Location', 'northeast');
            drawnow limitrate;
        end
    end
end
