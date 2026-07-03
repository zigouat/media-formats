const std = @import("std");
const Codec = @import("media").Codec;

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

pub const BoxType = enum(u32) {
    ftyp = 0x66747970,
    moov = 0x6D6F6F76,
    mvhd = 0x6D766864,
    trak = 0x7472616B,
    mvex = 0x6D766578,
    mehd = 0x6D656864,
    trex = 0x74726578,
    tkhd = 0x746B6864,
    mdia = 0x6D646961,
    mdhd = 0x6D646864,
    hdlr = 0x68646C72,
    minf = 0x6D696E66,
    dinf = 0x64696E66,
    dref = 0x64726566,
    @"url " = 0x75726C20,
    stbl = 0x7374626C,
    stsd = 0x73747364,
    stts = 0x73747473,
    ctts = 0x63747473,
    stss = 0x73747373,
    stsz = 0x7374737A,
    stz2 = 0x73747A32,
    stsc = 0x73747363,
    stco = 0x7374636F,
    co64 = 0x636F3634,
    avc1 = 0x61766331,
    avc3 = 0x61766333,
    avcC = 0x61766343,
    hvc1 = 0x68766331,
    hev1 = 0x68657631,
    hvcC = 0x68766343,
    mp4a = 0x6D703461,
    esds = 0x65736473,
    uuid = 0x75756964,
    mdat = 0x6D646174,
    vmhd = 0x766D6864,
    smhd = 0x736D6864,
    _,
};

pub const WriteError = std.Io.Writer.Error;

pub const ParseError = error{
    InvalidFtypBox,
    InvalidMoovBox,
    InvalidMvhdBox,
    InvalidTrakBox,
    InvalidTkhdBox,
    InvalidMehdBox,
    InvalidTrexBox,
    InvalidMdiaBox,
    InvalidMdhdBox,
    InvalidHdlrBox,
    InvalidMinfBox,
    InvalidDinfBox,
    InvalidDrefBox,
    InvalidDataEntryUrlBox,
    InvalidStblBox,
    InvalidStsdBox,
    InvalidSttsBox,
    InvalidCttsBox,
    InvalidStssBox,
    InvalidStszBox,
    InvalidStscBox,
    InvalidStcoBox,
    InvalidCo64Box,
    InvalidVideoSampleEntry,
    InvalidAudioSampleEntry,
};

pub const ReadError = ParseError || std.Io.Reader.Error || Allocator.Error;

pub const SampleEntryWriteError = WriteError || error{
    InvalidVideoSampleEntry,
    InvalidAudioSampleEntry,
};

/// The type of a track, determined by the handler type in the Hdlr box.
pub const TrakType = enum { video, audio, hint, unknown };

/// Represents the header of an MP4 box.
pub const Header = struct {
    pub const box_header_size: usize = 8;
    pub const full_box_header_size: usize = 12;

    type: BoxType,
    size: u64,
    uuid: ?[16]u8,

    pub fn new(box_type: BoxType, size: u64) Header {
        return .{
            .type = box_type,
            .size = size,
            .uuid = null,
        };
    }

    pub fn payloadSize(self: *const Header) usize {
        return @as(usize, @intCast(self.size)) - (if (self.type == .uuid) @as(usize, 16) else @as(usize, 0)) -| Header.box_header_size;
    }

    pub fn parse(reader: *Reader) ReadError!Header {
        var size: u64 = try reader.takeInt(u32, .big);
        const box_type: BoxType = @enumFromInt(try reader.takeInt(u32, .big));

        if (size == 1) {
            size = try reader.takeInt(u64, .big);
        }

        var uuid: ?[16]u8 = null;
        if (box_type == .uuid) {
            @branchHint(.unlikely);
            uuid = @splat(0);
            @memcpy(&uuid.?, try reader.take(16));
        }

        return .{
            .type = box_type,
            .size = size,
            .uuid = uuid,
        };
    }

    pub fn write(self: *const Header, writer: *std.Io.Writer) WriteError!void {
        if (self.size > std.math.maxInt(u32)) {
            @branchHint(.unlikely);
            try writer.writeInt(u32, 1, .big);
            try writer.writeInt(u32, @intFromEnum(self.type), .big);
            try writer.writeInt(u64, self.size, .big);
        } else {
            try writer.writeInt(u32, @intCast(self.size), .big);
            try writer.writeInt(u32, @intFromEnum(self.type), .big);
        }

        if (self.type == .uuid) try writer.writeAll(&self.uuid.?);
    }
};

/// Represents the File Type Box (ftyp) which specifies the file type and compatible brands.
pub const Ftyp = struct {
    major_brand: [4]u8,
    minor_version: u32,
    compatible_brands: std.ArrayList([4]u8),

    pub fn size(self: *const Ftyp) usize {
        return Header.box_header_size + 8 + self.compatible_brands.items.len * 4;
    }

    pub fn parse(allocator: Allocator, reader: *std.Io.Reader, box_size: usize) ReadError!Ftyp {
        if (@rem(box_size, 4) != 0) {
            return error.InvalidFtypBox;
        }

        var major_brand: [4]u8 = undefined;
        @memcpy(&major_brand, try reader.take(4));

        const minor_version = try reader.takeInt(u32, .big);
        var compatible_brands = try std.ArrayList([4]u8).initCapacity(allocator, (box_size - 8) / 4);
        errdefer compatible_brands.deinit(allocator);
        for (std.mem.bytesAsSlice([4]u8, try reader.take(box_size - 8))) |brand| try compatible_brands.append(allocator, brand);

        return .{
            .major_brand = major_brand,
            .minor_version = minor_version,
            .compatible_brands = compatible_brands,
        };
    }

    pub fn write(self: *const Ftyp, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.ftyp, self.size());
        try header.write(writer);
        _ = try writer.write(&self.major_brand);
        try writer.writeInt(u32, self.minor_version, .big);
        for (self.compatible_brands.items) |brand| {
            _ = try writer.write(&brand);
        }
    }

    pub fn deinit(self: *Ftyp, allocator: Allocator) void {
        self.compatible_brands.deinit(allocator);
    }
};

/// Represents the Movie Box (moov) which contains metadata about the movie, including the Movie Header Box (mvhd).
pub const Moov = struct {
    mvhd: Mvhd,
    traks: std.ArrayList(Trak),
    mvex: ?Mvex = null,

    pub fn size(self: *const Moov) usize {
        const mvex_size = if (self.mvex) |*box| box.size() else 0;
        var traks_size: usize = 0;
        for (self.traks.items) |trak| traks_size += trak.size();
        return Header.box_header_size + self.mvhd.size() + traks_size + mvex_size;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *std.Io.Reader) ReadError!Moov {
        var offset: u64 = 0;
        var mvhd: ?Mvhd = null;
        var traks: std.ArrayList(Trak) = .empty;
        errdefer {
            for (traks.items) |*trak| trak.deinit(allocator);
            traks.deinit(allocator);
        }

        while (offset < header.payloadSize()) {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;
            switch (inner_header.type) {
                .mvhd => mvhd = try Mvhd.parse(inner_header, reader),
                .trak => try traks.append(allocator, try Trak.parse(allocator, inner_header, reader)),
                else => try reader.discardAll(inner_header.payloadSize()),
            }
        }

        if (mvhd == null) return error.InvalidMoovBox;
        return .{ .mvhd = mvhd.?, .traks = traks };
    }

    pub fn write(self: *const Moov, writer: *std.Io.Writer) SampleEntryWriteError!void {
        const header = Header.new(.moov, self.size());
        try header.write(writer);
        try self.mvhd.write(writer);
        for (self.traks.items) |*trak| try trak.write(writer);
    }

    pub fn deinit(self: *Moov, allocator: Allocator) void {
        for (self.traks.items) |*trak| trak.deinit(allocator);
        self.traks.deinit(allocator);
    }
};

/// This box defines overall information which is media‐independent, and relevant to the entire
/// presentation considered as a whole.
pub const Mvhd = struct {
    version: u8 = 0,
    creation_time: u64 = 0,
    modification_time: u64 = 0,
    timescale: u32,
    duration: u64 = 0,
    next_track_id: u32 = 1,

    pub fn size(self: *const Mvhd) usize {
        return Header.full_box_header_size + 80 + @as(u8, if (self.version == 1) 28 else 16);
    }

    pub fn parse(header: Header, reader: *std.Io.Reader) ReadError!Mvhd {
        const version = try reader.takeByte();
        var mvhd = Mvhd{ .version = version, .timescale = 0 };

        if (mvhd.size() != header.size) return error.InvalidMvhdBox;

        reader.toss(3); // flags

        if (version == 1) {
            mvhd.creation_time = try reader.takeInt(u64, .big);
            mvhd.modification_time = try reader.takeInt(u64, .big);
            mvhd.timescale = try reader.takeInt(u32, .big);
            mvhd.duration = try reader.takeInt(u64, .big);
        } else {
            mvhd.creation_time = try reader.takeInt(u32, .big);
            mvhd.modification_time = try reader.takeInt(u32, .big);
            mvhd.timescale = try reader.takeInt(u32, .big);
            mvhd.duration = try reader.takeInt(u32, .big);
        }

        _ = try reader.discard(.limited(76));
        mvhd.next_track_id = try reader.takeInt(u32, .big);
        return mvhd;
    }

    pub fn write(self: *const Mvhd, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.mvhd, self.size());
        try header.write(writer);
        try writer.writeByte(self.version);
        try writer.writeInt(u24, 0, .big); // flags

        if (self.version == 1) {
            try writer.writeInt(u64, self.creation_time, .big);
            try writer.writeInt(u64, self.modification_time, .big);
            try writer.writeInt(u32, self.timescale, .big);
            try writer.writeInt(u64, self.duration, .big);
        } else {
            try writer.writeInt(u32, @intCast(self.creation_time), .big);
            try writer.writeInt(u32, @intCast(self.modification_time), .big);
            try writer.writeInt(u32, self.timescale, .big);
            try writer.writeInt(u32, @intCast(self.duration), .big);
        }

        try writer.writeInt(u32, 0x00010000, .big); // rate
        try writer.writeInt(u16, 0x0100, .big); // volume

        const reserved: [10]u8 = @splat(0);
        try writer.writeAll(&reserved); // reserved

        const matrix = [9]u32{
            0x00010000, 0,          0,
            0,          0x00010000, 0,
            0,          0,          0x40000000,
        };
        try writer.writeSliceEndian(u32, &matrix, .big);

        const predefined: [24]u8 = @splat(0);
        _ = try writer.writeAll(&predefined); // pre_defined

        try writer.writeInt(u32, self.next_track_id, .big);
    }
};

/// A container box for a single track of a presentation.
pub const Trak = struct {
    tkhd: Tkhd,
    mdia: Mdia,

    pub fn size(self: *const Trak) usize {
        return Header.box_header_size + self.tkhd.size() + self.mdia.size();
    }

    /// Parses the Track Box (trak).
    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Trak {
        var offset: u64 = 0;
        var tkhd: ?Tkhd = null;
        var mdia: ?Mdia = null;
        errdefer if (mdia) |*box| box.deinit(allocator);

        while (offset < header.payloadSize()) {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;
            switch (inner_header.type) {
                .tkhd => tkhd = try Tkhd.parse(reader, inner_header),
                .mdia => mdia = try Mdia.parse(allocator, inner_header, reader),
                else => try reader.discardAll(inner_header.payloadSize()),
            }
        }

        if (tkhd == null or mdia == null) return error.InvalidTrakBox;
        return .{ .tkhd = tkhd.?, .mdia = mdia.? };
    }

    pub fn write(self: *const Trak, writer: *std.Io.Writer) SampleEntryWriteError!void {
        const header = Header.new(.trak, self.size());
        try header.write(writer);
        try self.tkhd.write(writer);
        try self.mdia.write(writer);
    }

    pub fn deinit(self: *Trak, allocator: Allocator) void {
        self.mdia.deinit(allocator);
    }

    /// Gets the media type of the track.
    pub fn mediaType(self: *const Trak) TrakType {
        switch (self.mdia.hdlr.handler_type) {
            0x76696465 => return .video, // 'vide'
            0x736F756E => return .audio, // 'soun'
            0x6D696E65 => return .hint, // 'mine'
            else => return .unknown,
        }
    }

    /// Returns the width of the track in pixels, converting from fixed-point 16.16 format.
    pub fn width(self: *const Trak) u16 {
        return self.tkhd.width;
    }

    /// Returns the height of the track in pixels, converting from fixed-point 16.16 format.
    pub fn height(self: *const Trak) u16 {
        return self.tkhd.height;
    }

    /// Returns the sample count.
    pub fn sampleCount(self: *const Trak) usize {
        return self.mdia.minf.stbl.stsz.sample_count;
    }

    /// Returns the timescale of the track.
    pub fn timescale(self: *const Trak) u32 {
        return self.mdia.mdhd.timescale;
    }

    /// Returns the codec of the track, determined by the first sample entry in the stsd box.
    pub fn codec(self: *const Trak) Codec {
        const stsd = &self.mdia.minf.stbl.stsd;
        if (stsd.entries.items.len == 0) return .unknown;

        return switch (stsd.entries.items[0]) {
            .video => |v| v.codec,
            .audio => |a| a.codec,
            else => .unknown,
        };
    }

    pub fn sampleIterator(self: *const Trak) SampleIterator {
        return SampleIterator.init(&self.mdia.minf.stbl);
    }
};

pub const Mvex = struct {
    mehd: ?Mehd = null,
    trex: std.ArrayList(Trex) = .empty,

    pub fn size(self: *const Mvex) usize {
        var trex_size: usize = 0;
        for (self.trex.items) |*trex| trex_size += trex.size();
        return Header.box_header_size + trex_size + if (self.mehd) |*box| box.size() else 0;
    }

    pub fn parse(allocator: Allocator, reader: *Reader, header: Header) ReadError!Mvex {
        var offset: u64 = 0;
        var mvex = Mvex{ .mehd = null, .trex = .empty };
        errdefer mvex.deinit(allocator);

        while (offset < header.payloadSize()) {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;

            switch (inner_header.type) {
                .mehd => mvex.mehd = try Mehd.parse(reader, inner_header),
                .trex => try mvex.trex.append(allocator, try Trex.parse(reader, inner_header)),
                else => try reader.discardAll(inner_header.payloadSize()),
            }
        }

        return mvex;
    }

    pub fn write(self: *const Mvex, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.mvex, self.size());
        try header.write(writer);
        if (self.mehd) |*box| try box.write(writer);
        for (self.trex.items) |*trex| try trex.write(writer);
    }

    pub fn deinit(self: *Mvex, allocator: Allocator) void {
        self.trex.deinit(allocator);
    }
};

pub const Mehd = struct {
    version: u8,
    fragment_duration: u64,

    pub fn size(self: *const Mehd) usize {
        return Header.full_box_header_size + (self.version + 1) * 4;
    }

    pub fn parse(reader: *Reader, header: Header) ReadError!Mehd {
        var mhed = Mehd{ .version = try reader.takeByte(), .fragment_duration = 0 };
        if (mhed.size() != header.size) return error.InvalidMehdBox;

        try reader.discardAll(3); // flags

        if (mhed.version == 1) {
            mhed.fragment_duration = try reader.takeInt(u64, .big);
        } else {
            mhed.fragment_duration = try reader.takeInt(u32, .big);
        }

        return mhed;
    }

    pub fn write(self: *const Mehd, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.mehd, self.size());
        try header.write(writer);
        try writer.writeByte(self.version);
        try writer.writeInt(u24, 0, .big); // flags

        if (self.version == 1) {
            try writer.writeInt(u64, self.fragment_duration, .big);
        } else {
            try writer.writeInt(u32, @intCast(self.fragment_duration), .big);
        }
    }
};

pub const Trex = struct {
    track_id: u32,
    default_sample_description_index: u32,
    default_sample_duration: u32,
    default_sample_size: u32,
    default_sample_flags: u32,

    pub fn size(_: *const Trex) usize {
        return Header.full_box_header_size + 20;
    }

    pub fn parse(reader: *Reader, header: Header) ReadError!Trex {
        var trex = Trex{
            .track_id = 0,
            .default_sample_description_index = 0,
            .default_sample_duration = 0,
            .default_sample_size = 0,
            .default_sample_flags = 0,
        };

        if (trex.size() != header.size) return error.InvalidTrexBox;

        try reader.discardAll(4); // version + flags
        trex.track_id = try reader.takeInt(u32, .big);
        trex.default_sample_description_index = try reader.takeInt(u32, .big);
        trex.default_sample_duration = try reader.takeInt(u32, .big);
        trex.default_sample_size = try reader.takeInt(u32, .big);
        trex.default_sample_flags = try reader.takeInt(u32, .big);

        return trex;
    }

    pub fn write(self: *const Trex, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.trex, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // version + flags
        try writer.writeInt(u32, self.track_id, .big);
        try writer.writeInt(u32, self.default_sample_description_index, .big);
        try writer.writeInt(u32, self.default_sample_duration, .big);
        try writer.writeInt(u32, self.default_sample_size, .big);
        try writer.writeInt(u32, self.default_sample_flags, .big);
    }
};

/// The Track Header Box (tkhd) contains information about a track, including its dimensions, duration, and creation/modification times.
pub const Tkhd = struct {
    version: u8 = 0,
    creation_time: u64 = 0,
    modification_time: u64 = 0,
    track_id: u32,
    duration: u64 = 0,
    width: u16,
    height: u16,

    pub const empty = Tkhd{
        .version = 0,
        .creation_time = 0,
        .modification_time = 0,
        .track_id = 0,
        .duration = 0,
        .width = 0,
        .height = 0,
    };

    pub fn size(self: *const Tkhd) usize {
        return Header.full_box_header_size + 60 + @as(u8, if (self.version == 1) 32 else 20);
    }

    pub fn parse(reader: *Reader, header: Header) ReadError!Tkhd {
        const version = try reader.takeByte();
        var tkhd = Tkhd{
            .version = version,
            .creation_time = 0,
            .modification_time = 0,
            .track_id = 0,
            .duration = 0,
            .width = 0,
            .height = 0,
        };

        if (tkhd.size() != header.size) return error.InvalidTkhdBox;

        reader.toss(3); // flags

        if (version == 1) {
            tkhd.creation_time = try reader.takeInt(u64, .big);
            tkhd.modification_time = try reader.takeInt(u64, .big);
            tkhd.track_id = try reader.takeInt(u32, .big);
            reader.toss(4); // reserved
            tkhd.duration = try reader.takeInt(u64, .big);
        } else {
            tkhd.creation_time = try reader.takeInt(u32, .big);
            tkhd.modification_time = try reader.takeInt(u32, .big);
            tkhd.track_id = try reader.takeInt(u32, .big);
            reader.toss(4); // reserved
            tkhd.duration = try reader.takeInt(u32, .big);
        }

        _ = try reader.discard(.limited(52)); // reserved + matrix
        tkhd.width = @intCast(try reader.takeInt(u32, .big) >> 16);
        tkhd.height = @intCast(try reader.takeInt(u32, .big) >> 16);

        return tkhd;
    }

    pub fn write(self: *const Tkhd, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.tkhd, self.size());
        try header.write(writer);
        try writer.writeByte(self.version);
        try writer.writeInt(u24, 0, .big); // flags

        if (self.version == 1) {
            try writer.writeInt(u64, self.creation_time, .big);
            try writer.writeInt(u64, self.modification_time, .big);
            try writer.writeInt(u32, self.track_id, .big);
            try writer.writeInt(u32, 0, .big); // reserved
            try writer.writeInt(u64, self.duration, .big);
        } else {
            try writer.writeInt(u32, @intCast(self.creation_time), .big);
            try writer.writeInt(u32, @intCast(self.modification_time), .big);
            try writer.writeInt(u32, self.track_id, .big);
            try writer.writeInt(u32, 0, .big); // reserved
            try writer.writeInt(u32, @intCast(self.duration), .big);
        }

        const reserved: [16]u8 = @splat(0);
        _ = try writer.writeAll(&reserved); // reserved

        const matrix = [9]u32{
            0x00010000, 0,          0,
            0,          0x00010000, 0,
            0,          0,          0x40000000,
        };
        try writer.writeSliceEndian(u32, &matrix, .big);

        try writer.writeInt(u32, @as(u32, self.width) << 16, .big);
        try writer.writeInt(u32, @as(u32, self.height) << 16, .big);
    }
};

/// The Media Box (mdia) contains all the information about the media data in a track.
pub const Mdia = struct {
    mdhd: Mdhd,
    hdlr: Hdlr,
    minf: Minf,

    pub fn size(self: *const Mdia) usize {
        return Header.box_header_size + self.mdhd.size() + self.hdlr.size() + self.minf.size();
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Mdia {
        var offset: u64 = 0;
        var mdhd: ?Mdhd = null;
        var hdlr: ?Hdlr = null;
        errdefer if (hdlr) |*box| box.deinit(allocator);

        var minf: ?Minf = null;
        errdefer if (minf) |*box| box.deinit(allocator);

        while (offset < header.payloadSize()) {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;
            switch (inner_header.type) {
                .mdhd => mdhd = try Mdhd.parse(inner_header, reader),
                .hdlr => hdlr = try Hdlr.parse(allocator, inner_header, reader),
                .minf => minf = try Minf.parse(allocator, inner_header, reader),
                else => _ = try reader.discard(.limited(inner_header.payloadSize())),
            }
        }

        if (mdhd == null or hdlr == null or minf == null) return error.InvalidMdiaBox;
        return .{ .mdhd = mdhd.?, .hdlr = hdlr.?, .minf = minf.? };
    }

    pub fn write(self: *const Mdia, writer: *std.Io.Writer) SampleEntryWriteError!void {
        const header = Header.new(.mdia, self.size());
        try header.write(writer);
        try self.mdhd.write(writer);
        try self.hdlr.write(writer);
        try self.minf.write(writer);
    }

    pub fn deinit(self: *Mdia, allocator: Allocator) void {
        self.hdlr.deinit(allocator);
        self.minf.deinit(allocator);
    }
};

/// The Media Header Box (mdhd) contains information about the media data in a track, including the timescale and duration.
pub const Mdhd = struct {
    version: u8,
    timescale: u32,
    duration: u64,
    language: [3]u8,

    pub fn default(timescale: u32) Mdhd {
        return .{
            .timescale = timescale,
            .duration = 0,
            .language = [_]u8{ 'u', 'n', 'd' },
            .version = 0,
        };
    }

    pub fn size(self: *const Mdhd) usize {
        return Header.full_box_header_size + @as(u8, if (self.version == 1) 28 else 16) + 4;
    }

    pub fn parse(header: Header, reader: *Reader) ReadError!Mdhd {
        const version = try reader.takeByte();
        var mdhd = Mdhd{
            .version = version,
            .timescale = 0,
            .duration = 0,
            .language = undefined,
        };

        if (mdhd.size() != header.size) return error.InvalidMdhdBox;

        reader.toss(3); // flags
        if (version == 1) {
            reader.toss(16);
            mdhd.timescale = try reader.takeInt(u32, .big);
            mdhd.duration = try reader.takeInt(u64, .big);
        } else {
            reader.toss(8);
            mdhd.timescale = try reader.takeInt(u32, .big);
            mdhd.duration = try reader.takeInt(u32, .big);
        }

        const language_bits = try reader.takeInt(u16, .big);
        mdhd.language[0] = @intCast(((language_bits >> 10) & 0x1F) + 0x60);
        mdhd.language[1] = @intCast(((language_bits >> 5) & 0x1F) + 0x60);
        mdhd.language[2] = @intCast(((language_bits >> 0) & 0x1F) + 0x60);

        reader.toss(2); // pre_defined

        return mdhd;
    }

    pub fn write(self: *const Mdhd, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.mdhd, self.size());
        try header.write(writer);
        try writer.writeByte(self.version);
        try writer.writeInt(u24, 0, .big); // flags

        if (self.version == 1) {
            try writer.writeInt(u64, 0, .big); // creation_time
            try writer.writeInt(u64, 0, .big); // modification_time
            try writer.writeInt(u32, self.timescale, .big);
            try writer.writeInt(u64, self.duration, .big);
        } else {
            try writer.writeInt(u32, 0, .big); // creation_time
            try writer.writeInt(u32, 0, .big); // modification_time
            try writer.writeInt(u32, self.timescale, .big);
            try writer.writeInt(u32, @intCast(self.duration), .big);
        }

        const language_bits: u16 =
            (@as(u16, self.language[0] - 0x60) << 10) |
            (@as(u16, self.language[1] - 0x60) << 5) |
            @as(u16, self.language[2] - 0x60);
        try writer.writeInt(u16, language_bits, .big);
        try writer.writeInt(u16, 0, .big); // pre_defined
    }
};

/// The Handler Reference Box (hdlr) specifies the type of media data in a track, which is used to determine how to interpret the media data.
pub const Hdlr = struct {
    handler_type: u32,
    name: []u8,

    pub fn size(self: *const Hdlr) usize {
        return Header.full_box_header_size + 20 + self.name.len + 1;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Hdlr {
        var hdlr = Hdlr{
            .handler_type = 0,
            .name = &.{},
        };

        if (header.size < hdlr.size()) return error.InvalidHdlrBox;

        _ = try reader.discard(.limited(8)); // version + flags + pre_defined
        hdlr.handler_type = try reader.takeInt(u32, .big);
        _ = try reader.discard(.limited(12)); // reserved

        const name_size = header.payloadSize() - 25;
        hdlr.name = try allocator.alloc(u8, name_size);
        errdefer hdlr.deinit(allocator);
        @memcpy(hdlr.name, try reader.take(name_size));
        _ = try reader.takeByte(); // null terminator

        return hdlr;
    }

    pub fn write(self: *const Hdlr, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.hdlr, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // flags
        try writer.writeInt(u32, 0, .big); // pre_defined
        try writer.writeInt(u32, self.handler_type, .big);
        const reserved: [12]u8 = @splat(0);
        try writer.writeAll(&reserved); // reserved
        try writer.writeAll(self.name);
        try writer.writeByte(0); // null terminator
    }

    pub fn deinit(self: *Hdlr, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

/// The Media Information Box (minf) contains all the information about the media data in a track.
pub const Minf = struct {
    handler: MediaHandler,
    dinf: Dinf,
    stbl: Stbl,

    pub fn size(self: *const Minf) usize {
        return Header.box_header_size + self.stbl.size() + self.dinf.size() + self.handler.size();
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Minf {
        var offset: u64 = 0;
        var stbl: ?Stbl = null;
        var dinf: ?Dinf = null;
        var handler: MediaHandler = .{ .unknown = {} };
        errdefer {
            if (stbl) |*box| box.deinit(allocator);
            if (dinf) |*box| box.deinit(allocator);
        }

        while (offset < header.payloadSize()) {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;
            switch (inner_header.type) {
                .stbl => stbl = try Stbl.parse(allocator, inner_header, reader),
                .dinf => dinf = try Dinf.parse(allocator, inner_header, reader),
                else => |tag| {
                    switch (tag) {
                        .vmhd => handler = .{ .video = .{} },
                        .smhd => handler = .{ .audio = .{} },
                        else => {},
                    }
                    _ = try reader.discard(.limited(inner_header.payloadSize()));
                },
            }
        }

        if (stbl == null or dinf == null) return error.InvalidMinfBox;
        return .{ .stbl = stbl.?, .dinf = dinf.?, .handler = handler };
    }

    pub fn write(self: *const Minf, writer: *std.Io.Writer) SampleEntryWriteError!void {
        const header = Header.new(.minf, self.size());
        try header.write(writer);
        try self.handler.write(writer);
        try self.dinf.write(writer);
        try self.stbl.write(writer);
    }

    pub fn deinit(self: *Minf, allocator: Allocator) void {
        self.stbl.deinit(allocator);
        self.dinf.deinit(allocator);
    }
};

pub const Dinf = struct {
    dref: Dref,

    pub fn init(allocator: Allocator) Allocator.Error!Dinf {
        var entries = try std.ArrayList(DataEntryUrl).initCapacity(allocator, 1);
        try entries.append(allocator, .{ .url = &.{} });
        return Dinf{ .dref = .{ .entries = entries } };
    }

    pub fn deinit(self: *Dinf, allocator: Allocator) void {
        self.dref.deinit(allocator);
    }

    pub fn size(self: *const Dinf) usize {
        return Header.box_header_size + self.dref.size();
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Dinf {
        const inner_header = try Header.parse(reader);
        if (inner_header.type != .dref or header.payloadSize() != inner_header.size) return error.InvalidDinfBox;
        return .{ .dref = try Dref.parse(allocator, inner_header, reader) };
    }

    pub fn write(self: *const Dinf, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.dinf, self.size());
        try header.write(writer);
        try self.dref.write(writer);
    }
};

pub const Dref = struct {
    entries: std.ArrayList(DataEntryUrl),

    pub fn size(self: *const Dref) usize {
        var entries_size: usize = 0;
        for (self.entries.items) |entry| entries_size += entry.size();
        return Header.full_box_header_size + 4 + entries_size;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Dref {
        if (header.payloadSize() < 8) return error.InvalidDrefBox;

        _ = try reader.discard(.limited(4)); // version + flags
        const entry_count = try reader.takeInt(u32, .big);
        if (entry_count == 0) return error.InvalidDrefBox;

        var dref = Dref{ .entries = try .initCapacity(allocator, entry_count) };
        errdefer dref.deinit(allocator);

        var offset: u64 = 8;
        for (0..entry_count) |_| {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;
            if (offset > header.payloadSize()) return error.InvalidDrefBox;

            switch (inner_header.type) {
                .@"url " => try dref.entries.append(allocator, try DataEntryUrl.parse(allocator, inner_header, reader)),
                else => _ = try reader.discard(.limited(inner_header.payloadSize())),
            }
        }

        if (offset != header.payloadSize()) return error.InvalidDrefBox;

        return dref;
    }

    pub fn write(self: *const Dref, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.dref, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // flags
        try writer.writeInt(u32, @intCast(self.entries.items.len), .big);
        for (self.entries.items) |*entry| try entry.write(writer);
    }

    pub fn deinit(self: *Dref, allocator: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }
};

pub const DataEntryUrl = struct {
    url: []u8,

    pub fn size(self: *const DataEntryUrl) usize {
        return Header.full_box_header_size + self.url.len;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!DataEntryUrl {
        if (header.payloadSize() < 4) return error.InvalidDataEntryUrlBox;

        _ = try reader.discard(.limited(4)); // version + flags

        var box = DataEntryUrl{ .url = &.{} };
        const url_size = header.payloadSize() - 4;
        if (url_size == 0) return box;

        box.url = try allocator.alloc(u8, header.payloadSize() - 4);
        @memcpy(box.url, try reader.take(url_size));
        return box;
    }

    pub fn write(self: *const DataEntryUrl, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.@"url ", self.size());
        try header.write(writer);
        try writer.writeInt(u32, 1, .big); // flags (indicates that the media data is in the same file)
        try writer.writeAll(self.url);
    }

    pub fn deinit(self: *DataEntryUrl, allocator: Allocator) void {
        if (self.url.len > 0) allocator.free(self.url);
    }
};

pub const MediaHandler = union(enum) {
    video: Vmhd,
    audio: Smhd,
    unknown: void,

    pub fn size(self: *const MediaHandler) usize {
        return switch (self.*) {
            .video => self.video.size(),
            .audio => self.audio.size(),
            else => 0,
        };
    }

    pub fn write(self: *const MediaHandler, writer: *std.Io.Writer) WriteError!void {
        switch (self.*) {
            .video => try self.video.write(writer),
            .audio => try self.audio.write(writer),
            .unknown => {},
        }
    }
};

pub const Vmhd = struct {
    pub fn size(_: *const Vmhd) usize {
        return Header.full_box_header_size + 8;
    }

    pub fn write(self: *const Vmhd, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.vmhd, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // flags
        try writer.writeInt(u16, 0, .big); // graphicsmode
        try writer.writeSliceEndian(u16, &[_]u16{ 0, 0, 0 }, .big);
    }
};

pub const Smhd = struct {
    pub fn size(_: *const Smhd) usize {
        return Header.full_box_header_size + 4;
    }

    pub fn write(self: *const Smhd, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.smhd, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // flags
        try writer.writeInt(u16, 0, .big); // balance
        try writer.writeInt(u16, 0, .big); // reserved
    }
};

/// The Sample Table Box (stbl) contains all the time and data indexing of the media samples in a track.
pub const Stbl = struct {
    stsd: Stsd,
    stts: Stts,
    ctts: ?Ctts = null,
    stss: ?Stss = null,
    stsz: Stsz,
    stsc: Stsc,
    stco: ?Stco = null,
    co64: ?Co64 = null,

    pub const empty = Stbl{
        .stsd = .empty,
        .stts = .empty,
        .ctts = .empty,
        .stss = .empty,
        .stsz = .empty,
        .stsc = .empty,
        .stco = .empty,
        .co64 = null,
    };

    pub fn deinit(self: *Stbl, allocator: Allocator) void {
        self.stsd.deinit(allocator);
        self.stts.deinit(allocator);
        if (self.ctts) |*box| box.deinit(allocator);
        if (self.stss) |*box| box.deinit(allocator);
        self.stsz.deinit(allocator);
        self.stsc.deinit(allocator);
        if (self.stco) |*box| box.deinit(allocator);
        if (self.co64) |*box| box.deinit(allocator);
    }

    pub fn size(self: *const Stbl) usize {
        const ctts_size = if (self.ctts) |*box| box.size() else 0;
        const stss_size = if (self.stss) |*box| box.size() else 0;
        const stco_size = if (self.stco) |*box| box.size() else 0;
        const co64_size = if (self.co64) |*box| box.size() else 0;
        return Header.box_header_size + self.stsd.size() + self.stts.size() +
            self.stsz.size() + self.stsc.size() + ctts_size + stss_size + stco_size + co64_size;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Stbl {
        var offset: u64 = 0;
        var stsd: ?Stsd = null;
        var stts: ?Stts = null;
        var ctts: ?Ctts = null;
        var stss: ?Stss = null;
        var stsz: ?Stsz = null;
        var stsc: ?Stsc = null;
        var stco: ?Stco = null;
        var co64: ?Co64 = null;

        errdefer {
            if (stsd) |*box| box.deinit(allocator);
            if (stts) |*box| box.deinit(allocator);
            if (ctts) |*box| box.deinit(allocator);
            if (stss) |*box| box.deinit(allocator);
            if (stsz) |*box| box.deinit(allocator);
            if (stsc) |*box| box.deinit(allocator);
            if (stco) |*box| box.deinit(allocator);
            if (co64) |*box| box.deinit(allocator);
        }

        while (offset < header.payloadSize()) {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;
            switch (inner_header.type) {
                .stsd => stsd = try Stsd.parse(allocator, inner_header, reader),
                .stts => stts = try Stts.parse(allocator, inner_header, reader),
                .ctts => ctts = try Ctts.parse(allocator, inner_header, reader),
                .stss => stss = try Stss.parse(allocator, inner_header, reader),
                .stsz => stsz = try Stsz.parse(allocator, inner_header, reader),
                .stsc => stsc = try Stsc.parse(allocator, inner_header, reader),
                .stco => stco = try Stco.parse(allocator, inner_header, reader),
                .co64 => co64 = try Co64.parse(allocator, inner_header, reader),
                else => _ = try reader.discard(.limited(inner_header.payloadSize())),
            }
        }

        if (stsd == null or stts == null or stsz == null or
            (stco == null and co64 == null))
        {
            return error.InvalidStblBox;
        }

        return .{
            .stsd = stsd.?,
            .stts = stts.?,
            .ctts = ctts,
            .stss = stss,
            .stsz = stsz.?,
            .stsc = stsc.?,
            .stco = stco,
            .co64 = co64,
        };
    }

    pub fn write(self: *const Stbl, writer: *std.Io.Writer) SampleEntryWriteError!void {
        const header = Header.new(.stbl, self.size());
        try header.write(writer);
        try self.stsd.write(writer);
        try self.stts.write(writer);
        if (self.ctts) |*box| try box.write(writer);
        if (self.stss) |*box| try box.write(writer);
        try self.stsz.write(writer);
        try self.stsc.write(writer);
        if (self.stco) |*box| try box.write(writer);
        if (self.co64) |*box| try box.write(writer);
    }

    /// Adds a sample entry to the Sample Table Box.
    /// The sample entry is cloned and owned by the Sample Table Box after this call,
    /// so the caller can safely deallocate it if needed.
    pub fn addSampleEntry(self: *Stbl, allocator: Allocator, entry: SampleEntry) Allocator.Error!void {
        try self.stsd.addEntry(allocator, try entry.clone(allocator));
    }

    /// Adds a sample to the Sample Table Box.
    pub fn addSample(self: *Stbl, allocator: Allocator, sample: SampleMetadata) Allocator.Error!void {
        try self.stts.addDelta(allocator, sample.duration);
        try self.stsz.addSample(allocator, sample.size);

        const offset: i32 = @intCast(@as(i128, sample.pts) - @as(i128, sample.dts));
        if (self.ctts) |*ctts| {
            if (offset < 0) ctts.version = 1;
            try ctts.addDelta(allocator, @bitCast(offset));
        }

        switch (self.stsd.entries.items[0]) {
            .video => if (sample.is_sync) try self.stss.?.samples.append(allocator, self.stsz.sample_count),
            else => {},
        }
    }

    pub fn addChunk(self: *Stbl, allocator: Allocator, samples_per_chunk: u32, chunk_offset: u64) Allocator.Error!void {
        try self.stco.?.entries.append(allocator, @intCast(chunk_offset));
        const stsc_entry = SampleToChunkEntry{
            .first_chunk = @intCast(self.stco.?.entries.items.len),
            .samples_per_chunk = samples_per_chunk,
            .sample_description_index = 1, // always use the first sample description for now
        };
        try self.stsc.addEntry(allocator, stsc_entry);
    }
};

/// The Sample Description Box (stsd) provides a compact way to represent the format of the samples in a track,
/// including the codec and any associated configuration data.
pub const Stsd = struct {
    entries: std.ArrayList(SampleEntry),

    pub const empty = Stsd{ .entries = .empty };

    pub fn addEntry(self: *Stsd, allocator: Allocator, entry: SampleEntry) Allocator.Error!void {
        try self.entries.append(allocator, entry);
    }

    pub fn size(self: *const Stsd) usize {
        var entries_size: usize = 0;
        for (self.entries.items) |entry| entries_size += entry.size();
        return Header.full_box_header_size + 4 + entries_size;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Stsd {
        if (header.payloadSize() < 8) return error.InvalidStsdBox;

        _ = try reader.discard(.limited(4)); // version + flags
        const entry_count = try reader.takeInt(u32, .big);
        if (entry_count == 0) return error.InvalidStsdBox;

        var stsd = Stsd{ .entries = try .initCapacity(allocator, entry_count) };
        errdefer stsd.deinit(allocator);

        var pos: u64 = 0;
        for (0..entry_count) |_| {
            const inner_header = try Header.parse(reader);
            pos += inner_header.size;
            if (pos > header.payloadSize()) return error.InvalidStsdBox;

            switch (inner_header.type) {
                .avc1, .avc3 => try stsd.entries.append(allocator, .{ .video = try VideoSampleEntry.parse(allocator, inner_header, reader) }),
                .hvc1, .hev1 => try stsd.entries.append(allocator, .{ .video = try VideoSampleEntry.parse(allocator, inner_header, reader) }),
                .mp4a => try stsd.entries.append(allocator, .{ .audio = try AudioSampleEntry.parse(allocator, inner_header, reader) }),
                else => _ = try reader.discard(.limited(inner_header.payloadSize())),
            }
        }

        return stsd;
    }

    pub fn write(self: *const Stsd, writer: *std.Io.Writer) SampleEntryWriteError!void {
        const header = Header.new(.stsd, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // version + flags
        try writer.writeInt(u32, @intCast(self.entries.items.len), .big);
        for (self.entries.items) |*entry| try entry.write(writer);
    }

    pub fn deinit(self: *Stsd, allocator: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }
};

/// A Sample Entry describes the format of a sample in a track, including its codec and any associated configuration data.
pub const SampleEntry = union(enum) {
    video: VideoSampleEntry,
    audio: AudioSampleEntry,
    unknown: void,

    pub fn size(self: *const SampleEntry) usize {
        switch (self.*) {
            .video => |v| return v.size(),
            .audio => |a| return a.size(),
            .unknown => return 8,
        }
    }

    pub fn write(self: *const SampleEntry, writer: *std.Io.Writer) SampleEntryWriteError!void {
        switch (self.*) {
            .video => |v| try v.write(writer),
            .audio => |a| try a.write(writer),
            .unknown => {},
        }
    }

    pub fn deinit(self: *SampleEntry, allocator: Allocator) void {
        switch (self.*) {
            .video => |*v| v.deinit(allocator),
            .audio => |*a| a.deinit(allocator),
            .unknown => {},
        }
    }

    pub fn clone(self: *const SampleEntry, allocator: Allocator) Allocator.Error!SampleEntry {
        return switch (self.*) {
            .video => |v| .{ .video = try v.clone(allocator) },
            .audio => |a| .{ .audio = try a.clone(allocator) },
            .unknown => .unknown,
        };
    }
};

/// A Video Sample Entry describes the format of a video sample in a track, including its codec and any associated configuration data.
pub const VideoSampleEntry = struct {
    codec: Codec,
    data_reference_index: u16,
    width: u16,
    height: u16,
    codec_config: []u8,
    tag: u32 = 0,

    pub fn size(self: *const VideoSampleEntry) usize {
        const codec_config_size = self.codec_config.len + Header.box_header_size;
        return Header.box_header_size + 78 + codec_config_size;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!VideoSampleEntry {
        if (header.payloadSize() < 78) return error.InvalidVideoSampleEntry;

        _ = try reader.discard(.limited(6)); // reserved

        var sample_entry = VideoSampleEntry{
            .codec = switch (header.type) {
                .avc1, .avc3 => .h264,
                .hvc1, .hev1 => .h265,
                else => .unknown,
            },
            .data_reference_index = 0,
            .width = 0,
            .height = 0,
            .codec_config = &.{},
            .tag = @intFromEnum(header.type),
        };
        errdefer sample_entry.deinit(allocator);

        sample_entry.data_reference_index = try reader.takeInt(u16, .big);

        _ = try reader.discardAll(16); // pre_defined + reserved

        sample_entry.width = try reader.takeInt(u16, .big);
        sample_entry.height = try reader.takeInt(u16, .big);

        _ = try reader.discardAll(50); // reserved

        var offset: u64 = 78;
        while (offset < header.payloadSize()) {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;
            if (offset > header.payloadSize()) return error.InvalidVideoSampleEntry;
            switch (inner_header.type) {
                .avcC, .hvcC => {
                    const config = try reader.take(inner_header.payloadSize());
                    sample_entry.codec_config = try allocator.dupe(u8, config);
                },
                else => _ = try reader.discard(.limited(inner_header.payloadSize())),
            }
        }

        if (offset != header.payloadSize()) return error.InvalidVideoSampleEntry;

        return sample_entry;
    }

    pub fn write(self: *const VideoSampleEntry, writer: *std.Io.Writer) SampleEntryWriteError!void {
        const box_type: BoxType = switch (self.codec) {
            .h264 => .avc1,
            .h265 => .hvc1,
            else => return error.InvalidVideoSampleEntry,
        };

        const header = Header.new(box_type, self.size());
        try header.write(writer);
        try writer.writeAll(&[_]u8{ 0, 0, 0, 0, 0, 0 }); // reserved
        try writer.writeInt(u16, self.data_reference_index, .big);

        const reserved: [16]u8 = @splat(0);
        try writer.writeAll(&reserved); // pre_defined + reserved

        try writer.writeInt(u16, self.width, .big);
        try writer.writeInt(u16, self.height, .big);
        try writer.writeInt(u32, 0x00480000, .big); // horizresolution (72 dpi)
        try writer.writeInt(u32, 0x00480000, .big); // vertresolution (72 dpi)

        try writer.writeInt(u32, 0, .big);
        try writer.writeInt(u16, 1, .big);

        const compressor_name: [32]u8 = @splat(0);
        try writer.writeAll(&compressor_name);

        try writer.writeInt(u16, 0x0018, .big); // depth
        try writer.writeInt(i16, -1, .big); // pre_defined

        switch (self.codec) {
            .h264, .h265 => |codec| {
                const config_header = Header.new(if (codec == .h264) .avcC else .hvcC, self.codec_config.len + Header.box_header_size);
                try config_header.write(writer);
                try writer.writeAll(self.codec_config);
            },
            .unknown => {},
            else => unreachable,
        }
    }

    pub fn deinit(self: *VideoSampleEntry, allocator: Allocator) void {
        allocator.free(self.codec_config);
    }

    pub fn clone(self: *const VideoSampleEntry, allocator: Allocator) Allocator.Error!VideoSampleEntry {
        return VideoSampleEntry{
            .codec = self.codec,
            .data_reference_index = self.data_reference_index,
            .width = self.width,
            .height = self.height,
            .codec_config = try allocator.dupe(u8, self.codec_config),
        };
    }
};

/// An Audio Sample Entry describes the format of an audio sample in a track, including its codec and any associated configuration data.
pub const AudioSampleEntry = struct {
    codec: Codec,
    tag: u32 = 0,
    data_reference_index: u16,
    channelcount: u16 = 2,
    samplesize: u16 = 16,
    samplerate: u32,
    codec_config: []u8,

    pub fn size(self: *const AudioSampleEntry) usize {
        const codec_config_size = self.codec_config.len + Header.box_header_size;
        return Header.box_header_size + 28 + codec_config_size;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!AudioSampleEntry {
        if (header.payloadSize() < 28) return error.InvalidAudioSampleEntry;

        _ = try reader.discard(.limited(6)); // reserved

        var sample_entry = AudioSampleEntry{
            .codec = .unknown,
            .data_reference_index = 0,
            .samplerate = 0,
            .tag = 0,
            .codec_config = &.{},
        };
        errdefer sample_entry.deinit(allocator);

        sample_entry.data_reference_index = try reader.takeInt(u16, .big);

        _ = try reader.discard(.limited(8)); // reserved

        sample_entry.channelcount = try reader.takeInt(u16, .big);
        sample_entry.samplesize = try reader.takeInt(u16, .big);
        _ = try reader.discard(.limited(4)); // pre_defined + reserved
        sample_entry.samplerate = try reader.takeInt(u32, .big) >> 16;

        var offset: u64 = 28;
        while (offset < header.payloadSize()) {
            const inner_header = try Header.parse(reader);
            offset += inner_header.size;
            if (offset > header.payloadSize()) return error.InvalidAudioSampleEntry;
            switch (inner_header.type) {
                .esds => {
                    const data = try reader.take(inner_header.payloadSize());
                    sample_entry.codec = .aac;
                    sample_entry.tag = @intFromEnum(inner_header.type);
                    sample_entry.codec_config = try allocator.dupe(u8, data);
                },
                else => _ = try reader.discard(.limited(inner_header.payloadSize())),
            }
        }

        if (offset != header.payloadSize()) return error.InvalidAudioSampleEntry;

        return sample_entry;
    }

    pub fn write(self: *const AudioSampleEntry, writer: *std.Io.Writer) SampleEntryWriteError!void {
        const box_type = switch (self.codec) {
            .aac => .mp4a,
            else => return error.InvalidAudioSampleEntry,
        };

        const header = Header.new(box_type, self.size());
        try header.write(writer);
        try writer.writeAll(&[_]u8{ 0, 0, 0, 0, 0, 0 }); // reserved
        try writer.writeInt(u16, self.data_reference_index, .big);

        const reserved: [8]u8 = @splat(0);
        try writer.writeAll(&reserved); // reserved
        try writer.writeInt(u16, self.channelcount, .big);
        try writer.writeInt(u16, self.samplesize, .big);

        try writer.writeInt(u32, 0, .big); // pre_defined + reserved
        try writer.writeInt(u32, self.samplerate << 16, .big);

        switch (self.codec) {
            .aac => {
                const config_header = Header.new(.esds, self.codec_config.len + 8);
                try config_header.write(writer);
                try writer.writeAll(self.codec_config);
            },
            .unknown => {},
            else => unreachable,
        }
    }

    pub fn deinit(self: *AudioSampleEntry, allocator: Allocator) void {
        allocator.free(self.codec_config);
    }

    pub fn clone(self: *const AudioSampleEntry, allocator: Allocator) !AudioSampleEntry {
        return .{
            .codec = self.codec,
            .data_reference_index = self.data_reference_index,
            .channelcount = self.channelcount,
            .samplesize = self.samplesize,
            .samplerate = self.samplerate,
            .codec_config = try allocator.dupe(u8, self.codec_config),
        };
    }
};

pub const TimeToSampleEntry = extern struct { count: u32, delta: u32 };

/// The Time-to-Sample Box (stts) provides a compact way to represent the timing of samples in a track.
pub const Stts = struct {
    samples: std.ArrayList(TimeToSampleEntry),

    pub const empty = Stts{ .samples = .empty };

    pub fn deinit(self: *Stts, allocator: Allocator) void {
        self.samples.deinit(allocator);
    }

    pub fn size(self: *const Stts) usize {
        return Header.full_box_header_size + 4 + self.samples.items.len * 8;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Stts {
        if (header.payloadSize() < 8) return error.InvalidSttsBox;

        _ = try reader.discard(.limited(4)); // version + flags
        const entry_count = try reader.takeInt(u32, .big);
        if (header.payloadSize() != 8 + entry_count * @sizeOf(TimeToSampleEntry)) return error.InvalidSttsBox;

        var stts = Stts{
            .samples = try .initCapacity(allocator, entry_count),
        };
        stts.samples.expandToCapacity();
        errdefer stts.deinit(allocator);

        try reader.readSliceEndian(TimeToSampleEntry, stts.samples.items, .big);

        return stts;
    }

    pub fn write(self: *const Stts, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.stts, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // version + flags
        try writer.writeInt(u32, @intCast(self.samples.items.len), .big);
        try writer.writeSliceEndian(TimeToSampleEntry, self.samples.items, .big);
    }

    pub fn addDelta(self: *Stts, allocator: Allocator, delta: u32) Allocator.Error!void {
        if (self.length() > 0) {
            @branchHint(.likely);
            var item = &self.samples.items[self.length() - 1];
            if (item.delta == delta) {
                item.count += 1;
                return;
            }
        }

        try self.samples.append(allocator, .{ .count = 1, .delta = delta });
    }

    fn length(self: *const Stts) usize {
        return self.samples.items.len;
    }
};

pub const CompositionTimeToSampleEntry = extern struct { count: u32, delta: u32 };

/// The Composition Time to Sample Box (ctts) provides a compact way to represent the composition time offsets of samples in a track,
/// which is used for tracks where the decoding order differs from the presentation order (e.g., video tracks with B-frames).
pub const Ctts = struct {
    version: u8,
    samples: std.ArrayList(CompositionTimeToSampleEntry),

    pub const empty = Ctts{ .version = 0, .samples = .empty };

    pub fn size(self: *const Ctts) usize {
        return Header.full_box_header_size + 4 + self.samples.items.len * @sizeOf(CompositionTimeToSampleEntry);
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Ctts {
        if (header.payloadSize() < 8) return error.InvalidCttsBox;

        const version = try reader.takeByte();
        _ = try reader.discard(.limited(3)); // version + flags
        const entry_count = try reader.takeInt(u32, .big);
        if (header.payloadSize() != 8 + entry_count * @sizeOf(CompositionTimeToSampleEntry)) return error.InvalidCttsBox;

        var ctts = Ctts{ .version = version, .samples = try .initCapacity(allocator, entry_count) };
        errdefer ctts.deinit(allocator);

        ctts.samples.expandToCapacity();
        try reader.readSliceEndian(CompositionTimeToSampleEntry, ctts.samples.items, .big);

        return ctts;
    }

    pub fn write(self: *const Ctts, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.ctts, self.size());
        try header.write(writer);
        try writer.writeInt(u8, self.version, .big);
        try writer.writeInt(u24, 0, .big); // flags
        try writer.writeInt(u32, @intCast(self.samples.items.len), .big);
        try writer.writeSliceEndian(CompositionTimeToSampleEntry, self.samples.items, .big);
    }

    pub fn deinit(self: *Ctts, allocator: Allocator) void {
        self.samples.deinit(allocator);
    }

    pub fn addDelta(self: *Ctts, allocator: Allocator, offset: u32) !void {
        var items = self.samples.items;
        if (items.len > 0) {
            @branchHint(.likely);
            var item = &items[items.len - 1];
            if (item.delta == offset) {
                item.count += 1;
                return;
            }
        }

        try self.samples.append(allocator, .{ .count = 1, .delta = offset });
    }

    pub fn isEmpty(self: *const Ctts) bool {
        const items = self.samples.items;
        return items.len == 0 or (items.len == 1 and items[0].delta == 0);
    }
};

/// The Sync Sample Box (stss) provides a compact way to represent which samples in a track are sync samples (keyframes).
pub const Stss = struct {
    samples: std.ArrayList(u32),

    pub const empty = Stss{ .samples = .empty };

    pub fn size(self: *const Stss) usize {
        return Header.full_box_header_size + 4 + self.samples.items.len * 4;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Stss {
        if (header.payloadSize() < 8) return error.InvalidStssBox;

        reader.toss(4); // version + flags
        const entry_count = try reader.takeInt(u32, .big);
        var stss = Stss{
            .samples = try .initCapacity(allocator, entry_count),
        };
        errdefer stss.deinit(allocator);

        if (header.payloadSize() != 8 + entry_count * 4) return error.InvalidStssBox;

        for (0..entry_count) |_| {
            const sample_number = try reader.takeInt(u32, .big);
            try stss.samples.append(allocator, sample_number);
        }

        return stss;
    }

    pub fn write(self: *const Stss, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.stss, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // version + flags
        try writer.writeInt(u32, @intCast(self.samples.items.len), .big);
        try writer.writeSliceEndian(u32, self.samples.items, .big);
    }

    pub fn deinit(self: *Stss, allocator: Allocator) void {
        self.samples.deinit(allocator);
    }
};

/// The Sample Size Box (stsz) provides a compact way to represent the size of each sample in a track,
/// either by specifying a constant sample size or by providing an array of sample sizes.
pub const Stsz = struct {
    sample_size: u32,
    sample_count: u32,
    samples: std.ArrayList(u32),

    pub const empty = Stsz{ .sample_size = 0, .sample_count = 0, .samples = .empty };

    pub fn deinit(self: *Stsz, allocator: Allocator) void {
        self.samples.deinit(allocator);
    }

    pub fn size(self: *const Stsz) usize {
        return Header.full_box_header_size + 8 + self.samples.items.len * 4;
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Stsz {
        if (header.payloadSize() < 12) return error.InvalidStszBox;

        _ = try reader.discard(.limited(4)); // version + flags
        const sample_size = try reader.takeInt(u32, .big);
        const sample_count = try reader.takeInt(u32, .big);

        if (header.payloadSize() != 12 + sample_count * 4) return error.InvalidStszBox;

        var stsz = Stsz{
            .sample_size = sample_size,
            .sample_count = sample_count,
            .samples = if (sample_size != 0) .empty else try .initCapacity(allocator, sample_count),
        };
        stsz.samples.expandToCapacity();
        errdefer stsz.deinit(allocator);

        if (sample_size == 0) {
            @branchHint(.likely);
            try reader.readSliceEndian(u32, stsz.samples.items, .big);
        }

        return stsz;
    }

    pub fn write(self: *const Stsz, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.stsz, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // version + flags
        try writer.writeInt(u32, self.sample_size, .big);
        try writer.writeInt(u32, self.sample_count, .big);
        if (self.sample_size == 0) {
            try writer.writeSliceEndian(u32, self.samples.items, .big);
        }
    }

    pub fn addSample(self: *Stsz, allocator: Allocator, sample_size: u32) Allocator.Error!void {
        self.sample_count += 1;
        try self.samples.append(allocator, sample_size);
    }

    fn getAt(self: *const Stsz, index: usize) u32 {
        if (self.sample_size != 0) {
            return self.sample_size;
        } else {
            return self.samples.items[index];
        }
    }
};

pub const SampleToChunkEntry = extern struct {
    first_chunk: u32,
    samples_per_chunk: u32,
    sample_description_index: u32,
};

/// The Sample-to-Chunk Box (stsc) provides a compact way to represent how samples are grouped into chunks in a track,
/// where a chunk is a group of samples that are stored contiguously in the file.
pub const Stsc = struct {
    entries: std.ArrayList(SampleToChunkEntry),

    pub const empty = Stsc{ .entries = .empty };

    pub fn size(self: *const Stsc) usize {
        return Header.full_box_header_size + 4 + self.entries.items.len * @sizeOf(SampleToChunkEntry);
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Stsc {
        if (header.payloadSize() < 8) return error.InvalidStscBox;

        _ = try reader.discard(.limited(4)); // version + flags
        const entry_count = try reader.takeInt(u32, .big);
        if (header.payloadSize() != 8 + entry_count * @sizeOf(SampleToChunkEntry)) return error.InvalidStscBox;

        var stsc = Stsc{ .entries = try .initCapacity(allocator, entry_count) };
        stsc.entries.expandToCapacity();
        errdefer stsc.deinit(allocator);

        try reader.readSliceEndian(SampleToChunkEntry, stsc.entries.items, .big);
        return stsc;
    }

    pub fn write(self: *const Stsc, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.stsc, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // version + flags
        try writer.writeInt(u32, @intCast(self.entries.items.len), .big);
        try writer.writeSliceEndian(SampleToChunkEntry, self.entries.items, .big);
    }

    /// Adds a new entry.
    pub fn addEntry(self: *Stsc, allocator: Allocator, new_entry: SampleToChunkEntry) Allocator.Error!void {
        if (self.entries.getLastOrNull()) |entry| if (entry.sample_description_index == new_entry.sample_description_index and
            entry.samples_per_chunk == new_entry.samples_per_chunk)
        {
            return;
        };

        try self.entries.append(allocator, new_entry);
    }

    pub fn deinit(self: *Stsc, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};

/// The Chunk Offset Box (stco) provides a compact way to represent the file offsets of each chunk in a track,
/// where a chunk is a group of samples that are stored contiguously in the file.
pub const Stco = struct {
    entries: std.ArrayList(u32),

    pub const empty = Stco{ .entries = .empty };

    pub fn size(self: *const Stco) usize {
        return Header.full_box_header_size + 4 + self.entries.items.len * @sizeOf(u32);
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Stco {
        if (header.payloadSize() < 8) return error.InvalidStcoBox;

        reader.toss(4); // version + flags
        const entry_count = try reader.takeInt(u32, .big);
        if (header.payloadSize() != 8 + entry_count * @sizeOf(u32)) return error.InvalidStcoBox;

        var stco = Stco{ .entries = try .initCapacity(allocator, entry_count) };
        stco.entries.expandToCapacity();
        errdefer stco.deinit(allocator);

        try reader.readSliceEndian(u32, stco.entries.items, .big);
        return stco;
    }

    pub fn write(self: *const Stco, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.stco, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // version + flags
        try writer.writeInt(u32, @intCast(self.entries.items.len), .big);
        try writer.writeSliceEndian(u32, self.entries.items, .big);
    }

    pub fn deinit(self: *Stco, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};

/// The 64-bit Chunk Offset Box (co64) is an extension of the stco box that allows for 64-bit file offsets,
/// which is necessary for files larger than 4 GB.
pub const Co64 = struct {
    entries: std.ArrayList(u64),

    pub fn size(self: *const Co64) usize {
        return Header.full_box_header_size + 4 + self.entries.items.len * @sizeOf(u64);
    }

    pub fn parse(allocator: Allocator, header: Header, reader: *Reader) ReadError!Co64 {
        if (header.payloadSize() < 8) return error.InvalidCo64Box;

        reader.toss(4); // version + flags
        const entry_count = try reader.takeInt(u32, .big);
        var co64 = Co64{
            .entries = try .initCapacity(allocator, entry_count),
        };
        errdefer co64.deinit(allocator);

        if (header.payloadSize() != (entry_count + 1) * 8) return error.InvalidCo64Box;

        for (0..entry_count) |_| {
            try co64.entries.append(allocator, try reader.takeInt(u64, .big));
        }

        return co64;
    }

    pub fn write(self: *const Co64, writer: *std.Io.Writer) WriteError!void {
        const header = Header.new(.co64, self.size());
        try header.write(writer);
        try writer.writeInt(u32, 0, .big); // version + flags
        try writer.writeInt(u32, @intCast(self.entries.items.len), .big);
        try writer.writeSliceEndian(u64, self.entries.items, .big);
    }

    pub fn deinit(self: *Co64, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};

pub const SampleMetadata = struct {
    dts: u64,
    pts: u64,
    duration: u32,
    is_sync: bool,
    size: u32,
    // file offset
    offset: u64,
    chunk_id: u32 = 0,
    // offset within the chunk.
    chunk_offset: u64 = 0,
};

// Iterators
pub const SampleIterator = struct {
    stbl: *const Stbl,
    stts_iterator: DeltaIterator(TimeToSampleEntry),
    stsc_iterator: StscIterator,
    ctts_iterator: ?DeltaIterator(CompositionTimeToSampleEntry) = null,
    duration: u64 = 0,

    sample_idx: usize = 1,
    stss_idx: usize = 0,

    /// Init a sample iterator.
    pub fn init(stbl: *const Stbl) SampleIterator {
        var ctts_iterator: ?DeltaIterator(CompositionTimeToSampleEntry) = null;
        if (stbl.ctts) |*box| {
            ctts_iterator = DeltaIterator(CompositionTimeToSampleEntry).init(box.samples.items);
        }

        return SampleIterator{
            .stbl = stbl,
            .stts_iterator = DeltaIterator(TimeToSampleEntry).init(stbl.stts.samples.items),
            .ctts_iterator = ctts_iterator,
            .stsc_iterator = StscIterator.init(stbl),
        };
    }

    // Get the next sample, or null if there are no more samples.
    pub fn next(self: *SampleIterator) ?SampleMetadata {
        if (self.peek()) |metadata| {
            @branchHint(.likely);
            self.skip(1);
            return metadata;
        }

        return null;
    }

    pub fn peek(self: *SampleIterator) ?SampleMetadata {
        if (self.stts_iterator.peek()) |delta| {
            const dts = self.duration;
            const pts: u64 = blk: {
                if (self.ctts_iterator) |*iter| {
                    const offset = iter.peek() orelse 0;
                    if (self.stbl.ctts.?.version == 1) {
                        const signed_offset: i32 = @bitCast(offset);
                        break :blk @intCast(@as(i128, dts) + signed_offset);
                    } else {
                        break :blk dts + offset;
                    }
                }

                break :blk dts;
            };

            const is_sync = self.sync();
            const size = self.stbl.stsz.getAt(self.sample_idx - 1);
            const chunk_id, const chunk_offset = self.stsc_iterator.peek();
            const offset = self.chunkOffset(chunk_id) + chunk_offset;

            return .{
                .dts = dts,
                .pts = pts,
                .duration = delta,
                .is_sync = is_sync,
                .size = size,
                .offset = offset,
                .chunk_id = chunk_id,
                .chunk_offset = chunk_offset,
            };
        }

        return null;
    }

    pub fn skip(self: *SampleIterator, count: u32) void {
        self.duration += self.stts_iterator.skip(count);
        if (self.ctts_iterator) |*iter| {
            _ = iter.skip(count);
        }
        self.stsc_iterator.skip(self.sample_idx - 1, count);
        self.sample_idx += count;
        if (self.stbl.stss) |*stss| {
            const items = stss.samples.items;
            while (self.stss_idx < items.len and items[self.stss_idx] < self.sample_idx) : (self.stss_idx += 1) {}
        }
    }

    fn sync(self: *SampleIterator) bool {
        if (self.stbl.stss) |*stss| {
            if (self.stss_idx >= stss.samples.items.len) return false;
            return stss.samples.items[self.stss_idx] == self.sample_idx;
        }

        return true;
    }

    fn chunkOffset(self: *SampleIterator, chunk_id: usize) u64 {
        if (self.stbl.co64) |*co64| {
            return co64.entries.items[chunk_id - 1];
        } else {
            return self.stbl.stco.?.entries.items[chunk_id - 1];
        }
    }
};

fn DeltaIterator(comptime T: type) type {
    return struct {
        entries: []const T,
        idx: usize = 0,
        entry: T,

        fn init(entries: []const T) @This() {
            return .{
                .entries = entries,
                .entry = entries[0],
            };
        }

        fn next(self: *@This()) ?u32 {
            const delta = self.peek();
            self.skip(1);
            return delta;
        }

        fn peek(self: *@This()) ?u32 {
            if (self.idx >= self.entries.len) {
                @branchHint(.unlikely);
                return null;
            }

            return self.entry.delta;
        }

        fn skip(self: *@This(), count: u32) u64 {
            var remaining = count;
            var duration: u64 = 0;
            while (remaining > 0 and self.idx < self.entries.len) {
                if (self.entry.count > remaining) {
                    self.entry.count -= remaining;
                    duration += remaining * self.entry.delta;
                    break;
                } else {
                    remaining -= self.entry.count;
                    duration += self.entry.count * self.entry.delta;
                    self.idx += 1;
                    if (self.idx < self.entries.len) {
                        self.entry = self.entries[self.idx];
                    }
                }
            }

            return duration;
        }
    };
}

const StscIterator = struct {
    stsc: *const Stsc,
    stsz: *const Stsz,
    entry: SampleToChunkEntry,
    entry_samples_per_chunk: u32,
    next_entry: ?SampleToChunkEntry = null,
    idx: usize = 0,
    chunk_offset: u32 = 0,

    fn init(stbl: *const Stbl) StscIterator {
        const entry = stbl.stsc.entries.items[0];
        const next_entry = if (stbl.stsc.entries.items.len > 1) stbl.stsc.entries.items[1] else null;

        return StscIterator{
            .stsc = &stbl.stsc,
            .stsz = &stbl.stsz,
            .entry = entry,
            .entry_samples_per_chunk = entry.samples_per_chunk,
            .next_entry = next_entry,
        };
    }

    fn next(self: *StscIterator, sample_index: usize) struct { u32, u64 } {
        const result = self.peek();
        self.skip(sample_index, 1);
        return result;
    }

    fn peek(self: *StscIterator) struct { u32, u64 } {
        return .{ self.entry.first_chunk, self.chunk_offset };
    }

    fn skip(self: *StscIterator, sample_index: usize, count: u32) void {
        var remaining = count;
        var index = sample_index;
        while (remaining > 0) {
            if (self.entry.samples_per_chunk > remaining) {
                self.entry.samples_per_chunk -= remaining;
                for (0..remaining) |idx| {
                    self.chunk_offset += self.stsz.getAt(index + idx);
                }
                break;
            } else {
                remaining -= self.entry.samples_per_chunk;
                index += self.entry.samples_per_chunk;

                self.entry.first_chunk += 1;
                self.entry.samples_per_chunk = self.entry_samples_per_chunk;
                self.chunk_offset = 0;

                if (self.next_entry) |next_entry| if (self.entry.first_chunk == next_entry.first_chunk) {
                    self.entry = next_entry;
                    self.entry_samples_per_chunk = next_entry.samples_per_chunk;

                    self.idx += 1;
                    self.next_entry = if (self.idx + 1 < self.stsc.entries.items.len) self.stsc.entries.items[self.idx + 1] else null;
                };
            }
        }
    }
};

test "Header: parses correctly" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70 }; // size=20, type='ftyp'
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);

    try std.testing.expect(header.type == .ftyp);
    try std.testing.expect(header.size == 20);
}

test "Header: parse long box" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x01, // size=1 (indicates large size)
        0x66, 0x74, 0x79, 0x70, // type='ftyp'
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x20, // large size=32
    };

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);

    try std.testing.expect(header.type == .ftyp);
    try std.testing.expect(header.size == 32);
}

test "Header: parse uuid box" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x18, // size = 24
        0x75, 0x75, 0x69, 0x64, // type = 'uuid'
        'a',  'b',  'c',  'd',
        'e',  'f',  'g',  'h',
        'i',  'j',  'k',  'l',
        'm',  'n',  'o',  'p',
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);

    try std.testing.expectEqual(.uuid, header.type);
    try std.testing.expectEqual(@as(u64, 24), header.size);
    try std.testing.expect(header.uuid != null);
    try std.testing.expectEqualStrings("abcdefghijklmnop", &header.uuid.?);
}

test "Header: short buffer" {
    const data = [_]u8{ 0x00, 0x00, 0x00 }; // incomplete header
    var reader = Reader.fixed(&data);
    try std.testing.expectError(error.EndOfStream, Header.parse(&reader));
}

test "Ftyp: parses major brand, minor version and compatible brands" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        'i', 's', 'o', 'm', // major_brand = 'isom'
        0x00, 0x00, 0x02, 0x00, // minor_version = 512
        'i', 's', 'o', 'm', // compatible_brand[0] = 'isom'
        'a', 'v', 'c', '1', // compatible_brand[1] = 'avc1'
    };
    var reader = Reader.fixed(&data);
    var ftyp = try Ftyp.parse(allocator, &reader, data.len);
    defer ftyp.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "isom", &ftyp.major_brand);
    try std.testing.expectEqual(@as(u32, 512), ftyp.minor_version);
    try std.testing.expectEqual(@as(usize, 2), ftyp.compatible_brands.items.len);
    try std.testing.expectEqualSlices(u8, "isom", &ftyp.compatible_brands.items[0]);
    try std.testing.expectEqualSlices(u8, "avc1", &ftyp.compatible_brands.items[1]);
}

test "Ftyp: rejects size not a multiple of 4" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 'i', 's', 'o', 'm', 0, 0, 0, 0, 'x' };
    var reader = Reader.fixed(&data);
    try std.testing.expectError(error.InvalidFtypBox, Ftyp.parse(allocator, &reader, 9));
}

test "Ftyp: no compatible brands" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        'm', 'p', '4', '2', // major_brand = 'mp42'
        0x00, 0x00, 0x00, 0x00, // minor_version = 0
    };
    var reader = Reader.fixed(&data);
    var ftyp = try Ftyp.parse(allocator, &reader, data.len);
    defer ftyp.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "mp42", &ftyp.major_brand);
    try std.testing.expectEqual(@as(usize, 0), ftyp.compatible_brands.items.len);
}

test "Mvhd: version 0 parse" {
    // box_size must equal mvhd.size() - box_header_size = (12 + 80 + 16) - 8 = 100
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x6C, // box_size = 108
        'm',  'v',  'h',  'd',
        0x00, 0x00, 0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x01, // creation_time = 1
        0x00, 0x00, 0x00, 0x02, // modification_time = 2
        0x00, 0x00, 0x0B, 0xB8, // timescale = 3000
        0x00, 0x00, 0x03, 0xE8, // duration = 1000
    } ++ [_]u8{0} ** 76 ++ [_]u8{
        0x00, 0x00, 0x00, 0x02, // next_track_id = 2
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    const mvhd = try Mvhd.parse(header, &reader);

    try std.testing.expectEqual(@as(u8, 0), mvhd.version);
    try std.testing.expectEqual(@as(u64, 1), mvhd.creation_time);
    try std.testing.expectEqual(@as(u64, 2), mvhd.modification_time);
    try std.testing.expectEqual(@as(u32, 3000), mvhd.timescale);
    try std.testing.expectEqual(@as(u64, 1000), mvhd.duration);
    try std.testing.expectEqual(@as(u32, 2), mvhd.next_track_id);
    try std.testing.expectEqual(@as(usize, 108), mvhd.size()); // 12 + 80 + 16
}

test "Mvhd: version 1 parse" {
    // box_size must equal mvhd.size() - box_header_size = (12 + 80 + 28) - 8 = 112
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x78,
        'm',  'v',  'h',  'd',
        0x01, 0x00, 0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // creation_time = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, // modification_time = 2
        0x00, 0x00, 0x0B, 0xB8, // timescale = 3000
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, // duration = 1000
    } ++ [_]u8{0} ** 76 ++ [_]u8{
        0x00, 0x00, 0x00, 0x02, // next_track_id = 2
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    const mvhd = try Mvhd.parse(header, &reader);

    try std.testing.expectEqual(@as(u8, 1), mvhd.version);
    try std.testing.expectEqual(@as(u64, 1), mvhd.creation_time);
    try std.testing.expectEqual(@as(u64, 2), mvhd.modification_time);
    try std.testing.expectEqual(@as(u32, 3000), mvhd.timescale);
    try std.testing.expectEqual(@as(u64, 1000), mvhd.duration);
    try std.testing.expectEqual(@as(u32, 2), mvhd.next_track_id);
    try std.testing.expectEqual(@as(usize, 120), mvhd.size()); // 12 + 80 + 28
}

test "Mvhd: rejects invalid box size" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x2A, // box_size = 42 (invalid for version 0)
        'm',  'v',  'h',  'd',
        0x00, 0x00, 0x00, 0x00, // flags
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidMvhdBox, Mvhd.parse(header, &reader));
}

test "Moov: parse moov" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fs = try std.Io.Dir.cwd().openFile(io, "fixtures/moov.bin", .{ .mode = .read_only });
    defer fs.close(io);

    var buffer: [128]u8 = @splat(0);
    var fs_reader = fs.reader(io, &buffer);
    const reader = &fs_reader.interface;

    const header = try Header.parse(reader);
    try std.testing.expectEqual(.moov, header.type);
    try std.testing.expectEqual(812_644, header.size);

    var moov = try Moov.parse(allocator, header, reader);
    defer moov.deinit(allocator);

    const mvhd = moov.mvhd;
    try std.testing.expectEqual(@as(u8, 0), mvhd.version);
    try std.testing.expectEqual(@as(u64, 0), mvhd.creation_time);
    try std.testing.expectEqual(@as(u64, 0), mvhd.modification_time);
    try std.testing.expectEqual(@as(u32, 1000), mvhd.timescale);
    try std.testing.expectEqual(@as(u64, 2_725_209), mvhd.duration);
    try std.testing.expectEqual(@as(u32, 3), mvhd.next_track_id);

    try std.testing.expectEqual(@as(usize, 2), moov.traks.items.len);
    const video_trak = &moov.traks.items[0];
    try std.testing.expectEqual(.video, video_trak.mediaType());
    try std.testing.expectEqual(1920, video_trak.width());
    try std.testing.expectEqual(816, video_trak.height());
    try std.testing.expectEqual(12_800, video_trak.timescale());

    const audio_trak = &moov.traks.items[1];
    try std.testing.expectEqual(.audio, audio_trak.mediaType());
    try std.testing.expectEqual(0, audio_trak.width());
    try std.testing.expectEqual(0, audio_trak.height());
    try std.testing.expectEqual(44_100, audio_trak.timescale());
}

test "Moov: allocation error" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing_allocator.allocator();
    const io = std.testing.io;

    var fs = try std.Io.Dir.cwd().openFile(io, "fixtures/moov.bin", .{ .mode = .read_only });
    defer fs.close(io);

    var buffer: [64]u8 = undefined;
    var fs_reader = fs.reader(io, &buffer);
    const reader = &fs_reader.interface;

    const header = try Header.parse(reader);
    try std.testing.expectEqual(.moov, header.type);
    try std.testing.expectEqual(812_644, header.size);

    try std.testing.expectError(error.OutOfMemory, Moov.parse(allocator, header, reader));
}

test "Stsc: parses entries correctly" {
    const allocator = std.testing.allocator;
    // size = 8 (header) + 4 (version+flags) + 4 (entry_count) + 2*12 (entries) = 40
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x28, // size = 40
        's', 't', 's', 'c', // type = 'stsc'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x02, // entry_count = 2
        0x00, 0x00, 0x00, 0x01, // entry[0].first_chunk = 1
        0x00, 0x00, 0x00, 0x04, // entry[0].samples_per_chunk = 4
        0x00, 0x00, 0x00, 0x01, // entry[0].sample_description_index = 1
        0x00, 0x00, 0x00, 0x05, // entry[1].first_chunk = 5
        0x00, 0x00, 0x00, 0x01, // entry[1].samples_per_chunk = 1
        0x00, 0x00, 0x00, 0x01, // entry[1].sample_description_index = 1
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stsc = try Stsc.parse(allocator, header, &reader);
    defer stsc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), stsc.entries.items.len);
    try std.testing.expectEqual(@as(u32, 1), stsc.entries.items[0].first_chunk);
    try std.testing.expectEqual(@as(u32, 4), stsc.entries.items[0].samples_per_chunk);
    try std.testing.expectEqual(@as(u32, 1), stsc.entries.items[0].sample_description_index);
    try std.testing.expectEqual(@as(u32, 5), stsc.entries.items[1].first_chunk);
    try std.testing.expectEqual(@as(u32, 1), stsc.entries.items[1].samples_per_chunk);
    try std.testing.expectEqual(@as(u32, 1), stsc.entries.items[1].sample_description_index);
    try std.testing.expectEqual(@as(usize, 40), stsc.size()); // 12 + 4 + 2*12
}

test "Stsc: empty entry list" {
    const allocator = std.testing.allocator;
    // size = 8 + 4 + 4 = 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // size = 16
        's', 't', 's', 'c', // type = 'stsc'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x00, // entry_count = 0
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stsc = try Stsc.parse(allocator, header, &reader);
    defer stsc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), stsc.entries.items.len);
    try std.testing.expectEqual(@as(usize, 16), stsc.size()); // 12 + 4 + 0*12
}

test "Stsc: rejects payload too small" {
    const allocator = std.testing.allocator;
    // payload_size = 15 - 8 = 7 < 8
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0F, // size = 15
        's', 't', 's', 'c', // type = 'stsc'
        0x00, 0x00, 0x00, 0x00, // version + flags (partial)
        0x00, 0x00, 0x00,
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStscBox, Stsc.parse(allocator, header, &reader));
}

test "Stsc: rejects entry_count mismatch with payload size" {
    const allocator = std.testing.allocator;
    // size = 28, payload = 20, but entry_count = 3 → 8 + 3*12 = 44 ≠ 20
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x1C, // size = 28
        's', 't', 's', 'c', // type = 'stsc'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x03, // entry_count = 3 (but only room for 1 entry)
        0x00, 0x00, 0x00, 0x01, // entry[0].first_chunk = 1
        0x00, 0x00, 0x00, 0x01, // entry[0].samples_per_chunk = 1
        0x00, 0x00, 0x00, 0x01, // entry[0].sample_description_index = 1
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStscBox, Stsc.parse(allocator, header, &reader));
}

test "Stts: parses entries correctly" {
    const allocator = std.testing.allocator;
    // size = 8 (header) + 4 (version+flags) + 4 (entry_count) + 2*8 (entries) = 32
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x20, // size = 32
        's', 't', 't', 's', // type = 'stts'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x02, // entry_count = 2
        0x00, 0x00, 0x00, 0x03, // entry[0].count = 3
        0x00, 0x00, 0x02, 0x00, // entry[0].delta = 512
        0x00, 0x00, 0x00, 0x01, // entry[1].count = 1
        0x00, 0x00, 0x04, 0x00, // entry[1].delta = 1024
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stts = try Stts.parse(allocator, header, &reader);
    defer stts.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), stts.samples.items.len);
    try std.testing.expectEqual(@as(u32, 3), stts.samples.items[0].count);
    try std.testing.expectEqual(@as(u32, 512), stts.samples.items[0].delta);
    try std.testing.expectEqual(@as(u32, 1), stts.samples.items[1].count);
    try std.testing.expectEqual(@as(u32, 1024), stts.samples.items[1].delta);
    try std.testing.expectEqual(@as(usize, 32), stts.size()); // 12 + 4 + 2*8
}

test "Stts: empty entry list" {
    const allocator = std.testing.allocator;
    // size = 8 + 4 + 4 + 0 = 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // size = 16
        's', 't', 't', 's', // type = 'stts'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x00, // entry_count = 0
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stts = try Stts.parse(allocator, header, &reader);
    defer stts.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), stts.samples.items.len);
    try std.testing.expectEqual(@as(usize, 16), stts.size()); // 12 + 4 + 0*8
}

test "Stts: rejects payload too small" {
    const allocator = std.testing.allocator;
    // payload_size = 15 - 8 = 7 < 8
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0F, // size = 15
        's', 't', 't', 's', // type = 'stts'
        0x00, 0x00, 0x00, 0x00, // version + flags (partial)
        0x00, 0x00, 0x00,
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidSttsBox, Stts.parse(allocator, header, &reader));
}

test "Stts: rejects entry_count mismatch with payload size" {
    const allocator = std.testing.allocator;
    // size = 24, payload = 16, but entry_count = 3 → 8 + 3*8 = 32 ≠ 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x18, // size = 24
        's', 't', 't', 's', // type = 'stts'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x03, // entry_count = 3 (but only room for 1 entry)
        0x00, 0x00, 0x00, 0x01, // entry[0].count = 1
        0x00, 0x00, 0x00, 0x01, // entry[0].delta = 1
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidSttsBox, Stts.parse(allocator, header, &reader));
}

test "Ctts: version 0 parses entries correctly" {
    const allocator = std.testing.allocator;
    // size = 8 (header) + 4 (version+flags) + 4 (entry_count) + 2*8 (entries) = 32
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x20, // size = 32
        'c', 't', 't', 's', // type = 'ctts'
        0x00, 0x00, 0x00, 0x00, // version=0 + flags
        0x00, 0x00, 0x00, 0x02, // entry_count = 2
        0x00, 0x00, 0x00, 0x03, // entry[0].count = 3
        0x00, 0x00, 0x00, 0x00, // entry[0].offset = 0
        0x00, 0x00, 0x00, 0x01, // entry[1].count = 1
        0x00, 0x00, 0x00, 0x64, // entry[1].offset = 100
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var ctts = try Ctts.parse(allocator, header, &reader);
    defer ctts.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), ctts.samples.items.len);
    try std.testing.expectEqual(@as(u32, 3), ctts.samples.items[0].count);
    try std.testing.expectEqual(@as(u32, 0), ctts.samples.items[0].delta);
    try std.testing.expectEqual(@as(u32, 1), ctts.samples.items[1].count);
    try std.testing.expectEqual(@as(u32, 100), ctts.samples.items[1].delta);
    try std.testing.expectEqual(@as(usize, 32), ctts.size()); // 12 + 4 + 2*8
}

test "Ctts: version 1 parses signed offsets" {
    const allocator = std.testing.allocator;
    // size = 8 + 4 + 4 + 2*8 = 32
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x20, // size = 32
        'c', 't', 't', 's', // type = 'ctts'
        0x01, 0x00, 0x00, 0x00, // version=1 + flags
        0x00, 0x00, 0x00, 0x02, // entry_count = 2
        0x00, 0x00, 0x00, 0x03, // entry[0].count = 3
        0xFF, 0xFF, 0xFF, 0xFE, // entry[0].offset = -2
        0x00, 0x00, 0x00, 0x01, // entry[1].count = 1
        0x00, 0x00, 0x00, 0x0A, // entry[1].offset = 10
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var ctts = try Ctts.parse(allocator, header, &reader);
    defer ctts.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), ctts.samples.items.len);
    try std.testing.expectEqual(@as(u32, 3), ctts.samples.items[0].count);

    const offset0: i32 = @bitCast(ctts.samples.items[0].delta);
    const offset1: i32 = @bitCast(ctts.samples.items[1].delta);

    try std.testing.expectEqual(@as(i32, -2), offset0);
    try std.testing.expectEqual(@as(u32, 1), ctts.samples.items[1].count);
    try std.testing.expectEqual(@as(i32, 10), offset1);
    try std.testing.expectEqual(@as(usize, 32), ctts.size()); // 12 + 4 + 2*8
}

test "Stss: parses sample numbers correctly" {
    const allocator = std.testing.allocator;
    // size = 8 (header) + 4 (version+flags) + 4 (entry_count) + 3*4 (entries) = 28
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x1C, // size = 28
        's', 't', 's', 's', // type = 'stss'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x03, // entry_count = 3
        0x00, 0x00, 0x00, 0x01, // sample_number[0] = 1
        0x00, 0x00, 0x00, 0x0A, // sample_number[1] = 10
        0x00, 0x00, 0x00, 0x14, // sample_number[2] = 20
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stss = try Stss.parse(allocator, header, &reader);
    defer stss.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), stss.samples.items.len);
    try std.testing.expectEqual(@as(u32, 1), stss.samples.items[0]);
    try std.testing.expectEqual(@as(u32, 10), stss.samples.items[1]);
    try std.testing.expectEqual(@as(u32, 20), stss.samples.items[2]);
    try std.testing.expectEqual(@as(usize, 28), stss.size()); // 12 + 4 + 3*4
}

test "Stsz: parses variable sample sizes" {
    const allocator = std.testing.allocator;
    // size = 8 (header) + 4 (version+flags) + 4 (sample_size) + 4 (sample_count) + 3*4 (entries) = 32
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x20, // size = 32
        's', 't', 's', 'z', // type = 'stsz'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x00, // sample_size = 0 (variable)
        0x00, 0x00, 0x00, 0x03, // sample_count = 3
        0x00, 0x00, 0x00, 0x64, // sizes[0] = 100
        0x00, 0x00, 0x00, 0xC8, // sizes[1] = 200
        0x00, 0x00, 0x00, 0x96, // sizes[2] = 150
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stsz = try Stsz.parse(allocator, header, &reader);
    defer stsz.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), stsz.sample_size);
    try std.testing.expectEqual(@as(usize, 3), stsz.samples.items.len);
    try std.testing.expectEqual(@as(u32, 100), stsz.samples.items[0]);
    try std.testing.expectEqual(@as(u32, 200), stsz.samples.items[1]);
    try std.testing.expectEqual(@as(u32, 150), stsz.samples.items[2]);
    try std.testing.expectEqual(@as(usize, 32), stsz.size()); // 12 + 8 + 3*4
}

test "Stsz: parses constant sample size" {
    const allocator = std.testing.allocator;
    // size = 8 + 4 + 4 + 4 + 0 = 20
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x14, // size = 20
        's', 't', 's', 'z', // type = 'stsz'
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x02, 0x00, // sample_size = 512
        0x00, 0x00, 0x00, 0x00, // sample_count = 0
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stsz = try Stsz.parse(allocator, header, &reader);
    defer stsz.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 512), stsz.sample_size);
    try std.testing.expectEqual(@as(usize, 0), stsz.samples.items.len);
    try std.testing.expectEqual(@as(usize, 20), stsz.size()); // 12 + 8 + 0*4
}

test "VideoSampleEntry: parses avc1 without codec config" {
    const allocator = std.testing.allocator;
    // size = 8 (header) + 78 (payload) = 86
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x56, // size = 86
        'a', 'v', 'c', '1', // type = avc1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x01, // data_reference_index = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // pre_defined + reserved
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x80, // width = 1920
        0x04, 0x38, // height = 1080
    } ++ [_]u8{0} ** 50; // horizresolution, vertresolution, reserved, frame_count, compressorname, depth, pre_defined

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var entry = try VideoSampleEntry.parse(allocator, header, &reader);
    defer entry.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 1), entry.data_reference_index);
    try std.testing.expectEqual(@as(u16, 1920), entry.width);
    try std.testing.expectEqual(@as(u16, 1080), entry.height);
    try std.testing.expectEqualSlices(u8, &.{}, entry.codec_config);
}

test "VideoSampleEntry: parses avc1 with avcC codec config" {
    const allocator = std.testing.allocator;
    // size = 8 (header) + 78 (base payload) + 12 (avcC box) = 98
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x62, // size = 98
        'a', 'v', 'c', '1', // type = avc1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x01, // data_reference_index = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // pre_defined + reserved
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x80, // width = 1920
        0x04, 0x38, // height = 1080
    } ++ [_]u8{0} ** 50 ++ [_]u8{ // reserved
        0x00, 0x00, 0x00, 0x0C, // avcC size = 12
        'a', 'v', 'c', 'C', // type = avcC
        0x01, 0x64, 0x00, 0x1F, // avcC config bytes
    };

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var entry = try VideoSampleEntry.parse(allocator, header, &reader);
    defer entry.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 1), entry.data_reference_index);
    try std.testing.expectEqual(@as(u16, 1920), entry.width);
    try std.testing.expectEqual(@as(u16, 1080), entry.height);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x64, 0x00, 0x1F }, entry.codec_config);
}

test "VideoSampleEntry: rejects payload too small" {
    const allocator = std.testing.allocator;
    // size = 85 → payloadSize = 77 < 78
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x55, // size = 85
        'a', 'v', 'c', '1', // type = avc1
    } ++ [_]u8{0} ** 77;

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidVideoSampleEntry, VideoSampleEntry.parse(allocator, header, &reader));
}

test "AudioSampleEntry: parses mp4a without codec config" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x24, // size = 36
        'm', 'p', '4', 'a', // type = mp4a
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x01, // data_reference_index = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x06, // channelcount = 6
        0x00, 0x10, // samplesize = 16
        0x00, 0x00, 0x00, 0x00, // pre_defined + reserved
        0xAC, 0x44, 0x00, 0x00, // samplerate = 44100 in fixed-point 16.16
    };

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var entry = try AudioSampleEntry.parse(allocator, header, &reader);
    defer entry.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 1), entry.data_reference_index);
    try std.testing.expectEqual(@as(u16, 6), entry.channelcount);
    try std.testing.expectEqual(@as(u16, 16), entry.samplesize);
    try std.testing.expectEqual(@as(u32, 44100), entry.samplerate);
    try std.testing.expectEqualSlices(u8, &.{}, entry.codec_config);
}

test "AudioSampleEntry: parses mp4a with esds codec config" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x30, // size = 48
        'm', 'p', '4', 'a', // type = mp4a
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x01, // data_reference_index = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x02, // channelcount = 2
        0x00, 0x10, // samplesize = 16
        0x00, 0x00, 0x00, 0x00, // pre_defined + reserved
        0xBB, 0x80, 0x00, 0x00, // samplerate = 48000 in fixed-point 16.16
        0x00, 0x00, 0x00, 0x0C, // esds size = 12
        'e', 's', 'd', 's', // type = esds
        0xDE, 0xAD, 0xBE, 0xEF, // esds config bytes
    };

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var entry = try AudioSampleEntry.parse(allocator, header, &reader);
    defer entry.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 1), entry.data_reference_index);
    try std.testing.expectEqual(@as(u16, 2), entry.channelcount);
    try std.testing.expectEqual(@as(u16, 16), entry.samplesize);
    try std.testing.expectEqual(@as(u32, 48000), entry.samplerate);
    try std.testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, entry.codec_config);
}

test "AudioSampleEntry: rejects payload too small" {
    const allocator = std.testing.allocator;
    // size = 35 → payloadSize = 27 < 28
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x23, // size = 35
        'm', 'p', '4', 'a', // type = mp4a
    } ++ [_]u8{0} ** 27;

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidAudioSampleEntry, AudioSampleEntry.parse(allocator, header, &reader));
}

test "Stsd: parses video sample entry" {
    const allocator = std.testing.allocator;
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x66, // size = 102
        's', 't', 's', 'd', // type = stsd
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x01, // entry_count = 1
        0x00, 0x00, 0x00, 0x56, // avc1 size = 86
        'a', 'v', 'c', '1', // type = avc1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x01, // data_reference_index = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // pre_defined + reserved
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x80, // width = 1920
        0x04, 0x38, // height = 1080
    } ++ [_]u8{0} ** 50; // reserved

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stsd = try Stsd.parse(allocator, header, &reader);
    defer stsd.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), stsd.entries.items.len);
    const video = stsd.entries.items[0].video;
    try std.testing.expectEqual(@as(u16, 1), video.data_reference_index);
    try std.testing.expectEqual(@as(u16, 1920), video.width);
    try std.testing.expectEqual(@as(u16, 1080), video.height);
}

test "Stsd: parses audio sample entry" {
    const allocator = std.testing.allocator;
    // stsd size = 12 (full_box_header) + 4 (entry_count) + 36 (mp4a) = 52
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x34, // size = 52
        's', 't', 's', 'd', // type = stsd
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x01, // entry_count = 1
        0x00, 0x00, 0x00, 0x24, // mp4a size = 36
        'm', 'p', '4', 'a', // type = mp4a
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x01, // data_reference_index = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x02, // channelcount = 2
        0x00, 0x10, // samplesize = 16
        0x00, 0x00, 0x00, 0x00, // pre_defined + reserved
        0xBB, 0x80, 0x00, 0x00, // samplerate = 48000 in fixed-point 16.16
    };

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stsd = try Stsd.parse(allocator, header, &reader);
    defer stsd.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), stsd.entries.items.len);
    const audio = stsd.entries.items[0].audio;
    try std.testing.expectEqual(@as(u16, 1), audio.data_reference_index);
    try std.testing.expectEqual(@as(u16, 2), audio.channelcount);
    try std.testing.expectEqual(@as(u16, 16), audio.samplesize);
    try std.testing.expectEqual(@as(u32, 48000), audio.samplerate);
}

test "Stsd: rejects zero entry count" {
    const allocator = std.testing.allocator;
    // size = 12 + 4 = 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // size = 16
        's', 't', 's', 'd', // type = stsd
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x00, // entry_count = 0
    };

    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStsdBox, Stsd.parse(allocator, header, &reader));
}

test "SampleIterator: 4 samples 1 per chunk" {
    const allocator = std.testing.allocator;

    var stts_entries: std.ArrayListUnmanaged(TimeToSampleEntry) = .empty;
    try stts_entries.append(allocator, .{ .count = 4, .delta = 1000 });

    var stsz_samples: std.ArrayListUnmanaged(u32) = .empty;
    try stsz_samples.appendSlice(allocator, &.{ 100, 200, 300, 400 });

    var stsc_entries: std.ArrayListUnmanaged(SampleToChunkEntry) = .empty;
    try stsc_entries.append(allocator, .{ .first_chunk = 1, .samples_per_chunk = 1, .sample_description_index = 1 });

    var stco_entries: std.ArrayListUnmanaged(u32) = .empty;
    try stco_entries.appendSlice(allocator, &.{ 1000, 2000, 3000, 4000 });

    var stbl = Stbl{
        .stsd = .{ .entries = .empty },
        .stts = .{ .samples = stts_entries },
        .stsz = .{ .sample_size = 0, .sample_count = 4, .samples = stsz_samples },
        .stsc = .{ .entries = stsc_entries },
        .stco = .{ .entries = stco_entries },
    };
    defer stbl.deinit(allocator);

    var iter = SampleIterator.init(&stbl);

    const s0 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 0), s0.dts);
    try std.testing.expectEqual(@as(u64, 0), s0.pts);
    try std.testing.expectEqual(@as(u32, 1000), s0.duration);
    try std.testing.expect(s0.is_sync);
    try std.testing.expectEqual(@as(u32, 100), s0.size);
    try std.testing.expectEqual(@as(u32, 1), s0.chunk_id);
    try std.testing.expectEqual(@as(u64, 0), s0.chunk_offset);
    try std.testing.expectEqual(@as(u64, 1000), s0.offset);

    const s1 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 1000), s1.dts);
    try std.testing.expectEqual(@as(u64, 1000), s1.pts);
    try std.testing.expectEqual(@as(u32, 200), s1.size);
    try std.testing.expectEqual(@as(u32, 2), s1.chunk_id);
    try std.testing.expectEqual(@as(u64, 0), s1.chunk_offset);
    try std.testing.expectEqual(@as(u64, 2000), s1.offset);

    const s2 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 2000), s2.dts);
    try std.testing.expectEqual(@as(u32, 3), s2.chunk_id);
    try std.testing.expectEqual(@as(u64, 3000), s2.offset);

    const s3 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 3000), s3.dts);
    try std.testing.expectEqual(@as(u32, 4), s3.chunk_id);
    try std.testing.expectEqual(@as(u64, 4000), s3.offset);

    try std.testing.expect(iter.next() == null);
}

test "SampleIterator: 2 samples per chunk" {
    const allocator = std.testing.allocator;

    var stts_entries: std.ArrayListUnmanaged(TimeToSampleEntry) = .empty;
    try stts_entries.append(allocator, .{ .count = 4, .delta = 1000 });

    var stsz_samples: std.ArrayListUnmanaged(u32) = .empty;
    try stsz_samples.appendSlice(allocator, &.{ 100, 200, 150, 250 });

    var stsc_entries: std.ArrayListUnmanaged(SampleToChunkEntry) = .empty;
    try stsc_entries.append(allocator, .{ .first_chunk = 1, .samples_per_chunk = 2, .sample_description_index = 1 });

    var stco_entries: std.ArrayListUnmanaged(u32) = .empty;
    try stco_entries.appendSlice(allocator, &.{ 1000, 2000 });

    var stbl = Stbl{
        .stsd = .{ .entries = .empty },
        .stts = .{ .samples = stts_entries },
        .stsz = .{ .sample_size = 0, .sample_count = 4, .samples = stsz_samples },
        .stsc = .{ .entries = stsc_entries },
        .stco = .{ .entries = stco_entries },
    };
    defer stbl.deinit(allocator);

    var iter = SampleIterator.init(&stbl);

    const s0 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 1), s0.chunk_id);
    try std.testing.expectEqual(@as(u64, 0), s0.chunk_offset);
    try std.testing.expectEqual(@as(u64, 1000), s0.offset);

    const s1 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 1), s1.chunk_id);
    try std.testing.expectEqual(@as(u64, 100), s1.chunk_offset); // size of s0
    try std.testing.expectEqual(@as(u64, 1100), s1.offset);

    const s2 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 2), s2.chunk_id);
    try std.testing.expectEqual(@as(u64, 0), s2.chunk_offset);
    try std.testing.expectEqual(@as(u64, 2000), s2.offset);

    const s3 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 2), s3.chunk_id);
    try std.testing.expectEqual(@as(u64, 150), s3.chunk_offset); // size of s2
    try std.testing.expectEqual(@as(u64, 2150), s3.offset);

    try std.testing.expect(iter.next() == null);
}

test "SampleIterator: variable deltas across stts entries" {
    const allocator = std.testing.allocator;

    var stts_entries: std.ArrayListUnmanaged(TimeToSampleEntry) = .empty;
    try stts_entries.appendSlice(allocator, &.{
        .{ .count = 2, .delta = 1000 },
        .{ .count = 2, .delta = 500 },
    });

    var stsc_entries: std.ArrayListUnmanaged(SampleToChunkEntry) = .empty;
    try stsc_entries.append(allocator, .{ .first_chunk = 1, .samples_per_chunk = 1, .sample_description_index = 1 });

    var stco_entries: std.ArrayListUnmanaged(u32) = .empty;
    try stco_entries.appendSlice(allocator, &.{ 0, 100, 200, 300 });

    var stbl = Stbl{
        .stsd = .{ .entries = .empty },
        .stts = .{ .samples = stts_entries },
        .stsz = .{ .sample_size = 100, .sample_count = 0, .samples = .empty },
        .stsc = .{ .entries = stsc_entries },
        .stco = .{ .entries = stco_entries },
    };
    defer stbl.deinit(allocator);

    var iter = SampleIterator.init(&stbl);

    const s0 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 0), s0.dts);
    try std.testing.expectEqual(@as(u32, 1000), s0.duration);

    const s1 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 1000), s1.dts);
    try std.testing.expectEqual(@as(u32, 1000), s1.duration);

    const s2 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 2000), s2.dts);
    try std.testing.expectEqual(@as(u32, 500), s2.duration);

    const s3 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 2500), s3.dts);
    try std.testing.expectEqual(@as(u32, 500), s3.duration);

    try std.testing.expect(iter.next() == null);
}

test "SampleIterator: ctts shifts pts" {
    const allocator = std.testing.allocator;

    var stts_entries: std.ArrayListUnmanaged(TimeToSampleEntry) = .empty;
    try stts_entries.append(allocator, .{ .count = 3, .delta = 1000 });

    var ctts_samples: std.ArrayListUnmanaged(CompositionTimeToSampleEntry) = .empty;
    try ctts_samples.appendSlice(allocator, &.{
        .{ .count = 1, .delta = 2000 },
        .{ .count = 1, .delta = 0 },
        .{ .count = 1, .delta = 1000 },
    });

    var stsc_entries: std.ArrayListUnmanaged(SampleToChunkEntry) = .empty;
    try stsc_entries.append(allocator, .{ .first_chunk = 1, .samples_per_chunk = 1, .sample_description_index = 1 });

    var stco_entries: std.ArrayListUnmanaged(u32) = .empty;
    try stco_entries.appendSlice(allocator, &.{ 0, 100, 200 });

    var stbl = Stbl{
        .stsd = .{ .entries = .empty },
        .stts = .{ .samples = stts_entries },
        .ctts = .{ .version = 0, .samples = ctts_samples },
        .stsz = .{ .sample_size = 100, .sample_count = 0, .samples = .empty },
        .stsc = .{ .entries = stsc_entries },
        .stco = .{ .entries = stco_entries },
    };
    defer stbl.deinit(allocator);

    var iter = SampleIterator.init(&stbl);

    const s0 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 0), s0.dts);
    try std.testing.expectEqual(@as(u64, 2000), s0.pts);

    const s1 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 1000), s1.dts);
    try std.testing.expectEqual(@as(u64, 1000), s1.pts);

    const s2 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 2000), s2.dts);
    try std.testing.expectEqual(@as(u64, 3000), s2.pts);

    try std.testing.expect(iter.next() == null);
}

test "SampleIterator: ctts version 1 allows negative offsets" {
    const allocator = std.testing.allocator;

    // Simulates B-frame reordering: decode order I,B,P → presentation order I,P,B
    // DTS: 0, 1000, 2000 — offsets: +2000, -1000, +1000 → PTS: 2000, 0, 3000
    var stts_entries: std.ArrayListUnmanaged(TimeToSampleEntry) = .empty;
    try stts_entries.append(allocator, .{ .count = 3, .delta = 1000 });

    var ctts_samples: std.ArrayListUnmanaged(CompositionTimeToSampleEntry) = .empty;
    try ctts_samples.appendSlice(allocator, &.{
        .{ .count = 1, .delta = 2000 },
        .{ .count = 1, .delta = @bitCast(@as(i32, -1000)) },
        .{ .count = 1, .delta = 1000 },
    });

    var stsc_entries: std.ArrayListUnmanaged(SampleToChunkEntry) = .empty;
    try stsc_entries.append(allocator, .{ .first_chunk = 1, .samples_per_chunk = 1, .sample_description_index = 1 });

    var stco_entries: std.ArrayListUnmanaged(u32) = .empty;
    try stco_entries.appendSlice(allocator, &.{ 0, 100, 200 });

    var stbl = Stbl{
        .stsd = .{ .entries = .empty },
        .stts = .{ .samples = stts_entries },
        .ctts = .{ .version = 1, .samples = ctts_samples },
        .stsz = .{ .sample_size = 100, .sample_count = 0, .samples = .empty },
        .stsc = .{ .entries = stsc_entries },
        .stco = .{ .entries = stco_entries },
    };
    defer stbl.deinit(allocator);

    var iter = SampleIterator.init(&stbl);

    const s0 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 0), s0.dts);
    try std.testing.expectEqual(@as(u64, 2000), s0.pts);

    const s1 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 1000), s1.dts);
    try std.testing.expectEqual(@as(u64, 0), s1.pts); // 1000 + (-1000)

    const s2 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 2000), s2.dts);
    try std.testing.expectEqual(@as(u64, 3000), s2.pts);

    try std.testing.expect(iter.next() == null);
}

test "SampleIterator: stss marks sync samples" {
    const allocator = std.testing.allocator;

    var stts_entries: std.ArrayListUnmanaged(TimeToSampleEntry) = .empty;
    try stts_entries.append(allocator, .{ .count = 4, .delta = 1000 });

    var stss_samples: std.ArrayListUnmanaged(u32) = .empty;
    try stss_samples.appendSlice(allocator, &.{ 1, 3 }); // 1-based sample numbers

    var stsc_entries: std.ArrayListUnmanaged(SampleToChunkEntry) = .empty;
    try stsc_entries.append(allocator, .{ .first_chunk = 1, .samples_per_chunk = 1, .sample_description_index = 1 });

    var stco_entries: std.ArrayListUnmanaged(u32) = .empty;
    try stco_entries.appendSlice(allocator, &.{ 0, 100, 200, 300 });

    var stbl = Stbl{
        .stsd = .{ .entries = .empty },
        .stts = .{ .samples = stts_entries },
        .stss = .{ .samples = stss_samples },
        .stsz = .{ .sample_size = 100, .sample_count = 0, .samples = .empty },
        .stsc = .{ .entries = stsc_entries },
        .stco = .{ .entries = stco_entries },
    };
    defer stbl.deinit(allocator);

    var iter = SampleIterator.init(&stbl);

    try std.testing.expect(iter.next().?.is_sync); // sample 1
    try std.testing.expect(!iter.next().?.is_sync); // sample 2\
    try std.testing.expect(iter.next().?.is_sync); // sample 3
    try std.testing.expect(!iter.next().?.is_sync); // sample 4
    try std.testing.expect(iter.next() == null);
}

test "SampleIterator: multiple stsc entries" {
    const allocator = std.testing.allocator;

    // chunks 1,2: 2 samples each; chunk 3+: 1 sample each
    var stts_entries: std.ArrayListUnmanaged(TimeToSampleEntry) = .empty;
    try stts_entries.append(allocator, .{ .count = 5, .delta = 1000 });

    var stsc_entries: std.ArrayListUnmanaged(SampleToChunkEntry) = .empty;
    try stsc_entries.appendSlice(allocator, &.{
        .{ .first_chunk = 1, .samples_per_chunk = 2, .sample_description_index = 1 },
        .{ .first_chunk = 3, .samples_per_chunk = 1, .sample_description_index = 1 },
    });

    var stco_entries: std.ArrayListUnmanaged(u32) = .empty;
    try stco_entries.appendSlice(allocator, &.{ 0, 200, 400, 500, 600 });

    var stbl = Stbl{
        .stsd = .{ .entries = .empty },
        .stts = .{ .samples = stts_entries },
        .stsz = .{ .sample_size = 100, .sample_count = 0, .samples = .empty },
        .stsc = .{ .entries = stsc_entries },
        .stco = .{ .entries = stco_entries },
    };
    defer stbl.deinit(allocator);

    var iter = SampleIterator.init(&stbl);

    const s0 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 1), s0.chunk_id);
    try std.testing.expectEqual(@as(u64, 0), s0.chunk_offset);

    const s1 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 1), s1.chunk_id);
    try std.testing.expectEqual(@as(u64, 100), s1.chunk_offset);

    const s2 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 2), s2.chunk_id);
    try std.testing.expectEqual(@as(u64, 0), s2.chunk_offset);

    const s3 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 2), s3.chunk_id);
    try std.testing.expectEqual(@as(u64, 100), s3.chunk_offset);

    const s4 = iter.next().?;
    try std.testing.expectEqual(@as(u32, 3), s4.chunk_id);
    try std.testing.expectEqual(@as(u64, 0), s4.chunk_offset);

    try std.testing.expect(iter.next() == null);
}

test "Tkhd: version 0 parse" {
    // size = 12 (full_box_header) + 20 (v0 fields) + 60 (reserved+matrix+dimensions) = 92
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x5C, // size = 92
        't',  'k',  'h',  'd',
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, // creation_time = 1
        0x00, 0x00, 0x00, 0x02, // modification_time = 2
        0x00, 0x00, 0x00, 0x03, // track_id = 3
        0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x00, 0x02, 0xBC, // duration = 700
    } ++ [_]u8{0} ** 52 ++ [_]u8{ // reserved + matrix
        0x07, 0x80, 0x00, 0x00, // width = 1920 in 16.16 fixed-point
        0x04, 0x38, 0x00, 0x00, // height = 1080 in 16.16 fixed-point
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    const tkhd = try Tkhd.parse(&reader, header);

    try std.testing.expectEqual(@as(u8, 0), tkhd.version);
    try std.testing.expectEqual(@as(u64, 1), tkhd.creation_time);
    try std.testing.expectEqual(@as(u64, 2), tkhd.modification_time);
    try std.testing.expectEqual(@as(u32, 3), tkhd.track_id);
    try std.testing.expectEqual(@as(u64, 700), tkhd.duration);
    try std.testing.expectEqual(1920, tkhd.width);
    try std.testing.expectEqual(1080, tkhd.height);
}

test "Tkhd: version 1 parse" {
    // size = 12 (full_box_header) + 32 (v1 fields) + 60 (reserved+matrix+dimensions) = 104
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x68, // size = 104
        't',  'k',  'h',  'd',
        0x01, // version = 1
        0x00, 0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // creation_time = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, // modification_time = 2
        0x00, 0x00, 0x00, 0x05, // track_id = 5
        0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0B, 0xB8, // duration = 3000
    } ++ [_]u8{0} ** 52 ++ [_]u8{
        0x07, 0x80, 0x00, 0x00, // width = 0x07800000
        0x04, 0x38, 0x00, 0x00, // height = 0x04380000
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    const tkhd = try Tkhd.parse(&reader, header);

    try std.testing.expectEqual(@as(u8, 1), tkhd.version);
    try std.testing.expectEqual(@as(u64, 1), tkhd.creation_time);
    try std.testing.expectEqual(@as(u64, 2), tkhd.modification_time);
    try std.testing.expectEqual(@as(u32, 5), tkhd.track_id);
    try std.testing.expectEqual(@as(u64, 3000), tkhd.duration);
}

test "Tkhd: rejects invalid box size" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x2A, // size = 42 (invalid for both v0 and v1)
        't',  'k',  'h',  'd',
        0x00, 0x00, 0x00, 0x00,
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidTkhdBox, Tkhd.parse(&reader, header));
}

test "Mdhd: version 0 parse" {
    // size = 12 (full_box_header) + 16 (v0 time fields) + 4 (language+pre_defined) = 32
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x20, // size = 32
        'm',  'd',  'h',  'd',
        0x00, // version = 0
        0x00, 0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // creation + modification (tossed)
        0x00, 0x00, 0x0B, 0xB8, // timescale = 3000
        0x00, 0x00, 0x03, 0xE8, // duration = 1000
        0x55, 0xC4, // language = 'und'
        0x00, 0x00, // pre_defined
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    const mdhd = try Mdhd.parse(header, &reader);

    try std.testing.expectEqual(@as(u8, 0), mdhd.version);
    try std.testing.expectEqual(@as(u32, 3000), mdhd.timescale);
    try std.testing.expectEqual(@as(u64, 1000), mdhd.duration);
    try std.testing.expectEqualStrings("und", &mdhd.language);
}

test "Mdhd: version 1 parse" {
    // size = 12 (full_box_header) + 28 (v1 time fields) + 4 (language+pre_defined) = 44
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x2C, // size = 44
        'm',  'd',  'h',  'd',
        0x01, // version = 1
        0x00, 0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // creation_time (tossed)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // modification_time (tossed)
        0x00, 0x00, 0x75, 0x30, // timescale = 30000
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0xD0, // duration = 2000
        0x55, 0xC4, // language = 'und'
        0x00, 0x00, // pre_defined
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    const mdhd = try Mdhd.parse(header, &reader);

    try std.testing.expectEqual(@as(u8, 1), mdhd.version);
    try std.testing.expectEqual(@as(u32, 30000), mdhd.timescale);
    try std.testing.expectEqual(@as(u64, 2000), mdhd.duration);
    try std.testing.expectEqualStrings("und", &mdhd.language);
}

test "Mdhd: rejects invalid box size" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x14, // size = 20 (invalid for v0=32 or v1=44)
        'm',  'd',  'h',  'd',
        0x00, 0x00, 0x00, 0x00,
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidMdhdBox, Mdhd.parse(header, &reader));
}

test "Hdlr: parses handler type and name" {
    // size = 12 (full_box_header) + 20 (fixed fields) + 12 (name) + 1 (null) = 45
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x2D, // size = 45
        'h',  'd',  'l',  'r',
        0x00, // version = 0
        0x00, 0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, // pre_defined
        0x76, 0x69, 0x64, 0x65, // handler_type = 'vide'
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        'V', 'i', 'd', 'e', 'o', 'H', 'a', 'n', 'd', 'l', 'e', 'r', // name
        0x00, // null terminator
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var hdlr = try Hdlr.parse(allocator, header, &reader);
    defer hdlr.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0x76696465), hdlr.handler_type);
    try std.testing.expectEqualStrings("VideoHandler", hdlr.name);
}

test "Hdlr: parses empty name" {
    // size = 12 + 20 + 0 + 1 = 33 = 0x21
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x21, // size = 33
        'h',  'd',  'l',  'r',
        0x00, // version = 0
        0x00, 0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, // pre_defined
        0x73, 0x6F, 0x75, 0x6E, // handler_type = 'soun'
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, // null terminator
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var hdlr = try Hdlr.parse(allocator, header, &reader);
    defer hdlr.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0x736F756E), hdlr.handler_type);
    try std.testing.expectEqual(@as(usize, 0), hdlr.name.len);
}

test "Stco: parses entries correctly" {
    // size = 12 (full_box_header) + 4 (entry_count) + 3*4 (entries) = 28
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x1C, // size = 28
        's',  't',  'c',  'o',
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x03, // entry_count = 3
        0x00, 0x00, 0x03, 0xE8, // entries[0] = 1000
        0x00, 0x00, 0x07, 0xD0, // entries[1] = 2000
        0x00, 0x00, 0x0B, 0xB8, // entries[2] = 3000
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stco = try Stco.parse(allocator, header, &reader);
    defer stco.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), stco.entries.items.len);
    try std.testing.expectEqual(@as(u32, 1000), stco.entries.items[0]);
    try std.testing.expectEqual(@as(u32, 2000), stco.entries.items[1]);
    try std.testing.expectEqual(@as(u32, 3000), stco.entries.items[2]);
}

test "Stco: empty entries" {
    // size = 12 + 4 + 0 = 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // size = 16
        's',  't',  'c',  'o',
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x00, // entry_count = 0
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var stco = try Stco.parse(allocator, header, &reader);
    defer stco.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), stco.entries.items.len);
}

test "Stco: rejects payload too small" {
    // payloadSize = 15 - 8 = 7 < 8
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0F, // size = 15
        's',  't',  'c',  'o',
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStcoBox, Stco.parse(allocator, header, &reader));
}

test "Stco: rejects entry_count mismatch with payload size" {
    // payloadSize = 16, but entry_count=5 → 8 + 5*4 = 28 ≠ 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x18, // size = 24
        's',  't',  'c',  'o',
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x05, // entry_count = 5 (but only room for 2)
        0x00, 0x00, 0x03, 0xE8, // entries[0] = 1000
        0x00, 0x00, 0x07, 0xD0, // entries[1] = 2000
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStcoBox, Stco.parse(allocator, header, &reader));
}

test "Co64: parses entries correctly" {
    // payloadSize must equal (entry_count + 1) * 8
    // For 2 entries: (2+1)*8 = 24; size = 8 + 24 = 32
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x20, // size = 32
        'c',  'o',  '6',  '4',
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x02, // entry_count = 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, // entries[0] = 1000
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, // entries[1] = 4294967296
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var co64 = try Co64.parse(allocator, header, &reader);
    defer co64.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), co64.entries.items.len);
    try std.testing.expectEqual(@as(u64, 1000), co64.entries.items[0]);
    try std.testing.expectEqual(@as(u64, 4294967296), co64.entries.items[1]);
}

test "Co64: rejects payload too small" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0F, // size = 15, payloadSize = 7 < 8
        'c',  'o',  '6',  '4',
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidCo64Box, Co64.parse(allocator, header, &reader));
}

test "Co64: rejects entry_count payload mismatch" {
    // entry_count=1, requires payloadSize=(1+1)*8=16, but payloadSize=8
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // size = 16, payloadSize = 8
        'c',  'o',  '6',  '4',
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x01, // entry_count = 1
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidCo64Box, Co64.parse(allocator, header, &reader));
}

test "DataEntryUrl: parses self-contained (empty URL)" {
    // size = 12 (full_box_header) + 0 (url) = 12
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0C, // size = 12
        'u',  'r',  'l',  ' ',
        0x00, 0x00, 0x00, 0x01, // version=0 + flags=1 (self-contained)
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var entry = try DataEntryUrl.parse(allocator, header, &reader);
    defer entry.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), entry.url.len);
}

test "DataEntryUrl: parses URL" {
    // size = 12 + 4 (url "http") = 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // size = 16
        'u',  'r',  'l',  ' ',
        0x00, 0x00, 0x00, 0x00, // version=0 + flags=0
        'h', 't', 't', 'p', // url = "http"
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var entry = try DataEntryUrl.parse(allocator, header, &reader);
    defer entry.deinit(allocator);

    try std.testing.expectEqualStrings("http", entry.url);
}

test "Stss: rejects payload too small" {
    // payloadSize = 15 - 8 = 7 < 8
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0F, // size = 15
        's',  't',  's',  's',
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStssBox, Stss.parse(allocator, header, &reader));
}

test "Stss: rejects entry_count mismatch with payload size" {
    // payloadSize = 16, entry_count=5 → 8 + 5*4 = 28 ≠ 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x18, // size = 24
        's',  't',  's',  's',
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x05, // entry_count = 5 (but only room for 2)
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x02,
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStssBox, Stss.parse(allocator, header, &reader));
}

test "Stsz: rejects payload too small" {
    // payloadSize = 19 - 8 = 11 < 12
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x13, // size = 19
        's',  't',  's',  'z',
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStszBox, Stsz.parse(allocator, header, &reader));
}

test "Stsz: rejects both sample_size and sample_count nonzero" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x14, // size = 20
        's',  't',  's',  'z',
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x02, 0x00, // sample_size = 512 (nonzero)
        0x00, 0x00, 0x00, 0x03, // sample_count = 3 (nonzero — invalid)
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidStszBox, Stsz.parse(allocator, header, &reader));
}

test "Ctts: rejects payload too small" {
    // payloadSize = 15 - 8 = 7 < 8
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0F, // size = 15
        'c',  't',  't',  's',
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidCttsBox, Ctts.parse(allocator, header, &reader));
}

test "Ctts: rejects entry_count mismatch with payload size" {
    // payloadSize = 16, entry_count=3 → 8 + 3*8 = 32 ≠ 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x18, // size = 24
        'c',  't',  't',  's',
        0x00, 0x00, 0x00, 0x00, // version + flags
        0x00, 0x00, 0x00, 0x03, // entry_count = 3 (but only 2*8 bytes follow)
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x64,
    };
    const allocator = std.testing.allocator;
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidCttsBox, Ctts.parse(allocator, header, &reader));
}

test "SampleIterator: uses co64 offsets" {
    const allocator = std.testing.allocator;

    var stts_entries: std.ArrayListUnmanaged(TimeToSampleEntry) = .empty;
    try stts_entries.append(allocator, .{ .count = 2, .delta = 1000 });

    var stsc_entries: std.ArrayListUnmanaged(SampleToChunkEntry) = .empty;
    try stsc_entries.append(allocator, .{ .first_chunk = 1, .samples_per_chunk = 1, .sample_description_index = 1 });

    var co64_entries: std.ArrayListUnmanaged(u64) = .empty;
    try co64_entries.appendSlice(allocator, &.{
        0x1_0000_0000, // 4 GiB — beyond u32 range
        0x2_0000_0000,
    });

    var stbl = Stbl{
        .stsd = .{ .entries = .empty },
        .stts = .{ .samples = stts_entries },
        .stsz = .{ .sample_size = 100, .sample_count = 0, .samples = .empty },
        .stsc = .{ .entries = stsc_entries },
        .co64 = .{ .entries = co64_entries },
    };
    defer stbl.deinit(allocator);

    var iter = SampleIterator.init(&stbl);

    const s0 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), s0.offset);

    const s1 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 0x2_0000_0000), s1.offset);

    try std.testing.expect(iter.next() == null);
}

test "Header: writes small box" {
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const header = Header.new(.ftyp, 20);
    try header.write(&w);
    try w.flush();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p' }, &buf);
}

test "Header: writes long box" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const large_size: u64 = @as(u64, std.math.maxInt(u32)) + 1;
    const header = Header.new(.mdat, large_size);
    try header.write(&w);
    try w.flush();
    // size=1, type='mdat', large_size=0x100000000
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x00, 0x01,
        'm',  'd',  'a',  't',
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
    }, &buf);
}

test "Ftyp: serialize-parse" {
    const allocator = std.testing.allocator;
    var brands: std.ArrayList([4]u8) = .empty;
    try brands.appendSlice(allocator, &.{ "isom".*, "avc1".* });
    var ftyp = Ftyp{
        .major_brand = "isom".*,
        .minor_version = 512,
        .compatible_brands = brands,
    };
    defer ftyp.deinit(allocator);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try ftyp.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(ftyp.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var ftyp2 = try Ftyp.parse(allocator, &reader, header.payloadSize());
    defer ftyp2.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &ftyp.major_brand, &ftyp2.major_brand);
    try std.testing.expectEqual(ftyp.minor_version, ftyp2.minor_version);
    try std.testing.expectEqual(ftyp.compatible_brands.items.len, ftyp2.compatible_brands.items.len);
    try std.testing.expectEqualSlices(u8, &ftyp.compatible_brands.items[0], &ftyp2.compatible_brands.items[0]);
    try std.testing.expectEqualSlices(u8, &ftyp.compatible_brands.items[1], &ftyp2.compatible_brands.items[1]);
}

test "Mvhd: serialize-parse v0" {
    const mvhd = Mvhd{
        .version = 0,
        .creation_time = 1,
        .modification_time = 2,
        .timescale = 3000,
        .duration = 1000,
        .next_track_id = 2,
    };

    var wa: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer wa.deinit();

    try mvhd.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(mvhd.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const mvhd2 = try Mvhd.parse(header, &reader);

    try std.testing.expect(std.meta.eql(mvhd, mvhd2));
}

test "Mvhd: serialize-parse v1" {
    const mvhd = Mvhd{
        .version = 1,
        .creation_time = 1,
        .modification_time = 2,
        .timescale = 3000,
        .duration = 1000,
        .next_track_id = 3,
    };

    var wa: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer wa.deinit();
    try mvhd.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(mvhd.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const mvhd2 = try Mvhd.parse(header, &reader);

    try std.testing.expect(std.meta.eql(mvhd, mvhd2));
}

test "Tkhd: serialize-parse v0" {
    // width/height are stored as 16.16 fixed-point (pixel value * 65536)
    const tkhd = Tkhd{
        .version = 0,
        .creation_time = 1,
        .modification_time = 2,
        .track_id = 3,
        .duration = 700,
        .width = 1920,
        .height = 1080,
    };

    var wa: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer wa.deinit();
    try tkhd.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(tkhd.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const tkhd2 = try Tkhd.parse(&reader, header);

    try std.testing.expect(std.meta.eql(tkhd, tkhd2));
}

test "Tkhd: serialize-parse v1" {
    const tkhd = Tkhd{
        .version = 1,
        .creation_time = 1,
        .modification_time = 2,
        .track_id = 5,
        .duration = 3000,
        .width = 1920,
        .height = 1080,
    };

    var wa: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer wa.deinit();
    try tkhd.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(tkhd.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const tkhd2 = try Tkhd.parse(&reader, header);

    try std.testing.expect(std.meta.eql(tkhd, tkhd2));
}

test "Mdhd: serialize-parse v0" {
    const mdhd = Mdhd{
        .version = 0,
        .timescale = 3000,
        .duration = 1000,
        .language = "und".*,
    };

    var wa: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer wa.deinit();
    try mdhd.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(mdhd.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const mdhd2 = try Mdhd.parse(header, &reader);

    try std.testing.expect(std.meta.eql(mdhd, mdhd2));
}

test "Mdhd: serialize-parse v1" {
    const mdhd = Mdhd{
        .version = 1,
        .timescale = 30000,
        .duration = 2000,
        .language = "und".*,
    };

    var wa: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer wa.deinit();
    try mdhd.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(mdhd.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const mdhd2 = try Mdhd.parse(header, &reader);

    try std.testing.expect(std.meta.eql(mdhd, mdhd2));
}

test "Hdlr: serialize-parse" {
    const allocator = std.testing.allocator;
    var hdlr = Hdlr{
        .handler_type = std.mem.readInt(u32, "vide", .big),
        .name = try allocator.dupe(u8, "VideoHandler"),
    };
    defer hdlr.deinit(allocator);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try hdlr.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(hdlr.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var hdlr2 = try Hdlr.parse(allocator, header, &reader);
    defer hdlr2.deinit(allocator);

    try std.testing.expectEqual(hdlr.handler_type, hdlr2.handler_type);
    try std.testing.expectEqualStrings(hdlr.name, hdlr2.name);
}

test "DataEntryUrl: serialize-parse self-contained" {
    const allocator = std.testing.allocator;
    var entry = DataEntryUrl{ .url = &.{} };
    defer entry.deinit(allocator);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try entry.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(entry.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var entry2 = try DataEntryUrl.parse(allocator, header, &reader);
    defer entry2.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), entry2.url.len);
}

test "DataEntryUrl: serialize-parse URL" {
    const allocator = std.testing.allocator;
    var entry = DataEntryUrl{ .url = try allocator.dupe(u8, "http") };
    defer entry.deinit(allocator);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try entry.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(entry.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var entry2 = try DataEntryUrl.parse(allocator, header, &reader);
    defer entry2.deinit(allocator);

    try std.testing.expectEqualStrings(entry.url, entry2.url);
}

test "Stts: serialize-parse" {
    const allocator = std.testing.allocator;
    var stts: Stts = .empty;
    defer stts.deinit(allocator);

    try stts.samples.append(allocator, .{ .count = 3, .delta = 512 });
    try stts.samples.append(allocator, .{ .count = 1, .delta = 1024 });

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try stts.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(stts.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var stts2 = try Stts.parse(allocator, header, &reader);
    defer stts2.deinit(allocator);

    try std.testing.expectEqual(stts.samples.items.len, stts2.samples.items.len);
    for (stts.samples.items, stts2.samples.items) |s1, s2| try std.testing.expect(std.meta.eql(s1, s2));
}

test "Ctts: serialize-parse" {
    const allocator = std.testing.allocator;
    var ctts: Ctts = .empty;
    defer ctts.deinit(allocator);

    try ctts.samples.append(allocator, .{ .count = 3, .delta = 0 });
    try ctts.samples.append(allocator, .{ .count = 1, .delta = 100 });

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try ctts.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(ctts.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var ctts2 = try Ctts.parse(allocator, header, &reader);
    defer ctts2.deinit(allocator);

    try std.testing.expectEqual(ctts.version, ctts2.version);
    try std.testing.expectEqual(ctts.samples.items.len, ctts2.samples.items.len);
    for (ctts.samples.items, ctts2.samples.items) |s1, s2| try std.testing.expect(std.meta.eql(s1, s2));
}

test "Stss: serialize-parse" {
    const allocator = std.testing.allocator;
    var stss: Stss = .empty;
    defer stss.deinit(allocator);
    try stss.samples.append(allocator, 1);
    try stss.samples.append(allocator, 10);
    try stss.samples.append(allocator, 20);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try stss.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(stss.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var stss2 = try Stss.parse(allocator, header, &reader);
    defer stss2.deinit(allocator);

    try std.testing.expectEqual(stss.samples.items.len, stss2.samples.items.len);
    for (stss.samples.items, stss2.samples.items) |s1, s2| {
        try std.testing.expectEqual(s1, s2);
    }
}

test "Stsz: serialize-parse variable sizes" {
    const allocator = std.testing.allocator;
    var stsz: Stsz = .empty;
    defer stsz.deinit(allocator);
    try stsz.addSample(allocator, 100);
    try stsz.addSample(allocator, 200);
    try stsz.addSample(allocator, 150);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try stsz.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(stsz.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var stsz2 = try Stsz.parse(allocator, header, &reader);
    defer stsz2.deinit(allocator);

    try std.testing.expectEqual(stsz.sample_size, stsz2.sample_size);
    try std.testing.expectEqual(stsz.samples.items.len, stsz2.samples.items.len);
    for (stsz.samples.items, stsz2.samples.items) |s1, s2| {
        try std.testing.expectEqual(s1, s2);
    }
}

test "Stsz: serialize-parse constant size" {
    const allocator = std.testing.allocator;
    const stsz = Stsz{
        .sample_size = 512,
        .sample_count = 0,
        .samples = .empty,
    };

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try stsz.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(stsz.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var stsz2 = try Stsz.parse(allocator, header, &reader);
    defer stsz2.deinit(allocator);

    try std.testing.expectEqual(stsz.sample_size, stsz2.sample_size);
    try std.testing.expectEqual(stsz.sample_count, stsz2.sample_count);
    try std.testing.expectEqual(@as(usize, 0), stsz2.samples.items.len);
}

test "Stsc: serialize-parse" {
    const allocator = std.testing.allocator;
    var stsc: Stsc = .empty;
    defer stsc.deinit(allocator);
    try stsc.entries.append(allocator, .{ .first_chunk = 1, .samples_per_chunk = 4, .sample_description_index = 1 });
    try stsc.entries.append(allocator, .{ .first_chunk = 5, .samples_per_chunk = 1, .sample_description_index = 1 });

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try stsc.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(stsc.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var stsc2 = try Stsc.parse(allocator, header, &reader);
    defer stsc2.deinit(allocator);

    try std.testing.expectEqual(stsc.entries.items.len, stsc2.entries.items.len);
    for (stsc.entries.items, stsc2.entries.items) |e1, e2| try std.testing.expect(std.meta.eql(e1, e2));
}

test "Stco: serialize-parse" {
    const allocator = std.testing.allocator;
    var stco: Stco = .empty;
    defer stco.deinit(allocator);
    try stco.entries.append(allocator, 1000);
    try stco.entries.append(allocator, 2000);
    try stco.entries.append(allocator, 3000);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try stco.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(stco.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var stco2 = try Stco.parse(allocator, header, &reader);
    defer stco2.deinit(allocator);

    try std.testing.expectEqual(stco.entries.items.len, stco2.entries.items.len);
    for (stco.entries.items, stco2.entries.items) |e1, e2| try std.testing.expectEqual(e1, e2);
}

test "Co64: serialize-parse" {
    const allocator = std.testing.allocator;
    var co64 = Co64{ .entries = .empty };
    defer co64.deinit(allocator);
    try co64.entries.append(allocator, 1000);
    try co64.entries.append(allocator, 0x1_0000_0000);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try co64.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(co64.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var co64_2 = try Co64.parse(allocator, header, &reader);
    defer co64_2.deinit(allocator);

    try std.testing.expectEqual(co64.entries.items.len, co64_2.entries.items.len);
    for (co64.entries.items, co64_2.entries.items) |e1, e2| {
        try std.testing.expectEqual(e1, e2);
    }
}

test "VideoSampleEntry: parses hvc1 with hvcC config" {
    const allocator = std.testing.allocator;
    // size = 8 (header) + 78 (base payload) + 12 (hvcC box) = 98
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x62, // size = 98
        'h', 'v', 'c', '1', // type = hvc1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
        0x00, 0x01, // data_reference_index = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // pre_defined + reserved
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x80, // width = 1920
        0x04, 0x38, // height = 1080
    } ++ [_]u8{0} ** 50 ++ [_]u8{
        0x00, 0x00, 0x00, 0x0C, // hvcC size = 12
        'h', 'v', 'c', 'C', // type = hvcC
        0x01, 0x01, 0x60, 0x00, // hvcC config bytes
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    var entry = try VideoSampleEntry.parse(allocator, header, &reader);
    defer entry.deinit(allocator);

    try std.testing.expectEqual(.h265, entry.codec);
    try std.testing.expectEqual(@as(u16, 1), entry.data_reference_index);
    try std.testing.expectEqual(@as(u16, 1920), entry.width);
    try std.testing.expectEqual(@as(u16, 1080), entry.height);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x01, 0x60, 0x00 }, entry.codec_config);
}

test "VideoSampleEntry: serialize-parse avc1 with avcC config" {
    const allocator = std.testing.allocator;
    var entry = VideoSampleEntry{
        .codec = .h264,
        .data_reference_index = 1,
        .width = 1920,
        .height = 1080,
        .codec_config = try allocator.dupe(u8, &.{ 0x01, 0x64, 0x00, 0x1F }),
    };
    defer entry.deinit(allocator);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try entry.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(entry.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var entry2 = try VideoSampleEntry.parse(allocator, header, &reader);
    defer entry2.deinit(allocator);

    try std.testing.expectEqual(entry.codec, entry2.codec);
    try std.testing.expectEqual(entry.width, entry2.width);
    try std.testing.expectEqual(entry.height, entry2.height);
    try std.testing.expectEqualSlices(u8, entry.codec_config, entry2.codec_config);
}

test "VideoSampleEntry: serialize-parse hvc1 with hvcC config" {
    const allocator = std.testing.allocator;
    var entry = VideoSampleEntry{
        .codec = .h265,
        .data_reference_index = 1,
        .width = 1920,
        .height = 1080,
        .codec_config = try allocator.dupe(u8, &.{ 0x01, 0x01, 0x60, 0x00 }),
    };
    defer entry.deinit(allocator);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try entry.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(entry.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var entry2 = try VideoSampleEntry.parse(allocator, header, &reader);
    defer entry2.deinit(allocator);

    try std.testing.expectEqual(entry.codec, entry2.codec);
    try std.testing.expectEqual(entry.width, entry2.width);
    try std.testing.expectEqual(entry.height, entry2.height);
    try std.testing.expectEqualSlices(u8, entry.codec_config, entry2.codec_config);
}

test "AudioSampleEntry: serialize-parse mp4a with esds config" {
    const allocator = std.testing.allocator;
    var entry = AudioSampleEntry{
        .codec = .aac,
        .data_reference_index = 1,
        .channelcount = 2,
        .samplesize = 16,
        .samplerate = 48000,
        .codec_config = try allocator.dupe(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }),
    };
    defer entry.deinit(allocator);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try entry.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(entry.size(), wa.writer.buffered().len);

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var entry2 = try AudioSampleEntry.parse(allocator, header, &reader);
    defer entry2.deinit(allocator);

    try std.testing.expectEqual(entry.channelcount, entry2.channelcount);
    try std.testing.expectEqual(entry.samplerate, entry2.samplerate);
    try std.testing.expectEqualSlices(u8, entry.codec_config, entry2.codec_config);
}

test "Moov: serialize-parse" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fs = try std.Io.Dir.cwd().openFile(io, "fixtures/moov.bin", .{ .mode = .read_only });
    defer fs.close(io);

    var buffer: [128]u8 = @splat(0);
    var fs_reader = fs.reader(io, &buffer);
    const reader = &fs_reader.interface;

    const header = try Header.parse(reader);
    var moov = try Moov.parse(allocator, header, reader);
    defer moov.deinit(allocator);

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try moov.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(moov.size(), wa.writer.buffered().len);

    var reader2 = Reader.fixed(wa.writer.buffered());
    const header2 = try Header.parse(&reader2);
    var moov2 = try Moov.parse(allocator, header2, &reader2);
    defer moov2.deinit(allocator);

    try std.testing.expectEqual(moov.mvhd.timescale, moov2.mvhd.timescale);
    try std.testing.expectEqual(moov.mvhd.duration, moov2.mvhd.duration);
    try std.testing.expectEqual(moov.mvhd.next_track_id, moov2.mvhd.next_track_id);
    try std.testing.expectEqual(moov.traks.items.len, moov2.traks.items.len);
    try std.testing.expectEqual(moov.traks.items[0].timescale(), moov2.traks.items[0].timescale());
    try std.testing.expectEqual(moov.traks.items[1].timescale(), moov2.traks.items[1].timescale());
}

test "Mhed: version 0 serialize-parse" {
    const allocator = std.testing.allocator;
    const mhed = Mehd{ .version = 0, .fragment_duration = 5000 };

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try mhed.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(mhed.size(), wa.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 16), mhed.size()); // 12 + (0+1)*4

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const mhed2 = try Mehd.parse(&reader, header);

    try std.testing.expectEqual(mhed.version, mhed2.version);
    try std.testing.expectEqual(mhed.fragment_duration, mhed2.fragment_duration);
}

test "Mhed: version 1 serialize-parse" {
    const allocator = std.testing.allocator;
    const mhed = Mehd{ .version = 1, .fragment_duration = 0x1_0000_0000 };

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try mhed.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(mhed.size(), wa.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 20), mhed.size()); // 12 + (1+1)*4

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const mhed2 = try Mehd.parse(&reader, header);

    try std.testing.expectEqual(mhed.version, mhed2.version);
    try std.testing.expectEqual(mhed.fragment_duration, mhed2.fragment_duration);
}

test "Mhed: rejects invalid size" {
    // size = 15, but version 0 requires 16
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0F, // size = 15
        'm', 'h', 'e', 'd', // type = mhed
        0x00, // version = 0
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidMehdBox, Mehd.parse(&reader, header));
}

test "Trex: serialize-parse" {
    const allocator = std.testing.allocator;
    const trex = Trex{
        .track_id = 1,
        .default_sample_description_index = 1,
        .default_sample_duration = 512,
        .default_sample_size = 200,
        .default_sample_flags = 0x10000,
    };

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try trex.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(trex.size(), wa.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 32), trex.size()); // 12 + 20

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    const trex2 = try Trex.parse(&reader, header);

    try std.testing.expectEqual(trex.track_id, trex2.track_id);
    try std.testing.expectEqual(trex.default_sample_description_index, trex2.default_sample_description_index);
    try std.testing.expectEqual(trex.default_sample_duration, trex2.default_sample_duration);
    try std.testing.expectEqual(trex.default_sample_size, trex2.default_sample_size);
    try std.testing.expectEqual(trex.default_sample_flags, trex2.default_sample_flags);
}

test "Trex: rejects invalid size" {
    // size = 31, but trex is always 32
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x1F, // size = 31
        't', 'r', 'e', 'x', // type = trex
        0x00, 0x00, 0x00, 0x00, // version + flags
    };
    var reader = Reader.fixed(&data);
    const header = try Header.parse(&reader);
    try std.testing.expectError(error.InvalidTrexBox, Trex.parse(&reader, header));
}

test "Mvex: serialize-parse with mehd and single trex" {
    const allocator = std.testing.allocator;

    var mvex = Mvex{ .mehd = Mehd{ .version = 0, .fragment_duration = 10000 }, .trex = .empty };
    defer mvex.deinit(allocator);
    try mvex.trex.append(allocator, Trex{
        .track_id = 1,
        .default_sample_description_index = 1,
        .default_sample_duration = 512,
        .default_sample_size = 0,
        .default_sample_flags = 0,
    });

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try mvex.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(mvex.size(), wa.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 56), mvex.size()); // 8 + 16 (mehd v0) + 32 (trex)

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var mvex2 = try Mvex.parse(allocator, &reader, header);
    defer mvex2.deinit(allocator);

    try std.testing.expect(mvex2.mehd != null);
    try std.testing.expectEqual(mvex.mehd.?.fragment_duration, mvex2.mehd.?.fragment_duration);
    try std.testing.expectEqual(mvex.mehd.?.version, mvex2.mehd.?.version);
    try std.testing.expectEqual(@as(usize, 1), mvex2.trex.items.len);
    try std.testing.expectEqual(mvex.trex.items[0].track_id, mvex2.trex.items[0].track_id);
    try std.testing.expectEqual(mvex.trex.items[0].default_sample_duration, mvex2.trex.items[0].default_sample_duration);
}

test "Mvex: serialize-parse without mehd, multiple trex entries" {
    const allocator = std.testing.allocator;

    var mvex = Mvex{ .mehd = null, .trex = .empty };
    defer mvex.deinit(allocator);
    try mvex.trex.append(allocator, Trex{
        .track_id = 1,
        .default_sample_description_index = 1,
        .default_sample_duration = 512,
        .default_sample_size = 100,
        .default_sample_flags = 0,
    });
    try mvex.trex.append(allocator, Trex{
        .track_id = 2,
        .default_sample_description_index = 1,
        .default_sample_duration = 1024,
        .default_sample_size = 0,
        .default_sample_flags = 0x10000,
    });

    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();
    try mvex.write(&wa.writer);
    try wa.writer.flush();
    try std.testing.expectEqual(mvex.size(), wa.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 72), mvex.size()); // 8 + 32 + 32

    var reader = Reader.fixed(wa.writer.buffered());
    const header = try Header.parse(&reader);
    var mvex2 = try Mvex.parse(allocator, &reader, header);
    defer mvex2.deinit(allocator);

    try std.testing.expect(mvex2.mehd == null);
    try std.testing.expectEqual(@as(usize, 2), mvex2.trex.items.len);
    for (mvex.trex.items, mvex2.trex.items) |t1, t2| {
        try std.testing.expectEqual(t1.track_id, t2.track_id);
        try std.testing.expectEqual(t1.default_sample_description_index, t2.default_sample_description_index);
        try std.testing.expectEqual(t1.default_sample_duration, t2.default_sample_duration);
        try std.testing.expectEqual(t1.default_sample_size, t2.default_sample_size);
        try std.testing.expectEqual(t1.default_sample_flags, t2.default_sample_flags);
    }
}
