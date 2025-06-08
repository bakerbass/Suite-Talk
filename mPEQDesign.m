clear all;

frameLength = 512;

fileReader = dsp.AudioFileReader( ...
    'Filename','Noisy Speech.wav', ...
    'SamplesPerFrame',frameLength);
deviceWriter = audioDeviceWriter( ...
    'SampleRate',fileReader.SampleRate);

setup(deviceWriter,ones(frameLength,2))
hpf_Fc = 90 % rumble blocking high-pass filter
hpf_Slope = 24 % steep slope
dp_Q = 0.3
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
ds_Fc = 8000 % center of de-ess bell


FcLow = 6300 % low end of de-ess detector
Fchigh = 9800 % high end of de-ess detector

mPEQ = multibandParametricEQ('Oversample',true, ...
    'NumEQBands', 4, ...
    'HasHighpassFilter', true, ...
    'HighpassCutoff', hpf_Fc, ...
    'HighpassSlope', hpf_Slope, ...
    'Frequencies', [dp_Fc, lmBoost_Fc, hmBoost_Fc, ds_Fc], ...
    'QualityFactors', [dp_Q, lmBoost_Q, hmBoost_Q, ds_Q], ...
    'PeakGains', [0, lmBoost_G, hmBoost_G, -3]);
visualize(mPEQ)

count = 0;
while ~isDone(fileReader)
    originalSignal = fileReader();
    equalizedSignal = mPEQ(originalSignal);
    deviceWriter(equalizedSignal);
    count = count + 1;
end

release(fileReader)
release(mPEQ)
release(deviceWriter)