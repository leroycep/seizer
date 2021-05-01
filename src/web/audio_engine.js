export default function getAudioEngineEnv(getInstance) {
    const getMemory = () => getInstance().exports.memory;
    const utf8decoder = new TextDecoder();
    const readCharStr = (ptr, len) =>
        utf8decoder.decode(new Uint8Array(getMemory().buffer, ptr, len));

    let audio_ctx;
    let nextSoundId;
    let sounds;

    let nextNodeId;
    let nodes;

    return {
        init() {
            audio_ctx = new AudioContext();

            nextSoundId = 1;
            sounds = {};

            nextNodeId = 1;
            nodes = {};
        },
        load(framePtr, filenamePtr, filenameLen, idOutPtr) {
            const id = nextSoundId;
            nextSoundId += 1;

            sounds[id] = {
                buffer: null,
            };

            const filename = readCharStr(filenamePtr, filenameLen);
            fetch(filename)
                .then((response) => response.arrayBuffer())
                .then((array_buffer) => audio_ctx.decodeAudioData(array_buffer))
                .then((audio_buffer) => (sounds[id].buffer = audio_buffer))
                .then(() => {
                    const idOut = new Int32Array(
                        getMemory().buffer,
                        idOutPtr,
                        1
                    );
                    idOut[0] = id;
                    getInstance().exports.resume(framePtr);
                });
        },
        createSoundNode() {
            const id = nextNodeId;
            nextNodeId += 1;

            nodes[id] = {
                // Create an output gain node that will serve as the point that every other node connects to.
                // This is necessary because the AudioBufferSourceNode will only play once.
                output: audio_ctx.createGain(),
                source: null,

                play(soundId) {
                    if (this.source != null) {
                        this.source.disconnect(this.output);
                    }
                    const sound = sounds[soundId];
                    this.source = audio_ctx.createBufferSource();
                    this.source.buffer = sound.buffer;
                    this.source.connect(this.output);
                    this.source.start();
                },
            };
            return id;
        },
        play(nodeId, soundId) {
            nodes[nodeId].play(soundId);
        },
        createBiquadNode(inputId, filterKind, filterFreq, filterQ, filterGain) {
            const id = nextNodeId;
            nextNodeId += 1;

            const input = nodes[inputId];

            const BIQUAD_TYPES = [
                "lowpass",
                "highpass",
                "bandpass",
                "lowshelf",
                "highshelf",
                "peaking",
                "notch",
                "allpass",
            ];

            const biquad = audio_ctx.createBiquadFilter();
            biquad.type = BIQUAD_TYPES[filterKind];
            biquad.frequency.value = filterFreq;
            biquad.Q.value = filterQ;
            biquad.gain.value = filterGain;
            input.output.connect(biquad);

            nodes[id] = {
                output: biquad,
                play() {},
            };
            return id;
        },
        createMixerNode() {
            const id = nextNodeId;
            nextNodeId += 1;

            nodes[id] = {
                output: audio_ctx.createGain(),
                play() {},
            };

            return id;
        },
        connectToMixer(mixerId, inputId, gain) {
            const gain_node = audio_ctx.createGain();
            gain_node.gain.value = gain;

            nodes[inputId].output.connect(gain_node);
            gain_node.connect(nodes[mixerId].output);
        },
        createDelayOutputNode(delaySeconds) {
            const id = nextNodeId;
            nextNodeId += 1;

            nodes[id] = {
                output: audio_ctx.createDelay(delaySeconds),
                play() {},
            };

            return id;
        },
        createDelayInputNode(inputId, delayOutputId) {
            nodes[inputId].output.connect(nodes[delayOutputId].output);
            // Return 0 to indicate nothing went wrong
            return 0;
        },
        connectToOutput(inputId) {
            nodes[inputId].output.connect(audio_ctx.destination);
        },
    };
}
