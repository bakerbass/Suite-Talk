# VAD-Hackathon
This repository contains my 1st-place submission for the AES MATLAB Hackathon hosted in June 2025.

The challenge was to create a dialogue-focused vocal enhancement plugin, with at the very least a voice activity detector influencing a noise gate.

For my submission, titled Suite Talk, I designed a signal chain that aims to remove silibance and plosives, boost speech harmonics for clarity, remove 60 cycle hum, as well as use ML-driven speech enhancement to reduce the relative volume of non-speech sounds.

The primary file is found in [suiteTalk.m](https://github.com/bakerbass/VAD-Hackathon/blob/main/suiteTalk.m).

Code generation will not pass unless a Deep Learning Library is chosen.

# Parameters
![GUIhires](https://github.com/user-attachments/assets/1c28e900-909b-4ab2-89fc-5757656a151a)

The top row of parameters control the noise gate. Default values should cause no unwanted attenuation. The floor controls the lowest level the signal can be attenuated by.

The middle row controls the speech enhancer and hum reducer. Both parameters can be toggled off entirely.

The last row control the compression ratio and provided a toggle for the limiter.


# Design and Challenges
The block diagram shows the signal flow of the plugin from a higher-level overview.
![Suite Talk Block Diagram](https://github.com/user-attachments/assets/c8089991-5b2f-40bb-98bf-9de499098e5f)

The most difficult aspect of this challenge was implementing the [enhanceSpeech](https://www.mathworks.com/help/audio/ref/enhancespeech.html) function into a real time environment that is compatible with MATLAB code generation.

Due to both the VAD and speech enhancer requiring at least 0.032 seconds of audio to work, a ring buffer is implemented to fix the buffer size to be larger than this.

However, choosing a buffer size to be large enough for all possible sample rates would be suboptimal. Large buffer sizes increase processing, and fighting against the real-time requirement required another solution.

For typical sampling rates, a buffer size of 2048 is sufficient. However, higher sampling rates would need upwards of 8192 samples per block. Therefore, the speech enhancer is first fed through a downsampler.
Since enhanceSpeech can work with a sampling rate as low as 4000Hz, I chose to decemate by a factor of 6 (for most sampling rates, 4 for those where 6 is not an integer divisor). 
This results in a sampling rate of around 8000 for typical rates of 48kHz, and higher for higher sampling rates.

Once the enhanced speech is generated, it is then upsampled to its original sampling rate and mixed into the signal chain.

Other signal processing decisions were made based on my personal experience as an audio engineer. 
The challenge of implementing enhanceSpeech did take away from some of the detail I could go into for the parameter tuning process. One idea I had to drop for time was controlling ratio and threshold with one knob.
Instead, a simple ratio knob and a constant threshold of -10dB were implemented.

# Evaluation
Using the included evaluation script, I noticed that the enhance speech function objectively does not improve speech intelligibility in my implementation.

The following screenshot shows STOI values for different levels of "enhanceSpeech" funciton. 
![metrics](https://github.com/user-attachments/assets/c3c4240c-1368-4ca6-b5da-426b5b86b731)

This could be caused by the severe artifacting caused by resampling the audio.

If I were to fix this, I would probably only apply resampling to very high sampling rates.

# Future work
I often like to take time after these hackathons to develop the signal processing or design of the system further. 
These are typically off-the-cuff explorations, so not much is planned at this time.

However, I recorded video documentation of my hackathon experience that I plan on editing down to a vlog to share my mindset and experience regarding these hackathons.
