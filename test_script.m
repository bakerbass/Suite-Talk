% Test bench script for: My Vocal Enhancer with parameter sweep.
% Assumes suiteTalk has 'EnhanceLevel' property.

inputFile = 'C:\Users\ryanb\OneDrive\Documents\MATLAB\VAD HACKATHON\Noisy Speech.wav';
[filePath, fileName, ~] = fileparts(inputFile);

enhanceLevels = -12:3:0; % dB sweep
metricsTable = table('Size',[numel(enhanceLevels),2],...
    'VariableTypes',{'double','cell'},...
    'VariableNames',{'EnhanceLevel','Metrics'});

for k = 1:numel(enhanceLevels)
    % Create test bench input and output for each sweep
    fileReader = dsp.AudioFileReader(Filename=inputFile, PlayCount=1, SamplesPerFrame=512);
    outputFile = fullfile(filePath, [fileName '_Enh' num2str(enhanceLevels(k)) '.wav']);
    fileWriter = dsp.AudioFileWriter(outputFile, 'SampleRate', fileReader.SampleRate);

    % Create/initialize plugin and set EnhanceLevel
    sut1 = suiteTalk;
    setSampleRate(sut1, fileReader.SampleRate);
    sut1.EnhanceLevel = enhanceLevels(k);

    % Stream processing loop
    while ~isDone(fileReader)
        in = fileReader();
        out1 = sut1(in);
        fileWriter(out1);
    end

    release(sut1)
    release(fileReader)
    release(fileWriter)

    % Call your custom metric evaluator
    metrics = evaluateMetrics(outputFile); % Implement this as needed

    % Store result
    metricsTable.EnhanceLevel(k) = enhanceLevels(k);
    metricsTable.Metrics{k} = metrics;

    % Optionally, display progress
    fprintf('Done EnhanceLevel = %g dB, Metrics: %s\n', enhanceLevels(k), mat2str(metrics));
end

% Display or save summary
disp(metricsTable)
