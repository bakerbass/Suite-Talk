classdef vadnet_template < audioPlugin & matlab.System
    % vadnet_template
    % - Applies Voice Activity Detection (VAD) using a fixed-size ring buffer.
    % - Speech frames are gated based on VAD output and smoothed envelope.
    % - User parameters: Attack, Release, Gate Floor (dB).
    % - Includes visualization method.

    properties
        AttackTime    = 0.01        % Attack smoothing time (seconds)
        ReleaseTime   = 0.05        % Release smoothing time (seconds)
        ClosedGain_dB = -80         % Attenuation when gate is closed (dB)
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
                Mapping = {'lin', -120, -20}), ...
            'PluginName', 'My Vocal Enhancer');
        FFTLength = 2048
    end

    properties (Access = private)
        vadObj               % System object for VAD
        ring                 % Ring buffer [8192 x 1] (mono VAD)
        frameBuffer          % [8192 x 1] codegen-safe buffer for VAD input
        ringIdx = 1          % Next write index
        gateMask             % Gating mask for the last 8192 samples
        gateIdx = 1          % Index through gateMask for output
        bufferFill = 0       % Number of valid samples in the ring

        envState = 0         % Last gate envelope value

        % Visualization buffers
        historyLen = 4096           % Number of samples to store for display
        audioHistory                % Last N samples (mono) for display
        gateHistory                 % Last N samples (gate state) for display
    end

    methods
        function plugin = vadnet_template()
            % Constructor: init ring buffer, VAD, and state
            plugin.vadObj = voiceActivityDetector( ...
                'FFTLength', plugin.FFTLength);
            plugin.ring = zeros(plugin.FFTLength, 1);
            plugin.frameBuffer = zeros(plugin.FFTLength, 1);
            plugin.gateMask = ones(plugin.FFTLength, 1, 'single');
            plugin.gateIdx = 1;
            plugin.ringIdx = 1;
            plugin.bufferFill = 0;
            plugin.envState = 0;

            % Visualization buffers
            plugin.audioHistory = zeros(plugin.historyLen, 1);
            plugin.gateHistory  = zeros(plugin.historyLen, 1);
        end
    end

    methods (Access = protected)
        function resetImpl(plugin)
            reset(plugin.vadObj);
            plugin.ring(:) = 0;
            plugin.frameBuffer(:) = 0;
            plugin.gateMask(:) = 1;
            plugin.gateIdx = 1;
            plugin.ringIdx = 1;
            plugin.bufferFill = 0;
            plugin.envState = 0;

            plugin.audioHistory(:) = 0;
            plugin.gateHistory(:) = 1;
        end

        function out = stepImpl(plugin, in)
            [frameLen, nCh] = size(in);
            out = zeros(size(in), 'like', in);

            % Prepare mono for VAD
            if nCh == 1
                inMono = in;
            else
                inMono = mean(in, 2);
            end

            % === Fill ring buffer with input samples ===
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

            % === Run VAD only when ring buffer is full ===
            runVAD = false;
            if plugin.bufferFill == plugin.FFTLength
                runVAD = true;
            end

            if runVAD
                % Codegen-safe copy of ring buffer into frameBuffer
                for k = 1:plugin.FFTLength
                    ringIdxLogical = mod(plugin.ringIdx + k - 2, plugin.FFTLength) + 1;
                    plugin.frameBuffer(k) = plugin.ring(ringIdxLogical);
                end

                [prob, ~] = plugin.vadObj(plugin.frameBuffer);
                probThreshold = 0.75;
                if isscalar(prob)
                    plugin.gateMask = repmat(single(prob > probThreshold), plugin.FFTLength, 1);
                else
                    plugin.gateMask = single(prob > probThreshold);
                    if length(plugin.gateMask) ~= plugin.FFTLength
                        plugin.gateMask = repmat(single(mean(plugin.gateMask) > probThreshold), plugin.FFTLength, 1);
                    end
                end
                plugin.gateIdx = 1;
            end

            % === Envelope gating with attack, release, gain floor ===
            fs = getSampleRate(plugin);
            aAtt = exp(-1 / (plugin.AttackTime  * fs));
            aRel = exp(-1 / (plugin.ReleaseTime * fs));
            closed = db2mag(plugin.ClosedGain_dB);

            env = zeros(frameLen,1,'like',in);
            g = plugin.envState;

            gateVec = zeros(frameLen,1);

            for n = 1:frameLen
                % Step through gateMask sample by sample
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

                plugin.gateIdx = plugin.gateIdx + 1;
                if plugin.gateIdx > plugin.FFTLength
                    plugin.gateIdx = 1;
                end
            end
            plugin.envState = g;

            % === Apply gain floor to envelope ===
            gainVec = closed + (1 - closed) * env;
            for ch = 1:nCh
                out(:,ch) = in(:,ch) .* gainVec;
                % out(:,ch) = enhanceSpeech(out(:,ch), fs);
            end

            % === Update visualization buffers ===
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
            % Plot audio waveform and gate state history

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

            % Masked areas for gate state
            openMask = env >= probThreshold;
            speechAudio    = abs(audio);
            speechAudio(~openMask) = NaN;

            nonSpeechAudio = abs(audio);
            nonSpeechAudio(openMask) = NaN;

            % Plot gated region (gray) and open region (blue)
            area(t, nonSpeechAudio, ...
                 'FaceColor', [0.7, 0.7, 0.7], 'EdgeColor', 'none', 'BaseValue', 0);
            hold on;
            area(t, speechAudio, ...
                 'FaceColor', [0.3 0.3 0.8], 'EdgeColor', 'none', 'BaseValue', 0);

            % Plot waveform (black)
            plot(t, audio, 'k', 'LineWidth', 1);

            % Plot envelope as red line (optional)
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
