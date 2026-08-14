const std = @import("std");
const box = @import("box.zig");
const media = @import("media");

const Io = std.Io;
const Mp4Reader = @This();

pub const Error = error{
    FileNotFound,
    InvalidFile,
    UnsupportedFile,
    Unseekable,
} || std.Io.File.OpenError || box.ReadError;

pub const StreamIterator = struct {
    traks: []box.Trak,

    pub fn init(moov: *const box.Moov) StreamIterator {
        return StreamIterator{
            .traks = moov.traks.items,
        };
    }

    pub fn next(self: *StreamIterator) ?media.Stream {
        if (self.traks.len == 0) {
            return null;
        }

        const trak = &self.traks[0];
        self.traks = self.traks[1..];
        return trakToStream(trak);
    }

    fn trakToStream(trak: *const box.Trak) media.Stream {
        const sample_entry = trak.mdia.minf.stbl.stsd.entries.items[0];

        const stream = media.Stream{
            .id = trak.tkhd.track_id,
            .time_base = .{ .num = 1, .den = trak.timescale() },
            .codec = trak.codec(),
            .duration = trak.mdia.mdhd.duration,
            .nb_frames = trak.sampleCount(),
            .config = switch (trak.mediaType()) {
                .video => .{
                    .video = media.VideoConfig{
                        .width = trak.width(),
                        .height = trak.height(),
                    },
                },
                .audio => .{
                    .audio = media.AudioConfig{
                        .channels = sample_entry.audio.channelcount,
                        .sample_rate = sample_entry.audio.samplerate,
                    },
                },
                else => .unknown,
            },
            .extra_data = blk: {
                const config: []u8 = switch (trak.mediaType()) {
                    .video => sample_entry.video.codec_config,
                    .audio => sample_entry.audio.codec_config,
                    else => &.{},
                };

                break :blk config;
            },
        };

        return stream;
    }
};

pub const FrameIterator = struct {
    streams: []Stream,
    reader: Io.File.Reader,
    buffer: []u8,
    min_stream: ?*Stream = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        file: Io.File,
        moov: *const box.Moov,
        buffer: []u8,
    ) !FrameIterator {
        var streams = try allocator.alloc(Stream, moov.traks.items.len);
        for (moov.traks.items, 0..) |*trak, i| {
            streams[i] = .{
                .iterator = trak.sampleIterator(),
                .timescale = trak.timescale(),
                .id = trak.tkhd.track_id,
            };
        }

        var frame_iterator = FrameIterator{
            .streams = streams,
            .reader = undefined,
            .buffer = buffer,
        };

        frame_iterator.reader = file.reader(io, frame_iterator.buffer);
        frame_iterator.min_stream = frame_iterator.getMinStream();
        return frame_iterator;
    }

    pub fn next(self: *FrameIterator, media_allocator: std.mem.Allocator) !?media.Packet {
        if (self.min_stream) |stream| {
            const sample_metadata = stream.iterator.next().?;
            var packet = try media.Packet.alloc(media_allocator, sample_metadata.size);
            errdefer packet.deinit(media_allocator);

            try self.reader.seekTo(sample_metadata.offset);
            try readFramePayload(&self.reader, &packet);

            packet.dts = @intCast(sample_metadata.dts);
            packet.pts = @intCast(sample_metadata.pts);
            packet.duration = sample_metadata.duration;
            packet.flags.keyframe = sample_metadata.is_sync;
            packet.stream_id = stream.id;

            self.min_stream = self.getMinStream();

            return packet;
        }

        return null;
    }

    pub fn peek(self: *FrameIterator, media_allocator: std.mem.Allocator) !?media.Packet {
        if (self.min_stream) |stream| {
            const sample_metadata = stream.iterator.peek().?;
            var packet = try media.Packet.alloc(media_allocator, sample_metadata.size);
            errdefer packet.deinit(media_allocator);

            try self.reader.seekTo(sample_metadata.offset);
            try readFramePayload(&self.reader, &packet);

            packet.dts = @intCast(sample_metadata.dts);
            packet.pts = @intCast(sample_metadata.pts);
            packet.duration = sample_metadata.duration;
            packet.flags.keyframe = sample_metadata.is_sync;
            packet.stream_id = stream.id;

            return packet;
        }

        return null;
    }

    pub fn skip(self: *FrameIterator) void {
        if (self.min_stream) |stream| {
            stream.iterator.skip(1);
            self.min_stream = self.getMinStream();
        }
    }

    pub fn deinit(self: *FrameIterator, allocator: std.mem.Allocator) void {
        allocator.free(self.streams);
    }

    fn getMinStream(self: *FrameIterator) ?*Stream {
        var min_idx: usize = 0;
        var min_dts = self.streams[0].sampleDts();

        for (self.streams[1..], 1..) |*stream, idx| {
            const stream_dts = stream.sampleDts();
            if (stream_dts < min_dts) {
                min_idx = idx;
                min_dts = stream_dts;
            }
        }

        return if (min_dts != std.math.maxInt(u64)) &self.streams[min_idx] else null;
    }
};

const Stream = struct {
    iterator: box.SampleIterator,
    timescale: u32,
    id: u32,

    fn sampleOffset(self: *Stream) u64 {
        if (self.iterator.peek()) |*sample| {
            return sample.offset;
        }

        return std.math.maxInt(u64);
    }

    fn sampleDts(self: *Stream) u64 {
        if (self.iterator.peek()) |*sample| {
            return sample.dts;
        }

        return std.math.maxInt(u64);
    }
};

io: Io,
file: Io.File,
moov: box.Moov,
err: ?Io.File.Reader.Error = null,

/// Creates a new mp4 reader.
pub fn init(io: Io, allocator: std.mem.Allocator, dir: ?Io.Dir, src: []const u8) Error!Mp4Reader {
    const base_dir = dir orelse Io.Dir.cwd();
    const file = try base_dir.openFile(io, src, .{ .mode = .read_only });

    var reader = Mp4Reader{
        .io = io,
        .file = file,
        .moov = .{
            .mvhd = undefined,
            .traks = .empty,
        },
    };
    errdefer reader.deinit(allocator);

    try reader.readMoov(allocator);
    return reader;
}

pub fn deinit(self: *Mp4Reader, allocator: std.mem.Allocator) void {
    self.file.close(self.io);
    self.moov.deinit(allocator);
}

/// Gets an interator over all the streams in the file.
///
/// The stream data owned by the reader and should not be freeed or used after the reader is deinitialized.
pub fn streamIterator(self: *const Mp4Reader) StreamIterator {
    return .init(&self.moov);
}

/// Read a single frame from the specified stream and frame index. Returns null if the stream or frame is not found.
///
/// This is a slow operation that seeks to the frame's offset and reads it. For better performance, use `frameIterator` to read frames sequentially.
pub fn readFrame(self: *Mp4Reader, media_allocator: std.mem.Allocator, stream_id: u32, frame_idx: usize) !?media.Packet {
    var maybe_trak: ?*const box.Trak = null;
    for (self.moov.traks.items) |*in_trak| if (in_trak.tkhd.track_id == stream_id) {
        maybe_trak = in_trak;
        break;
    };

    if (maybe_trak) |trak| {
        var iterator = trak.sampleIterator();
        iterator.skip(@intCast(frame_idx));

        if (iterator.next()) |*sample| {
            var packet = try media.Packet.alloc(media_allocator, sample.size);
            errdefer packet.deinit(media_allocator);

            var reader = self.file.reader(self.io, &.{});
            try reader.seekTo(sample.offset);
            try readFramePayload(&reader, &packet);

            packet.dts = @intCast(sample.dts);
            packet.pts = @intCast(sample.pts);
            packet.duration = sample.duration;
            packet.flags.keyframe = sample.is_sync;
            packet.stream_id = stream_id;

            return packet;
        }
    }

    return null;
}

/// Creates an iterator that reads frames sequentially from all streams. Frames are sorted in decoding order (based on DTS).
pub fn frameIterator(self: *Mp4Reader, allocator: std.mem.Allocator, buffer: []u8) !FrameIterator {
    return try FrameIterator.init(
        allocator,
        self.io,
        self.file,
        &self.moov,
        buffer,
    );
}

fn readMoov(self: *Mp4Reader, allocator: std.mem.Allocator) !void {
    var buffer: [1024]u8 = undefined;
    var reader = self.file.reader(self.io, &buffer);

    var moov_found: bool = false;

    while (true) {
        const header = try box.Header.parse(&reader.interface);
        switch (header.type) {
            .moov => {
                self.moov = box.Moov.parse(allocator, header, &reader.interface) catch |err| switch (err) {
                    error.ReadFailed => {
                        self.err = reader.err;
                        return error.ReadFailed;
                    },
                    else => |e| return e,
                };
                moov_found = true;
                break;
            },
            else => try reader.seekBy(@intCast(header.payloadSize())),
        }
    }

    if (!moov_found) return error.InvalidFile;
    if (self.moov.mvex != null) return error.UnsupportedFile;
}

fn readFramePayload(reader: *Io.File.Reader, packet: *media.Packet) !void {
    reader.interface.readSliceAll(packet.mutableData().?) catch |err| switch (err) {
        error.ReadFailed => {
            reader.err = reader.err;
            return error.ReadFailed;
        },
        else => |e| return e,
    };
}

const testing = std.testing;

fn openFixture(allocator: std.mem.Allocator, io: Io, name: []const u8) ![:0]u8 {
    return try Io.Dir.cwd().realPathFileAlloc(io, name, allocator);
}

test "Mp4Reader: init parses moov and deinit releases memory" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    try testing.expectEqual(1000, reader.moov.mvhd.timescale);
    try testing.expectEqual(2, reader.moov.traks.items.len);
}

test "Mp4Reader: init returns FileNotFound for missing file" {
    const allocator = testing.allocator;
    const io = testing.io;

    try testing.expectError(
        error.FileNotFound,
        Mp4Reader.init(io, allocator, null, "/nonexistent/path/does_not_exist.mp4"),
    );
}

test "Mp4Reader: streamIterator yields video then audio then null" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    var it = reader.streamIterator();

    const video = it.next().?;
    try testing.expectEqual(media.MediaType.video, video.mediaType());
    try testing.expectEqual(1, video.id);
    try testing.expectEqual(media.Codec.h264, video.codec);
    try testing.expectEqual(1, video.time_base.num);
    try testing.expectEqual(10_240, video.time_base.den);
    try testing.expectEqual(160, video.config.video.width);
    try testing.expectEqual(120, video.config.video.height);

    const audio = it.next().?;
    try testing.expectEqual(media.MediaType.audio, audio.mediaType());
    try testing.expectEqual(2, audio.id);
    try testing.expectEqual(media.Codec.aac, audio.codec);
    try testing.expectEqual(22_050, audio.time_base.den);
    try testing.expectEqual(22_050, audio.config.audio.sample_rate);
    try testing.expect(audio.config.audio.channels >= 1);

    try testing.expect(it.next() == null);
}

test "Mp4Reader: readFrame returns first video keyframe" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    var packet = (try reader.readFrame(allocator, 1, 0)).?;
    defer packet.deinit(allocator);

    try testing.expectEqual(4454, packet.data.len);
    try testing.expectEqual(0, packet.dts);
    try testing.expectEqual(0, packet.pts);
    try testing.expectEqual(1024, packet.duration.?);
    try testing.expect(packet.flags.keyframe);
    try testing.expect(packet.ownsData());
}

test "Mp4Reader: readFrame reads middle video frame at correct offset" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    var packet = (try reader.readFrame(allocator, 1, 1)).?;
    defer packet.deinit(allocator);

    try testing.expectEqual(400, packet.data.len);
    try testing.expectEqual(1024, packet.dts);
    try testing.expect(!packet.flags.keyframe);
}

test "Mp4Reader: readFrame reads first audio frame" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    var packet = (try reader.readFrame(allocator, 2, 0)).?;
    defer packet.deinit(allocator);

    try testing.expectEqual(192, packet.data.len);
    try testing.expectEqual(0, packet.dts);
}

test "Mp4Reader: readFrame returns null for unknown stream id" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    try testing.expectEqual(null, try reader.readFrame(allocator, 999, 0));
}

test "Mp4Reader: readFrame returns null for out-of-range frame index" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    try testing.expectEqual(null, reader.readFrame(allocator, 1, 999));
}

test "Mp4Reader: frameIterator yields all frames across streams" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    var it = try reader.frameIterator(allocator, &buffer);
    defer it.deinit(allocator);

    var video_count: usize = 0;
    var audio_count: usize = 0;
    var keyframes: usize = 0;
    var first_packet_size: usize = 0;
    var first_seen = false;

    while (try it.next(allocator)) |p| {
        var packet = p;
        defer packet.deinit(allocator);

        if (!first_seen) {
            first_packet_size = packet.data.len;
            first_seen = true;
        }
        if (packet.flags.keyframe) keyframes += 1;
        if (packet.data.len >= 300) video_count += 1 else audio_count += 1;
    }

    try testing.expectEqual(5, video_count);
    try testing.expectEqual(12, audio_count);
    try testing.expectEqual(4454, first_packet_size);
    try testing.expect(keyframes >= 1);
}

test "Mp4Reader: frameIterator exhausted returns null" {
    const allocator = testing.allocator;
    const io = testing.io;

    var reader = try Mp4Reader.init(io, allocator, null, "fixtures/sample.mp4");
    defer reader.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    var it = try reader.frameIterator(allocator, &buffer);
    defer it.deinit(allocator);

    var drained: usize = 0;
    while (try it.next(allocator)) |p| {
        var packet = p;
        defer packet.deinit(allocator);
        drained += 1;
    }

    try testing.expectEqual(17, drained);
    try testing.expectEqual(null, try it.next(allocator));
    try testing.expectEqual(null, try it.next(allocator));
}
