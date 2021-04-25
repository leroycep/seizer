const std = @import("std");
const seizer = @import("../seizer.zig");
const c = @import("c.zig");

/// This is initialized in sdl.zig before the event loop is called
pub var engine: SoundEngine = undefined;

pub const SoundHandle = struct {
    id: u32,
};

pub const NodeHandle = struct {
    id: u32,
};

const MAX_NUM_SOUNDS = 10;
const MAX_SOUNDS_PLAYING = 10;
const Generation = u4;

pub const SoundEngine = struct {
    device_id: c.SDL_AudioDeviceID,
    spec: c.SDL_AudioSpec,
    sounds: [MAX_NUM_SOUNDS]Sound,
    next_sound_slot: u32,
    sounds_playing: [MAX_SOUNDS_PLAYING]?PlayingSound,

    nodes: [MAX_SOUNDS_PLAYING]AudioNode,
    next_node_slot: u32,
    output_nodes: [MAX_SOUNDS_PLAYING]?u32,

    pub fn init(this: *@This()) !void {
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
            .device_id = device_id,
            .spec = obtained,
            .sounds = [_]Sound{.{ .alive = false, .generation = 0, .audio = undefined, .allocator = undefined }} ** MAX_NUM_SOUNDS,
            .sounds_playing = [_]?PlayingSound{null} ** MAX_SOUNDS_PLAYING,
            .next_sound_slot = 0,
            .nodes = [_]AudioNode{AudioNode{ .None = {} }} ** MAX_SOUNDS_PLAYING,
            .next_node_slot = 0,
            .output_nodes = [_]?u32{null} ** MAX_SOUNDS_PLAYING,
        };
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
                //std.log.debug("sample[{}] = {d}, {d}", .{ idx, val[0], val[1] });
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
        allocator: *std.mem.Allocator,
    };

    const PlayingSound = struct {
        slot: u32,
        pos: usize,
    };

    pub fn load(this: *@This(), allocator: *std.mem.Allocator, filename: [:0]const u8, maxFileSize: usize) !SoundHandle {
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

    pub fn createSoundNode(this: *@This(), handle: SoundHandle) NodeHandle {
        c.SDL_LockAudioDevice(this.device_id);
        defer c.SDL_UnlockAudioDevice(this.device_id);

        const sound_slot = this.validate_handle(handle) catch unreachable;

        const node_slot = this.next_node_slot;
        this.next_node_slot += 1;
        this.nodes[node_slot] = AudioNode{
            .Sound = .{
                .sound = sound_slot,
                .pos = 0,
                .play = .paused,
            },
        };

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

    pub fn play(this: *@This(), nodeHandle: NodeHandle) void {
        switch (this.nodes[nodeHandle.id]) {
            .None => {},
            .Sound => |*sound| {
                sound.pos = 0;
                sound.play = .once;
            },
        }
    }

    fn saturating_add(a: f32, b: f32) f32 {
        return std.math.clamp(a + b, -1, 1);
    }

    // SDL fill audio callback
    fn fill_audio(userdata: ?*c_void, stream_ptr: ?[*]u8, stream_len: c_int) callconv(.C) void {
        const this = @ptrCast(*@This(), @alignCast(@alignOf(@This()), userdata.?));
        const stream = @ptrCast([*][2]f32, @alignCast(@alignOf([2]f32), stream_ptr.?))[0..@intCast(usize, @divExact(stream_len, @sizeOf([2]f32)))];
        const silence = @intToFloat(f32, this.spec.silence);
        std.mem.set([2]f32, stream, [2]f32{ silence, silence });

        // TODO: switch to using samples buffers, instead of individual samples
        for (stream) |*sample, sampleIdx| {
            for (this.output_nodes) |output_node_opt, idx| {
                const output_node = output_node_opt orelse continue;

                const val = switch (this.nodes[output_node]) {
                    .None => [2]f32{ 0, 0 },
                    .Sound => |sound_node| get_sound_sample: {
                        const sound = this.sounds[sound_node.sound];

                        if (sound_node.play == .paused or sound_node.pos >= sound.audio.len) {
                            break :get_sound_sample [2]f32{ 0, 0 };
                        }

                        break :get_sound_sample sound.audio[sound_node.pos];
                    },
                };

                sample[0] = saturating_add(sample[0], val[0]);
                sample[1] = saturating_add(sample[1], val[1]);
            }

            for (this.nodes) |*node, idx| {
                switch (node.*) {
                    .None => {},
                    .Sound => |*sound_node| {
                        if (sound_node.play == .paused) continue;
                        sound_node.pos += 1;
                        const sound = this.sounds[sound_node.sound];
                        if (sound_node.play == .once and sound_node.pos >= sound.audio.len) {
                            sound_node.play = .paused;
                        }
                    },
                }
            }
        }
    }

    pub fn deinit(this: *@This(), handle: SoundHandle) void {
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
    };

    const SoundNode = struct {
        sound: u32,
        pos: u32,
        play: Play,

        const Play = enum {
            paused,
            once,
        };
    };
};
