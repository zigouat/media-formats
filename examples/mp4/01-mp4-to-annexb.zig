const std = @import("std");
const mp4 = @import("formats").mp4;
const media = @import("media");

const Box = mp4.Box;

/// This example shows how to read an MP4 file and write it back to disk in Annex B format, which is a common format for H.264/H.265 video streams.
/// The code reads the MP4 file, extracts the video track, and writes the video data in Annex B format to a new file.
pub fn main(init: std.process.Init) !void {
    var args_iterator = init.minimal.args.iterate();
    defer args_iterator.deinit();

    _ = args_iterator.skip(); // Skip the program name

    const source = args_iterator.next();
    if (source == null) {
        std.debug.print("Usage: mp4_to_annexb <input.mp4>\n", .{});
        return;
    }

    var reader = try mp4.Reader.init(init.io, init.gpa, null, source.?);
    defer reader.deinit(init.gpa);

    // Get the video track id
    var video_stream: ?media.Stream = null;
    var stream_iterator = reader.streamIterator();
    while (stream_iterator.next()) |stream| if (stream.mediaType() == .video and (stream.codec == .h264 or stream.codec == .h265)) {
        video_stream = stream;
        break;
    };

    if (video_stream == null) {
        std.log.err("No h264/h265 video track found in the MP4 file", .{});
        return;
    }

    // Get the prefix length of each NAL unit
    const codec_config = video_stream.?.extra_data;
    const nalu_length = switch (video_stream.?.codec) {
        .h264 => blk: {
            const config = try media.codecs.h264.DecoderConfigurationRecord.parse(codec_config);
            break :blk config.length_size;
        },
        .h265 => blk: {
            if (codec_config.len < 22) return error.InvalidCodecConfig;
            break :blk codec_config[21] & 0x03 + 1;
        },
        else => return error.UnsupportedCodec,
    };

    const out_path = args_iterator.next() orelse switch (video_stream.?.codec) {
        .h264 => "test.h264",
        .h265 => "test.h265",
        else => unreachable,
    };

    var out_file = try std.Io.Dir.cwd().createFile(init.io, out_path, .{ .truncate = true });
    defer out_file.close(init.io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = out_file.writer(init.io, &write_buffer);

    switch (video_stream.?.codec) {
        .h264 => {
            var dcr = try media.codecs.h264.DecoderConfigurationRecord.parse(codec_config);
            var it = dcr.iterateParameterSets();
            while (try it.next()) |nalu| {
                try file_writer.interface.writeAll(&media.codecs.h264.annexb_start_code);
                try file_writer.interface.writeAll(nalu);
            }
        },
        else => {},
    }

    var buffer: [4096]u8 = undefined;
    var iterator = try reader.frameIterator(init.gpa, &buffer);
    defer iterator.deinit(init.gpa);
    while (true) {
        const maybe_packet = try iterator.next(init.gpa);
        if (maybe_packet == null) break;

        var packet = maybe_packet.?;
        defer packet.deinit(init.gpa);

        if (packet.stream_id != video_stream.?.id) continue;

        var sample_reader = std.Io.Reader.fixed(packet.data);
        while (true) {
            const nalu_size = sample_reader.takeVarInt(u32, .big, nalu_length) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            try file_writer.interface.writeAll(&media.codecs.h264.annexb_start_code);
            try file_writer.interface.writeAll(try sample_reader.take(nalu_size));
        }
    }

    std.log.info("Done writing file", .{});
}
