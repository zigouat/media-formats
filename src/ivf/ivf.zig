const std = @import("std");
const media = @import("media");

const Io = std.Io;

const max_frame_size = 5 * 1024 * 1024; // 5 MB

const Header = struct {
    signature: [4]u8,
    version: u16,
    length: u16,
    codec_fourcc: u32,
    width: u16,
    height: u16,
    timebase_den: u32,
    timebase_num: u32,
    nb_frames: u32,
    _unused: u32 = 0,

    fn parse(reader: *Io.Reader) !Header {
        var header: Header = undefined;
        header.signature = (try reader.takeArray(4)).*;
        if (!std.mem.eql(u8, &header.signature, "DKIF")) {
            return error.InvalidSignature;
        }

        header.version = try reader.takeInt(u16, .little);
        header.length = try reader.takeInt(u16, .little);
        header.codec_fourcc = try reader.takeInt(u32, .big);
        header.width = try reader.takeInt(u16, .little);
        header.height = try reader.takeInt(u16, .little);
        header.timebase_den = try reader.takeInt(u32, .little);
        header.timebase_num = try reader.takeInt(u32, .little);
        header.nb_frames = try reader.takeInt(u32, .little);
        header._unused = try reader.takeInt(u32, .little);

        return header;
    }

    fn toStream(header: *const Header) media.Stream {
        const codec: media.Codec = switch (header.codec_fourcc) {
            0x56503830 => .vp8, // 'VP80'
            0x56503930 => .vp9, // 'VP90'
            0x41563130 => .av1, // 'AV10'
            else => .unknown,
        };

        return .{
            .id = 1,
            .codec = codec,
            .config = .{ .video = .{ .width = header.width, .height = header.height } },
            .time_base = .{ .num = header.timebase_num, .den = header.timebase_den },
            .nb_frames = header.nb_frames,
        };
    }
};

pub const Reader = struct {
    reader: *Io.Reader,
    stream: media.Stream,

    pub fn init(reader: *Io.Reader) !Reader {
        var ivf_reader: Reader = undefined;
        ivf_reader.stream = (try Header.parse(reader)).toStream();
        ivf_reader.reader = reader;
        return ivf_reader;
    }

    /// Gets the next frame from the stream.
    ///
    /// Note that the returned packet doesn't have a duration.
    pub fn next(ivf_reader: *Reader, allocator: std.mem.Allocator) !?media.Packet {
        const size = ivf_reader.reader.takeInt(u32, .little) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };

        const timestamp = try ivf_reader.reader.takeInt(u64, .little);
        if (size > max_frame_size) {
            @branchHint(.cold);
            return error.FrameTooLarge;
        }

        var packet = try media.Packet.alloc(allocator, size);
        const buffer = packet.mutableData().?;
        try ivf_reader.reader.readSliceAll(buffer);
        packet.dts = @bitCast(timestamp);
        packet.pts = @bitCast(timestamp);
        packet.stream_id = ivf_reader.stream.id;
        return packet;
    }
};

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "Header: parse" {
    const header = [_]u8{
        0x44, 0x4b, 0x49, 0x46, 0x00, 0x00, 0x20, 0x00,
        0x56, 0x50, 0x38, 0x30, 0x80, 0x07, 0x30, 0x03,
        0x19, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0xf0, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    var reader = Io.Reader.fixed(&header);
    var parsed_header = try Header.parse(&reader);

    try testing.expectEqualStrings("DKIF", &parsed_header.signature);
    try testing.expect(parsed_header.version == 0);
    try testing.expect(parsed_header.length == 32);
    try testing.expectEqual(0x56503830, parsed_header.codec_fourcc); //VP80
    try testing.expect(parsed_header.width == 1920);
    try testing.expect(parsed_header.height == 816);
    try testing.expectEqual(1, parsed_header.timebase_num);
    try testing.expectEqual(25, parsed_header.timebase_den);
    try testing.expectEqual(1008, parsed_header.nb_frames);
}

test "Header: wrong signature" {
    const header = [_]u8{ 0x44, 0x4f, 0x49, 0x46, 0x00, 0x00, 0x20, 0x00 };
    var reader = Io.Reader.fixed(&header);
    try testing.expectError(error.InvalidSignature, Header.parse(&reader));
}

test "Header: toStream" {
    const header = Header{
        .signature = "DKIF".*,
        .version = 0,
        .length = 32,
        .codec_fourcc = 0x56503830, // VP80
        .width = 1920,
        .height = 1080,
        .timebase_den = 25,
        .timebase_num = 1,
        .nb_frames = 1008,
    };

    const stream = header.toStream();
    try testing.expect(stream.codec == .vp8);
    try testing.expect(stream.config.video.width == 1920);
    try testing.expect(stream.config.video.height == 1080);
    try testing.expect(stream.time_base.num == 1);
    try testing.expect(stream.time_base.den == 25);
    try testing.expect(stream.nb_frames == 1008);
}

test "Reader: read all frames" {
    var fs = try std.Io.Dir.cwd().openFile(testing.io, "fixtures/ivf/test_vp8_10.ivf", .{ .mode = .read_only });
    defer fs.close(testing.io);

    var buffer: [1024]u8 = @splat(0);
    var reader = fs.readerStreaming(testing.io, &buffer);
    var ivf_reader = try Reader.init(&reader.interface);

    try testing.expectEqual(320, ivf_reader.stream.config.video.width);
    try testing.expectEqual(240, ivf_reader.stream.config.video.height);
    try testing.expectEqual(10, ivf_reader.stream.nb_frames);

    const expected = [_]struct { i64, u64 }{
        .{ 0, 4756 },
        .{ 1, 999 },
        .{ 2, 877 },
        .{ 3, 703 },
        .{ 4, 917 },
        .{ 5, 864 },
        .{ 6, 955 },
        .{ 7, 1331 },
        .{ 8, 1208 },
        .{ 9, 910 },
    };

    for (expected) |exp| {
        var packet = (try ivf_reader.next(testing.allocator)).?;
        defer packet.deinit(testing.allocator);

        try testing.expectEqual(exp.@"0", packet.pts);
        try testing.expectEqual(exp.@"1", packet.data.len);
    }

    try testing.expect(try ivf_reader.next(testing.allocator) == null);
}
