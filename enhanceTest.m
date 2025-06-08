classdef enhanceTest < audioPlugin & matlab.System
    properties (Constant)
        PluginInterface = audioPluginInterface('PluginName', 'SR Enhanced Speech (Quick)');
        bufSize  = 1024;       % Buffer size at low rate
    end

    properties (Access=private)
        circBuf
        circIdx
        circFill
        outputBuffer
        fsOrig
        dsFactor = 6;         % Downsample by 6 (e.g., from 48kHz to 8kHz)
        lastOut
        xfadeLength = 16;
        tailBuffer
        isFirstBuffer = true;
    end

    methods
        function plugin = enhanceTest()
            plugin.circBuf = zeros(plugin.bufSize,1);
            plugin.circIdx = 1;
            plugin.circFill = 0;
            plugin.outputBuffer = [];
            plugin.fsOrig = [];
            plugin.tailBuffer = zeros(plugin.xfadeLength,1);
        end
    end

    methods (Access=protected)
        function resetImpl(plugin)
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
            if size(in,2) > 1
                inM = mean(in,2); % Mono only
            end
            
            % b_ds = fir1(64, 3800/(plugin.fsOrig/2)); % 64 taps, cutoff at 3.8kHz
            % b_us = fir1(64, 18000/(plugin.fsOrig/2));
            % x_filt = filter(b_ds, 1, inM);
            x_ds = resample(inM, 1, plugin.dsFactor);

            %--- Fill buffer and process when full ---
            n_ds = length(x_ds);
            enh_ds = [];  % output at downsampled rate
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

                    %--- Enhance at 8kHz ---
                    enh = enhanceSpeech(frame, plugin.fsOrig/plugin.dsFactor);

                    %--- Collect output
                    enh_ds = [enh_ds; enh];
                    plugin.circFill = 0;
                end
            end

            %--- Crude upsample (zero-insertion) ---
            if isempty(enh_ds)
                % Pass-through (but still need to match size)
                y = double(resample(x_ds, plugin.dsFactor, 1)); % Just for codegen shape
            else
                y = double(resample(enh_ds, plugin.dsFactor, 1));
            end
            % y = filter(b_us, 1, y); % Use the same b as above, but cutoff now is fsOrig/2

            %--- Always output exactly N samples (codegen requirement) ---
            out = zeros(N,nCh,'like',in);
            M = min(length(y), N);
            y = y(:); % Ensure column orientation     


            for ch = 1:nCh
            % if ~isempty(plugin.lastOut)
            %     out(1,ch) = 0.5*plugin.lastOut + 0.5*y(1);
            % else
            %     out(1,ch) = y(1);
            % end
            %     out(2:M, ch) = y(2:M);
                out(1:M, ch) = y(1:M);
            end
            % plugin.lastOut = out(end,1);
            if N > 31
                if plugin.isFirstBuffer
                    % nothing to blend
                else

                    win = hann(2*plugin.xfadeLength, 'periodic');
                    fadeOut = win(1:plugin.xfadeLength);
                    fadeIn  = win(plugin.xfadeLength+1:end);
                    len = min(plugin.xfadeLength, N);
                    for ch = 1:size(in,2)
                        out(1:len, ch) = plugin.tailBuffer(end-len+1:end) .* fadeOut(end-len+1:end) + ...
                                         out(1:len, ch) .* fadeIn(1:len);
                    end
                end
            
                % Save tail for next call
                if N >= plugin.xfadeLength
                    plugin.tailBuffer = out(end-plugin.xfadeLength+1:end, 1);
                else
                    plugin.tailBuffer = out(:,1);
                end
            end
            plugin.isFirstBuffer = false;
            % No outputBuffer logic, because upsample always produces at least as many samples as input, unless input is very short

        end
    end
end
