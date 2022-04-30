const std = @import("std");
const seizer = @import("../seizer.zig");
const c = @import("c.zig");

pub const SoundHandle = struct {
    id: u32,
};

pub const NodeHandle = struct {
    id: u32,
};

pub const BiquadOptions = struct {
    kind: enum(u4) {
        lowpass = 0,
        highpass,
        bandpass,
        lowshelf,
        highshelf,
        peaking,
        notch,
        allpass,
    },
    freq: f32,
    q: f32,
    gain: f32 = 1.0,
};

pub const MixerInput = struct {
    handle: NodeHandle,
    gain: f32,
};

const MAX_NUM_SOUNDS = 10;
const MAX_SOUNDS_PLAYING = 200;
const MAX_OUTPUT = 10;
const Generation = u4;

pub const Engine = struct {
    allocator: std.mem.Allocator,

    device_id: c.SDL_AudioDeviceID,
    spec: c.SDL_AudioSpec,

    // TODO: put the following fields into a heap allocated struct so we can share pointer to it without fear of someone moving the Engine struct
    sounds: [MAX_NUM_SOUNDS]Sound,
    next_sound_slot: u32,
    nodes: [MAX_SOUNDS_PLAYING]AudioNode,
    next_node_slot: u32,
    output_nodes: [MAX_OUTPUT]?u32,

    pub fn init(this: *@This(), allocator: std.mem.Allocator) !void {
        const wanted = c.SDL_AudioSpec{
            .freq = 44_100,
            .format = c.AUDIO_F32,
            .channels = 2,
            .samples = 1024,
            .callback = fill_audio,
            .userdata = this,

            // What values should these have?
            .silence = undefined,
            .padding = undefined,
            .size = undefined,
        };
        var obtained: c.SDL_AudioSpec = undefined;

        const device_id = c.SDL_OpenAudioDevice(null, 0, &wanted, &obtained, 0);
        if (device_id == 0) {
            return error.OpenAudioDevice;
        }

        std.debug.assert(obtained.format == c.AUDIO_F32);

        c.SDL_PauseAudioDevice(device_id, 0);

        this.* = @This(){
            .allocator = allocator,
            .device_id = device_id,
            .spec = obtained,
            .sounds = [_]Sound{.{ .alive = false, .generation = 0, .audio = undefined, .allocator = undefined }} ** MAX_NUM_SOUNDS,
            .next_sound_slot = 0,
            .nodes = [_]AudioNode{AudioNode{ .None = {} }} ** MAX_SOUNDS_PLAYING,
            .next_node_slot = 0,
            .output_nodes = [_]?u32{null} ** MAX_OUTPUT,
        };
    }

    pub fn deinit(this: *@This()) void {
        c.SDL_CloseAudioDevice(this.device_id);
        for (this.nodes) |*node| {
            switch (node.*) {
                .None, .Sound, .Biquad, .DelayInput => {},
                .Mixer => |mixer_node| this.allocator.free(mixer_node.inputs),
                .DelayOutput => |delay_out_node| this.allocator.free(delay_out_node.buffer),
            }
        }
    }

    const Sampler = struct {
        spec: c.SDL_AudioSpec,
        buffer: []u8,

        fn sampleF32(this: @This(), idx: usize) f32 {
            switch (this.spec.format) {
                c.AUDIO_S16 => {
                    const RANGE = @intToFloat(f32, std.math.maxInt(i16));
                    const val = @intToFloat(f32, std.mem.readIntLittle(i16, this.buffer[idx..][0..2]));
                    return val / RANGE;
                },
                c.AUDIO_F32 => return @bitCast(f32, this.buffer[idx..][0..4].*),
                else => @panic("Unsupported audio format"),
            }
        }

        pub fn sampleF32Stereo(this: @This(), idx: usize) [2]f32 {
            const component_size: usize = switch (this.spec.format) {
                c.AUDIO_S16 => @sizeOf(i16),
                c.AUDIO_F32 => @sizeOf(f32),
                else => @panic("Unsupported audio format"),
            };
            if (this.spec.channels == 1) {
                const mono = this.sampleF32(idx * component_size);
                return [2]f32{ mono, mono };
            } else {
                const stride = this.spec.channels * component_size;
                const val = [2]f32{
                    this.sampleF32(idx * stride),
                    this.sampleF32(idx * stride + component_size),
                };
                return val;
            }
        }

        pub fn numSamples(this: @This()) usize {
            const component_size: usize = switch (this.spec.format) {
                c.AUDIO_S16 => @sizeOf(i16),
                c.AUDIO_F32 => @sizeOf(f32),
                else => @panic("Unsupported audio format"),
            };
            const stride = this.spec.channels * component_size;
            return this.buffer.len / stride;
        }
    };

    const Sound = struct {
        alive: bool,
        generation: Generation,
        audio: [][2]f32,
        allocator: std.mem.Allocator,
    };

    const PlayingSound = struct {
        slot: u32,
        pos: usize,
    };

    pub fn load(this: *@This(), allocator: std.mem.Allocator, filename: [:0]const u8, maxFileSize: usize) !SoundHandle {
        const starting_slot = this.next_sound_slot;
        var slot = starting_slot;
        while (true) {
            if (!this.sounds[slot].alive) {
                break;
            }

            slot += 1;
            slot %= @intCast(u32, this.sounds.len);

            if (slot == starting_slot) {
                @panic("Out of sound slots");
            }
        }

        const file_contents = try seizer.fetch(allocator, filename, maxFileSize);
        defer allocator.free(file_contents);

        var file_audio_spec: c.SDL_AudioSpec = undefined;
        var audio_buf: ?[*]u8 = null;
        var audio_len: u32 = undefined;
        if (c.SDL_LoadWAV_RW(c.SDL_RWFromConstMem(file_contents.ptr, @intCast(c_int, file_contents.len)), 0, &file_audio_spec, &audio_buf, &audio_len) == null) {
            // TODO: print error from SDL
            return error.InvalidFile;
        }

        // TODO: Remove this limitation
        std.debug.assert(file_audio_spec.freq == this.spec.freq);
        std.debug.assert(file_audio_spec.channels > 0);

        const sampler = Sampler{
            .spec = file_audio_spec,
            .buffer = audio_buf.?[0..audio_len],
        };

        const num_samples = sampler.numSamples();

        const audio = try allocator.alloc([2]f32, num_samples);
        errdefer allocator.free(audio);

        std.mem.set([2]f32, audio, [2]f32{ 0, 0 });

        for (audio) |*sample, idx| {
            sample.* = sampler.sampleF32Stereo(idx);
        }

        const generation = (this.sounds[slot].generation +% 1);

        this.sounds[slot] = .{
            .alive = true,
            .generation = generation,
            .audio = audio,
            .allocator = allocator,
        };

        this.next_sound_slot = (slot + 1) % @intCast(u32, this.sounds.len);

        return make_handle(generation, slot);
    }

    fn make_handle(generation: Generation, slot: u32) SoundHandle {
        std.debug.assert(Generation == u4);
        const instance = @as(u32, @intCast(u28, slot));
        return .{ .id = (@as(u32, generation) << 28) | instance };
    }

    fn validate_handle(this: @This(), handle: SoundHandle) !u32 {
        std.debug.assert(Generation == u4);
        const generation = @intCast(Generation, (handle.id & (0b1111 << 28)) >> 28);
        const slot = std.math.maxInt(u28) & handle.id;
        if (this.sounds[slot].generation != generation) {
            return error.InvalidHandle;
        }
        return slot;
    }

    pub fn createSoundNode(this: *@This()) NodeHandle {
        c.SDL_LockAudioDevice(this.device_id);
        defer c.SDL_UnlockAudioDevice(this.device_id);

        const node_slot = this.next_node_slot;
        this.next_node_slot += 1;
        this.nodes[node_slot] = AudioNode{
            .Sound = .{
                .sound = null,
                .pos = 0,
                .play = .paused,
            },
        };

        return NodeHandle{ .id = node_slot };
    }

    pub fn createBiquadNode(this: *@This(), inputNode: NodeHandle, options: BiquadOptions) NodeHandle {
        c.SDL_LockAudioDevice(this.device_id);
        defer c.SDL_UnlockAudioDevice(this.device_id);

        const freq = options.freq / @intToFloat(f32, this.spec.freq);

        const biquad = switch (options.kind) {
            .lowpass => Biquad.lopass(freq, options.q),
            .bandpass => Biquad.bandpass(freq, options.q),
            .allpass => Biquad.allpass(),
            else => @panic("Unimplmented biquad kind"),
        };

        const node_slot = this.next_node_slot;
        this.next_node_slot += 1;
        this.nodes[node_slot] = AudioNode{ .Biquad = .{
            .inputNode = inputNode.id,
            .left = biquad,
            .right = biquad,
        } };

        return NodeHandle{ .id = node_slot };
    }

    pub fn createMixerNode(this: *@This(), inputs: []const MixerInput) !NodeHandle {
        c.SDL_LockAudioDevice(this.device_id);
        defer c.SDL_UnlockAudioDevice(this.device_id);

        const node_slot = this.next_node_slot;
        this.nodes[node_slot] = AudioNode{ .Mixer = .{
            .inputs = try this.allocator.dupe(MixerInput, inputs),
            .sample = [2]f32{ 0, 0 },
        } };

        this.next_node_slot += 1;
        return NodeHandle{ .id = node_slot };
    }

    pub fn createDelayOutputNode(this: *@This(), delaySeconds: f32) !NodeHandle {
        c.SDL_LockAudioDevice(this.device_id);
        defer c.SDL_UnlockAudioDevice(this.device_id);

        const delay_samples = delaySeconds * @intToFloat(f32, this.spec.freq);

        const delay_buffer = try this.allocator.alloc([2]f32, @floatToInt(usize, delay_samples));
        errdefer this.allocator.free(delay_buffer);

        std.mem.set([2]f32, delay_buffer, .{ 0, 0 });

        const node_slot = this.next_node_slot;
        this.nodes[node_slot] = AudioNode{ .DelayOutput = .{
            .pos = 0,
            .buffer = delay_buffer,
        } };

        this.next_node_slot += 1;
        return NodeHandle{ .id = node_slot };
    }

    pub fn createDelayInputNode(this: *@This(), inputNode: NodeHandle, delayOutputNode: NodeHandle) !NodeHandle {
        c.SDL_LockAudioDevice(this.device_id);
        defer c.SDL_UnlockAudioDevice(this.device_id);

        const node_slot = this.next_node_slot;
        this.nodes[node_slot] = AudioNode{ .DelayInput = .{
            .inputNode = inputNode.id,
            .delayOutputNode = delayOutputNode.id,
        } };

        this.next_node_slot += 1;
        return NodeHandle{ .id = node_slot };
    }

    pub fn connectToOutput(this: *@This(), nodeHandle: NodeHandle) void {
        c.SDL_LockAudioDevice(this.device_id);
        defer c.SDL_UnlockAudioDevice(this.device_id);

        for (this.output_nodes) |output_node_opt, idx| {
            if (output_node_opt != null) continue;
            this.output_nodes[idx] = nodeHandle.id;
            return;
        }

        @panic("No more slots to connect to node to output");
    }

    pub fn play(this: *@This(), nodeHandle: NodeHandle, soundHandle: SoundHandle) void {
        const sound_slot = this.validate_handle(soundHandle) catch unreachable;
        switch (this.nodes[nodeHandle.id]) {
            .Sound => |*sound| {
                sound.sound = sound_slot;
                sound.pos = 0;
                sound.play = .once;
            },
            else => {},
        }
    }

    fn saturating_add(a: f32, b: f32) f32 {
        return std.math.clamp(a + b, -1, 1);
    }

    // SDL fill audio callback
    fn fill_audio(userdata: ?*anyopaque, stream_ptr: ?[*]u8, stream_len: c_int) callconv(.C) void {
        const this = @ptrCast(*@This(), @alignCast(@alignOf(@This()), userdata.?));
        const stream = @ptrCast([*][2]f32, @alignCast(@alignOf([2]f32), stream_ptr.?))[0..@intCast(usize, @divExact(stream_len, @sizeOf([2]f32)))];
        const silence = @intToFloat(f32, this.spec.silence);
        std.mem.set([2]f32, stream, [2]f32{ silence, silence });

        // TODO: switch to using samples buffers, instead of individual samples
        for (stream) |*sample| {
            for (this.output_nodes) |output_node_opt| {
                const output_node = output_node_opt orelse continue;

                const val = this.nodes[output_node].getSample(this.sounds[0..]);

                sample[0] = saturating_add(sample[0], val[0]);
                sample[1] = saturating_add(sample[1], val[1]);
            }

            for (this.nodes) |*node| {
                switch (node.*) {
                    .None, .DelayOutput => {},
                    .Sound => |*sound_node| {
                        if (sound_node.play == .paused) continue;
                        sound_node.pos += 1;
                        const sound = this.sounds[sound_node.sound orelse continue];
                        if (sound_node.play == .once and sound_node.pos >= sound.audio.len) {
                            sound_node.play = .paused;
                        }
                    },
                    .Biquad => |*biquad_node| {
                        const input = this.nodes[biquad_node.inputNode].getSample(this.sounds[0..]);
                        _ = biquad_node.left.process(input[0]);
                        _ = biquad_node.right.process(input[1]);
                    },
                    .Mixer => |*mixer_node| {
                        mixer_node.sample = [2]f32{ 0, 0 };
                        for (mixer_node.inputs) |node_input| {
                            const input = this.nodes[node_input.handle.id].getSample(this.sounds[0..]);
                            mixer_node.sample[0] = saturating_add(mixer_node.sample[0], input[0]);
                            mixer_node.sample[1] = saturating_add(mixer_node.sample[1], input[1]);
                        }
                    },
                    .DelayInput => |*delay_in_node| {
                        const delay_out_node = &(this.nodes[delay_in_node.delayOutputNode].DelayOutput);
                        const input = this.nodes[delay_in_node.inputNode].getSample(this.sounds[0..]);
                        delay_out_node.pos = (delay_out_node.pos + 1) % @intCast(u32, delay_out_node.buffer.len);
                        delay_out_node.buffer[delay_out_node.pos] = input;
                    },
                }
            }
        }
    }

    pub fn freeSound(this: *@This(), handle: SoundHandle) void {
        c.SDL_LockAudioDevice(this.device_id);
        defer c.SDL_UnlockAudioDevice(this.device_id);

        const slot = this.validate_handle(handle) catch unreachable;
        const sound = this.sounds[slot];

        sound.allocator.free(sound.audio);
        this.sounds[slot].alive = false;
    }

    const AudioNode = union(enum) {
        None: void,
        Sound: SoundNode,
        Biquad: BiquadNode,
        Mixer: MixerNode,
        DelayOutput: DelayOutputNode,
        DelayInput: DelayInputNode,

        pub fn getSample(this: @This(), sounds: []Sound) [2]f32 {
            switch (this) {
                .None, .DelayInput => return [2]f32{ 0, 0 },
                .Sound => |sound_node| {
                    const sound = sounds[sound_node.sound orelse return [2]f32{ 0, 0 }];

                    if (sound_node.play == .paused or sound_node.pos >= sound.audio.len) {
                        return [2]f32{ 0, 0 };
                    }

                    return sound.audio[sound_node.pos];
                },
                .Biquad => |biquad_node| return [2]f32{ biquad_node.left.out, biquad_node.right.out },
                .Mixer => |mixer_node| return mixer_node.sample,
                .DelayOutput => |delay_node| {
                    const idx = (delay_node.pos + 1) % delay_node.buffer.len;
                    return delay_node.buffer[idx];
                },
            }
        }
    };

    const SoundNode = struct {
        sound: ?u32,
        pos: u32,
        play: Play,

        const Play = enum {
            paused,
            once,
        };
    };

    const BiquadNode = struct {
        inputNode: u32,
        left: Biquad,
        right: Biquad,
    };

    const MixerNode = struct {
        inputs: []const MixerInput,
        sample: [2]f32,
    };

    const DelayOutputNode = struct {
        pos: u32,
        buffer: [][2]f32,
    };

    const DelayInputNode = struct {
        inputNode: u32,
        delayOutputNode: u32,
    };
};

const Biquad = struct {
    a0: f32,
    a1: f32,
    a2: f32,
    b1: f32,
    b2: f32,
    z1: f32,
    z2: f32,
    out: f32,

    pub fn lopass(freq: f32, q: f32) @This() {
        const k = @tan(std.math.pi * freq);
        const norm = 1.0 / (1.0 + k / q + k * k);

        const a0 = k * k * norm;

        return @This(){
            .a0 = a0,
            .a1 = 2 * a0,
            .a2 = a0,
            .b1 = 2 * (k * k - 1) * norm,
            .b2 = (1 - k / q + k * k) * norm,
            .z1 = 0,
            .z2 = 0,
            .out = 0,
        };
    }

    pub fn bandpass(freq: f32, q: f32) @This() {
        const k = @tan(std.math.pi * freq);
        const norm = 1.0 / (1.0 + k / q + k * k);
        const a0 = k / q * norm;
        return @This(){
            .a0 = a0,
            .a1 = 0,
            .a2 = -a0,
            .b1 = 2.0 * (k * k - 1.0) * norm,
            .b2 = (1.0 - k / q + k * k) * norm,
            .z1 = 0,
            .z2 = 0,
            .out = 0,
        };
    }

    pub fn allpass() @This() {
        return @This(){
            .a0 = 1,
            .a1 = 0,
            .a2 = 0,
            .b1 = 0,
            .b2 = 0,
            .z1 = 0,
            .z2 = 0,
            .out = 0,
        };
    }

    pub fn process(this: *@This(), in: f32) f32 {
        this.out = in * this.a0 + this.z1;
        this.z1 = in * this.a1 + this.z2 - this.b1 * this.out;
        this.z2 = in * this.a2 - this.b2 * this.out;
        return this.out;
    }
};
