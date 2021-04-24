const std = @import("std");
const seizer = @import("../seizer.zig");
const c = @import("c.zig");

/// This is initialized in sdl.zig before the event loop is called
pub var engine: SoundEngine = undefined;

pub const SoundHandle = struct {
    id: u32,
};

const MAX_NUM_SOUNDS = 10;
const MAX_SOUNDS_PLAYING = 4;
const Generation = u4;

pub const SoundEngine = struct {
    device_id: c.SDL_AudioDeviceID,
    spec: c.SDL_AudioSpec,
    sounds: [MAX_NUM_SOUNDS]Sound,
    next_sound_slot: u32,
    sounds_playing: [MAX_SOUNDS_PLAYING]?PlayingSound,

    pub fn init(this: *@This()) !void {
        const wanted = c.SDL_AudioSpec{
            .freq = 44_100,
            .format = c.AUDIO_S16,
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

        c.SDL_PauseAudioDevice(device_id, 0);

        this.* = @This(){
            .device_id = device_id,
            .spec = obtained,
            .sounds = [_]Sound{.{ .alive = false, .generation = 0, .spec = undefined, .audio = undefined }} ** MAX_NUM_SOUNDS,
            .sounds_playing = [_]?PlayingSound{null} ** MAX_SOUNDS_PLAYING,
            .next_sound_slot = 0,
        };
    }

    const Sound = struct {
        alive: bool,
        generation: Generation,
        spec: c.SDL_AudioSpec,
        audio: []i16,
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
        std.debug.assert(file_audio_spec.format == c.AUDIO_S16);

        const generation = (this.sounds[slot].generation + 1) & std.math.maxInt(Generation);

        this.sounds[slot] = .{
            .alive = true,
            .generation = generation,
            .spec = file_audio_spec,
            .audio = @ptrCast([*]i16, @alignCast(@alignOf(i16), audio_buf.?))[0..@divExact(audio_len, @sizeOf(i16))],
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

    pub fn play(this: *@This(), handle: SoundHandle) void {
        const slot = this.validate_handle(handle) catch unreachable;
        const sound = this.sounds[slot];
        for (this.sounds_playing) |*playing_sound_opt| {
            if (playing_sound_opt.* == null) {
                playing_sound_opt.* = .{
                    .slot = slot,
                    .pos = 0,
                };
                return;
            }
        }
        std.log.warn("Too many sounds playing, dropping sounds", .{});
    }

    fn fill_audio(userdata: ?*c_void, stream_ptr: ?[*]u8, stream_len: c_int) callconv(.C) void {
        const this = @ptrCast(*@This(), @alignCast(@alignOf(@This()), userdata.?));
        const stream = @ptrCast([*]i16, @alignCast(@alignOf(i16), stream_ptr.?))[0..@intCast(usize, @divExact(stream_len, @sizeOf(i16)))];
        std.mem.set(i16, stream, this.spec.silence);

        for (this.sounds_playing) |_, idx| {
            if (this.sounds_playing[idx] == null) continue;
            const sound_playing = &this.sounds_playing[idx].?;
            const sound = this.sounds[sound_playing.slot];

            const sound_audio = sound.audio[sound_playing.pos..];
            for (stream) |*sample, i| {
                if (sound_playing.pos >= sound.audio.len) {
                    this.sounds_playing[idx] = null;
                    break;
                }
                var res: i16 = undefined;
                if (@addWithOverflow(i16, sample.*, sound.audio[sound_playing.pos], &res)) {
                    if (sound.audio[sound_playing.pos] < 0) {
                        sample.* = std.math.maxInt(i16);
                    } else {
                        sample.* = std.math.minInt(i16);
                    }
                } else {
                    sample.* = res;
                }
                sound_playing.pos += 1;
            }
        }
    }
};
