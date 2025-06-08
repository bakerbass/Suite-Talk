classdef MultiBandCompressor < audioPlugin & matlab.System
    % MultiBandCompressor: 3-band compressor with variable cutoffs

    properties
        % User-adjustable crossover frequencies
        FcLow = 200;    % Hz
        FcHigh = 2000;  % Hz

        % Compression thresholds per band (dB)
        LowThreshold = -20;
        MidThreshold = -20;
        HighThreshold = -20;

        % Compression ratio (same for all bands)
        Ratio = 4;
    end

    properties (Access = private)
        SampleRate = 44100;
        crossover = crossoverFilter;

        % Compressors
        LowCompressor = compressor;
        MidCompressor = compressor;
        HighCompressor = compressor;
        % Crossover filter

    end

    properties (Constant)
        PluginInterface = audioPluginInterface( ...
            audioPluginParameter('FcLow', ...
                'DisplayName', 'Low Cutoff', ...
                'Mapping', {'log', 20, 1000}, ...
                'Label', 'Hz'), ...
            audioPluginParameter('FcHigh', ...
                'DisplayName', 'High Cutoff', ...
                'Mapping', {'log', 1000, 10000}, ...
                'Label', 'Hz'), ...
            audioPluginParameter('LowThreshold', ...
                'DisplayName', 'Low Threshold', ...
                'Mapping', {'lin', -60, 0}, ...
                'Label', 'dB'), ...
            audioPluginParameter('MidThreshold', ...
                'DisplayName', 'Mid Threshold', ...
                'Mapping', {'lin', -60, 0}, ...
                'Label', 'dB'), ...
            audioPluginParameter('HighThreshold', ...
                'DisplayName', 'High Threshold', ...
                'Mapping', {'lin', -60, 0}, ...
                'Label', 'dB'), ...
            audioPluginParameter('Ratio', ...
                'DisplayName', 'Compression Ratio', ...
                'Mapping', {'lin', 1, 10}) ...
            );

    end

    methods
        function plugin = MultiBandCompressor()
            % Constructor: initialize compressors
        plugin.crossover = crossoverFilter;
        plugin.crossover.NumCrossovers = 2;
        % Compressors
        plugin.LowCompressor = compressor;
        plugin.MidCompressor = compressor;
        plugin.HighCompressor = compressor;
        end
    end

    methods (Access = protected)
        function out = stepImpl(plugin, in)
            % Split input into bands
            % if numChannel > 1
            [lowBand, midBand, highBand] = plugin.crossover(in(:,1:2));

            % Apply compression to each band
            lowBand = plugin.LowCompressor(lowBand(:,1:2));
            midBand = plugin.MidCompressor(midBand(:,1:2));
            highBand = plugin.HighCompressor(highBand(:,1:2));

            % Sum bands
            out = lowBand + midBand + highBand;
        end

        function resetImpl(plugin)
            % Reset Sample Rate
            sr = plugin.getSampleRate();
            plugin.SampleRate = sr;

            % Update crossover filter
            % plugin.crossover = crossoverFilter( ...
            %     2, ...
            %     [plugin.FcLow, plugin.FcHigh], ...
            %     [24, 24], ...
            %     plugin.SampleRate);
            plugin.crossover.SampleRate = sr;
            plugin.crossover.CrossoverFrequencies = [plugin.FcLow, plugin.FcHigh];
% crossFilt = crossoverFilter(nCrossovers,xFrequencies,xSlopes,Fs) 
            % Update compressors
            plugin.LowCompressor.SampleRate = plugin.SampleRate;
            plugin.LowCompressor.Threshold = plugin.LowThreshold;
            plugin.LowCompressor.Ratio = plugin.Ratio;

            plugin.MidCompressor.SampleRate = plugin.SampleRate;
            plugin.MidCompressor.Threshold = plugin.MidThreshold;
            plugin.MidCompressor.Ratio = plugin.Ratio;

            plugin.HighCompressor.SampleRate = plugin.SampleRate;
            plugin.HighCompressor.Threshold = plugin.HighThreshold;
            plugin.HighCompressor.Ratio = plugin.Ratio;
        end
        function updateCrossover(plugin)
            plugin.crossover.CrossoverFrequencies = [plugin.FcLow, plugin.FcHigh];
        end
        function updateRatio(plugin)
            plugin.LowCompressor.Ratio = plugin.Ratio;
            plugin.MidCompressor.Ratio = plugin.Ratio;
            plugin.HighCompressor.Ratio = plugin.Ratio;
        end
        function updateThreshold(plugin, newThreshold, index)
            if(index == 1)
                plugin.LowCompressor.Threshold = newThreshold;
            elseif(index == 2)
                plugin.MidCompressor.Threshold = newThreshold;
            elseif(index == 3)
                plugin.HighCompressor.Threshold = newThreshold;
            end
        end
    end
    methods
        function set.FcLow(plugin, val)
            % Update crossover filter
            plugin.FcLow = val;
            updateCrossover(plugin);
        end
        function set.FcHigh(plugin, val)
            % Update crossover filter
            plugin.FcHigh = val;
            updateCrossover(plugin)
        end
        function set.Ratio(plugin, val)
            plugin.Ratio = val;
            updateRatio(plugin);
        end
        function set.LowThreshold(plugin, val)
            plugin.LowThreshold = val;
            updateThreshold(plugin, val, 1);
        end
        function set.MidThreshold(plugin, val)
            plugin.MidThreshold = val;
            updateThreshold(plugin, val, 2);
        end
        function set.HighThreshold(plugin, val)
            plugin.HighThreshold = val;
            updateThreshold(plugin, val, 3);
        end
    end
end
