const std = @import("std");
const box = @import("box.zig");
const media = @import("media");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Mp4Writer = @This();

const default_timescale = 1000;

// Default Ftyp box
var compatible_brands = [_][4]u8{ "isom".*, "mp42".* };
var ftyp: box.Ftyp = .{
    .major_brand = "isom".*,
    .minor_version = 0,
    .compatible_brands = .fromOwnedSlice(&compatible_brands),
};

pub const Error = error{ UnsupportedMediaType, StreamNotFound } || Allocator.Error || Io.Writer.Error;
pub const OpenError = Io.File.OpenError || Allocator.Error;

allocator: Allocator,
file: Io.File.Writer,
moov: box.Moov,
streams: std.ArrayList(Stream),

pub const InitConfig = struct {};

const Stream = struct {
    id: u32,
    trak: *box.Trak,

    fn addSample(stream: *Stream, allocator: Allocator, packet: *const media.Packet, pos: u64) !void {
        var stbl = &stream.trak.mdia.minf.stbl;
        const duration: u32 = @intCast(packet.duration.?);

        try stbl.addSample(allocator, box.SampleMetadata{
            .dts = @intCast(packet.dts),
            .pts = @intCast(packet.pts),
            .duration = duration,
            .size = @intCast(packet.data.len),
            .is_sync = packet.flags.keyframe,
            .offset = 0,
        });

        try stbl.addChunk(allocator, 1, pos);
        stream.trak.mdia.mdhd.duration += duration;
    }
};

pub fn init(io: Io, allocator: Allocator, dir: ?Io.Dir, dest: []const u8, buffer: []u8, _: InitConfig) OpenError!Mp4Writer {
    const base_dir = dir orelse Io.Dir.cwd();
    const file = try base_dir.createFile(io, dest, .{ .truncate = true });

    return .{
        .allocator = allocator,
        .file = file.writer(io, buffer),
        .moov = .{
            .mvhd = .{ .timescale = default_timescale },
            .traks = .empty,
        },
        .streams = try .initCapacity(allocator, 2),
    };
}

pub fn deinit(self: *Mp4Writer, io: Io) void {
    self.file.file.close(io);
    self.moov.deinit(self.allocator);
    self.streams.deinit(self.allocator);
}

/// Writes the header (ftyp box + empty mdat)
pub fn writeHeader(self: *Mp4Writer) Io.Writer.Error!void {
    try ftyp.write(&self.file.interface);
    try box.Header.new(.mdat, 0).write(&self.file.interface);
}

/// Adds a new stream to the file.
pub fn addStream(self: *Mp4Writer, stream: *const media.Stream) Error!void {
    const trak = try self.moov.traks.addOne(self.allocator);
    trak.* = self.streamToTrak(stream) catch |err| {
        _ = self.moov.traks.swapRemove(self.streams.items.len);
        return err;
    };

    try self.streams.append(self.allocator, .{
        .id = stream.id,
        .trak = trak,
    });

    self.moov.mvhd.next_track_id += 1;
}

/// Writes a frame to the file.
///
/// The frame is written immediately to the file. Interleaving should be
/// implemented by the user.
pub fn writeFrame(self: *Mp4Writer, packet: media.Packet) Error!void {
    for (self.streams.items) |*stream| if (stream.id == packet.stream_id) {
        const pos = self.file.logicalPos();
        try self.file.interface.writeAll(packet.data);
        try stream.addSample(self.allocator, &packet, pos);
        return;
    };

    return error.StreamNotFound;
}

/// Writes the trailer (mp4 metadata).
///
/// After calling this function, there must be no other call to this
/// module except for `deinit`.
pub fn writeTrailer(self: *Mp4Writer) !void {
    const mdat_size: u32 = @intCast(self.file.logicalPos() -| ftyp.size());

    // Write moov
    var moov = &self.moov;
    for (moov.traks.items) |*trak| {
        trak.tkhd.duration = trak.mdia.mdhd.duration * moov.mvhd.timescale / trak.timescale();
        if (moov.mvhd.duration < trak.tkhd.duration) {
            moov.mvhd.duration = trak.tkhd.duration;
        }

        // Delete stss and ctts if empty
        if (trak.mediaType() == .video) {
            var stbl = &trak.mdia.minf.stbl;
            if (stbl.stss.?.samples.items.len == 0) {
                stbl.stss = null;
            }

            if (stbl.ctts.?.isEmpty()) {
                stbl.ctts.?.deinit(self.allocator);
                stbl.ctts = null;
            }
        }
    }
    try moov.write(&self.file.interface);

    try self.file.seekTo(ftyp.size());
    try self.file.interface.writeInt(u32, mdat_size, .big);
    try self.file.interface.flush();
}

fn streamToTrak(self: *Mp4Writer, stream: *const media.Stream) Error!box.Trak {
    const media_type = stream.mediaType();
    const sample_entry: box.SampleEntry = switch (media_type) {
        .video => .{
            .video = .{
                .data_reference_index = 1,
                .codec = stream.codec,
                .width = @intCast(stream.config.video.width),
                .height = @intCast(stream.config.video.height),
                .codec_config = stream.extra_data,
            },
        },
        .audio => .{
            .audio = .{
                .data_reference_index = 1,
                .codec = stream.codec,
                .samplerate = stream.config.audio.sample_rate,
                .channelcount = stream.config.audio.channels,
                .codec_config = stream.extra_data,
            },
        },
        else => return error.UnsupportedMediaType,
    };

    const hdlr_type: u32 = switch (media_type) {
        .video => 0x76696465, // "vide"
        .audio => 0x736F756E, // "soun"
        else => unreachable,
    };

    var dinf = try box.Dinf.init(self.allocator);
    errdefer dinf.deinit(self.allocator);

    var stbl = box.Stbl.empty;
    switch (media_type) {
        .audio => {
            stbl.ctts = null;
            stbl.stss = null;
        },
        else => {},
    }
    try stbl.addSampleEntry(self.allocator, sample_entry);
    errdefer stbl.deinit(self.allocator);

    return .{
        .tkhd = .{
            .track_id = self.moov.mvhd.next_track_id,
            .width = if (media_type == .video) sample_entry.video.width else 0,
            .height = if (media_type == .video) sample_entry.video.height else 0,
        },
        .mdia = .{
            .mdhd = .default(@intCast(stream.time_base.den)),
            .hdlr = .{
                .handler_type = hdlr_type,
                .name = &.{},
            },
            .minf = .{
                .dinf = dinf,
                .stbl = stbl,
                .handler = switch (media_type) {
                    .video => .{ .video = .{} },
                    .audio => .{ .audio = .{} },
                    else => unreachable,
                },
            },
        },
    };
}

const testing = std.testing;
const test_file = "test.mp4";
const Mp4Reader = @import("reader.zig");

test "init writer" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var mp4_writer = try init(testing.io, testing.allocator, tmp_dir.dir, test_file, &.{}, .{});
    defer mp4_writer.deinit(testing.io);
}

test "write valid empty file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var mp4_writer = try init(testing.io, testing.allocator, tmp_dir.dir, test_file, &.{}, .{});
    defer mp4_writer.deinit(testing.io);

    try testing.expectEqual({}, try mp4_writer.writeHeader());
    try testing.expectEqual({}, try mp4_writer.writeTrailer());

    var reader = try Mp4Reader.init(testing.io, testing.allocator, tmp_dir.dir, test_file);
    defer reader.deinit(testing.allocator);

    var iterator = reader.streamIterator();
    try testing.expectEqual(null, iterator.next());
}

test "write valid empty file with streams" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var mp4_writer = try init(testing.io, testing.allocator, tmp_dir.dir, test_file, &.{}, .{});
    defer mp4_writer.deinit(testing.io);

    try testing.expectEqual({}, try mp4_writer.writeHeader());

    const expected_stream1 = media.Stream{
        .codec = .h264,
        .id = 3,
        .time_base = .{ .num = 1, .den = 90000 },
        .config = .{ .video = .{ .width = 1920, .height = 1080 } },
    };

    const expected_stream2 = media.Stream{
        .codec = .aac,
        .id = 4,
        .time_base = .{ .num = 1, .den = 44100 },
        .config = .{ .audio = .{ .channels = 2, .sample_rate = 44100 } },
    };

    try testing.expectEqual({}, try mp4_writer.addStream(&expected_stream1));
    try testing.expectEqual({}, try mp4_writer.addStream(&expected_stream2));
    try testing.expectEqual({}, try mp4_writer.writeTrailer());

    var reader = try Mp4Reader.init(testing.io, testing.allocator, tmp_dir.dir, test_file);
    defer reader.deinit(testing.allocator);

    var iterator = reader.streamIterator();
    const stream1 = iterator.next().?;
    const stream2 = iterator.next().?;
    try testing.expectEqual(null, iterator.next());

    try testing.expectEqual(media.Codec.h264, stream1.codec);
    try testing.expectEqual(media.Codec.aac, stream2.codec);
}

test "write file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var mp4_writer = try init(testing.io, testing.allocator, tmp_dir.dir, test_file, &.{}, .{});
    defer mp4_writer.deinit(testing.io);

    try mp4_writer.writeHeader();

    const stream1 = media.Stream{
        .codec = .h264,
        .id = 3,
        .time_base = .{ .num = 1, .den = 44100 },
        .config = .{ .video = .{ .width = 1920, .height = 1080 } },
    };

    const stream2 = media.Stream{
        .codec = .aac,
        .id = 4,
        .time_base = .{ .num = 1, .den = 44100 },
        .config = .{ .audio = .{ .channels = 2, .sample_rate = 44100 } },
    };

    try mp4_writer.addStream(&stream1);
    try mp4_writer.addStream(&stream2);

    const samples = [_][]const u8{
        &.{ 0x01, 0x02, 0x03, 0x04, 0x05 },
        &.{ 0x06, 0x07, 0x08, 0x08, 0x09 },
        &.{ 0x10, 0x11, 0x12, 0x13, 0x14 },
        &.{ 0x0a, 0x0b, 0x0c },
        &.{ 0x0d, 0x0e, 0x0f },
    };

    for (samples, 0..) |sample, idx| {
        var packet: media.Packet = .fromSlice(sample);
        packet.dts = @intCast(idx);
        packet.pts = @intCast(idx);
        packet.duration = 1;
        packet.stream_id = if (idx < 3) stream1.id else stream2.id;

        try mp4_writer.writeFrame(packet);
    }

    try mp4_writer.writeTrailer();

    var reader = try Mp4Reader.init(testing.io, testing.allocator, tmp_dir.dir, test_file);
    defer reader.deinit(testing.allocator);

    var iterator = reader.streamIterator();
    try testing.expect(iterator.next() != null);
    try testing.expect(iterator.next() != null);
    try testing.expect(iterator.next() == null);

    var frame_it = try reader.frameIterator(testing.allocator, &.{});
    defer frame_it.deinit(testing.allocator);

    var idx: usize = 0;
    var video_idx: usize = 0;
    var audio_idx: usize = 0;
    while (idx < 5) : (idx += 1) {
        var packet = try frame_it.next(testing.allocator);
        try testing.expect(packet != null);
        defer packet.?.deinit(testing.allocator);

        switch (idx) {
            0, 2, 4 => {
                try testing.expect(packet.?.dts == video_idx);
                try testing.expect(packet.?.pts == video_idx);
                try testing.expectEqualSlices(u8, samples[video_idx], packet.?.data);

                video_idx += 1;
            },
            else => {
                try testing.expect(packet.?.dts == audio_idx);
                try testing.expect(packet.?.pts == audio_idx);
                try testing.expectEqualSlices(u8, samples[audio_idx + 3], packet.?.data);

                audio_idx += 1;
            },
        }
        try testing.expectEqual(1, packet.?.duration.?);
    }

    try testing.expectEqual(null, try frame_it.next(testing.allocator));
}
