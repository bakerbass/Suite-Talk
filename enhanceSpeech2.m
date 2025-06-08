function varargout = enhanceSpeech2(audioIn,fs, model)
%ENHANCESPEECH Enhance speech signal
%   cleanSpeech = enhanceSpeech(noisySpeech,fs) enhances the mono audio
%   input by reducing non-speech sounds.
%
%   enhanceSpeech(noisySpeech,fs) with no output arguments displays a plot
%   of the original and enhanced speech.
%
%   Example:
%       % Use enhanceSpeech to reduce non-speech sounds from an audio
%       % signal containing speech. Call enhanceSpeech a second time to
%       % visualize the original and enhanced signals. Listen to the audio
%       % signal before and after processing. Compare the short time
%       % objective intelligibility before and after processing.
%
%       target = audioread('CleanSpeech-16-mono-3secs.ogg');
%       [x,fs] = audioread('NoisySpeech-16-mono-3secs.ogg');
% 
%       y = enhanceSpeech(x,fs);
%
%       enhanceSpeech(x,fs)
%
%       sound(target,fs),pause(3.5)
%       sound(x,fs),pause(3.5)
%       sound(y,fs)
%
%       stoi_x = stoi(x,target,fs)
%       stoi_y = stoi(y,target,fs)
%
% See also SEPARATESPEAKERS, DETECTSPEECHNN, SPEECH2TEXT, STOI, VISQOL

% Copyright 2023 The MathWorks, Inc.

%#codegen

arguments
    audioIn (:,1) {mustBeA(audioIn,{'single','double','gpuArray'}),mustBeUnderlyingType(audioIn,'float')}
    fs (1,1) single {mustBeA(fs,{'single','double'}),mustBeGreaterThanOrEqual(fs,4e3)}
    model
end

% Get the network
net = model;

% Preprocess - Convert audio to features
win = single(hamming(512,"periodic"));
[netInput,reconstructionPhase] = audio.ai.metricgan.preprocess(single(audioIn),fs,win);

% Process features in network
if isempty(coder.target)
    netOutput = predict(net,netInput);
else
    dlnetInput = dlarray(netInput,'TC');
    dlnetOutput = predict(net,dlnetInput);
    netOutput = permute(extractdata(dlnetOutput),[2,1]);
end

% Postprocess - Convert features to audio
audioOut = audio.ai.metricgan.postprocess(audioIn,fs,reconstructionPhase,netOutput,win);

if nargout==0
    iConveniencePlot(audioIn,audioOut,fs)
else
    varargout{1} = audioOut;
end

end

%% Supporting Functions

% Convenience plot
function iConveniencePlot(x,y,fs)

% Create tiledlayout
tiledlayout(2,2, ...
    TileSpacing="compact", ...
    Padding="compact")

% Create time index.
t = ((0:size(x,1)-1)/fs)';

% Get the spectral representation of the predictor
wL = round(0.03*fs);
[xS,F,T]= stft(x,fs, ...
    Window=hann(wL,"periodic"), ...
    FFTLength=wL, ...
    FrequencyRange="onesided");
xS = abs(xS);
xS = 20*log10(xS(:,:,1) + eps(underlyingType(xS)));

% Get the spectral representation of the prediction
yS = stft(y,fs, ...
    Window=hann(wL,"periodic"), ...
    FFTLength=wL, ...
    FrequencyRange="onesided");
yS = abs(yS);
yS = 20*log10(yS(:,:,1) + eps(underlyingType(yS)));

% Define options for plotting
plotopts.isFsnormalized = false;
plotopts.freqlocation = 'yaxis';

% Get joint min and max y-limits for time domain
joint_ylim = [min([x;y],[],"all","omitmissing"), ...
    max([x;y],[],"all","omitmissing")];

% Get joint min and max c-limits for frequency domain
smin = min([xS;yS],[],"all","omitmissing");
smax = max([xS;yS],[],"all","omitmissing");
joint_clim = [max(smax-80,smin),smax];

% Plot input audio in time domain
nexttile
plot(t,x)
ylabel(getString(message('audio:convenienceplots:AudioInput')),FontWeight='bold')
xlim('tight')
ylim(joint_ylim)
grid minor
set(gca,XTickLabel="")
title(getString(message('audio:convenienceplots:TimeAnalysis')))

% Plot input audio in frequency domain
nexttile
ax = signalwavelet.internal.convenienceplot.plotTFR(T,F,xS,plotopts);
set(ax,XTickLabel="")
xlabel(ax,"")
colorbar(ax,'off')
clim(gather(joint_clim)) % As of R2024a, clim does not support gpuArrays
title(getString(message('audio:convenienceplots:SpectralAnalysis')))

% Plot output audio in the time domain
nexttile
plot(t,y)
xlabel(getString(message('audio:convenienceplots:XaxisTime')))
ylabel(getString(message('audio:convenienceplots:AudioOutput')),FontWeight='bold')
ylim(joint_ylim)
xlim('tight')
grid minor

% Plot output audio in the frequency domain.
nexttile
ax = signalwavelet.internal.convenienceplot.plotTFR(T,F,yS,plotopts);
colorbar(ax,'off')
clim(gather(joint_clim)) % As of R2024a, clim does not support gpuArrays
xlabel(getString(message('audio:convenienceplots:XaxisTime')))

% Add a colorbar to the frequency domain representations
cb = colorbar();
cb.Layout.Tile='east';
cb.Label.String = getString(message('audio:convenienceplots:MagnitudedB'));
end