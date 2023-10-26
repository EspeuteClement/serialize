const std = @import("std");

const Record = union(enum) {
    Add: Add,
    Delete: Delete,
    Convert: ConvertFunc,

    pub const ConvertFunc = *const fn (from: anytype, to: anytype) void;

    pub const Add = struct {
        name: []const u8,
        info: Info,
    };

    pub const Info = struct {
        type: FieldType,
        default: ?*const anyopaque,
        size: Size,

        const FieldType = union(enum) {
            type: type,
            serializable: type,
        };

        const Size = enum {
            One,
            Many,
        };

        pub fn getType(comptime self: Info) type {
            return switch (self.size) {
                .One => self.getSimpleType(),
                .Many => []self.getSimpleType(),
            };
        }

        pub fn getSimpleType(comptime self: Info) type {
            return switch (self.type) {
                .type => |t| t,
                .serializable => |s| s.CurrentVersion.T,
            };
        }

        fn deserializeOne(comptime self: Info, reader: anytype, allocator: ?std.mem.Allocator) !self.getSimpleType() {
            switch (self.type) {
                .type => |T| {
                    return readValue(T, reader);
                },
                .serializable => |ser| {
                    return ser.deserialize(reader, allocator);
                },
            }
        }

        fn serializeOne(comptime self: Info, value: self.getSimpleType(), writer: anytype) !void {
            switch (self.type) {
                .type => {
                    try writeValue(value, writer);
                },
                .serializable => |ser| {
                    try ser.serialize(value, writer);
                },
            }
        }
    };

    pub const Delete = struct {
        name: []const u8,
    };

    pub fn add(comptime name: []const u8, comptime T: type, comptime def: T) Record {
        return .{ .Add = .{ .name = name, .info = .{
            .type = .{ .type = T },
            .default = &def,
            .size = .One,
        } } };
    }

    pub fn addSer(comptime name: []const u8, comptime ser: Serializable) Record {
        return .{ .Add = .{ .name = name, .info = .{
            .type = .{ .serializable = ser },
            .default = null,
            .size = .One,
        } } };
    }

    pub fn addSerMany(comptime name: []const u8, comptime ser: Serializable) Record {
        var SerT = ReifySerializable(ser);
        const def: []SerT.CurrentVersion.T = &.{};
        return .{ .Add = .{ .name = name, .info = .{
            .type = .{ .serializable = SerT },
            .default = @ptrCast(&def),
            .size = .Many,
        } } };
    }

    pub fn del(comptime name: []const u8) Record {
        return .{ .Delete = .{
            .name = name,
        } };
    }
};

const SerializableVersion = []const Record;
const Serializable = []const SerializableVersion;

const SerFieldInfo = struct {
    name: []const u8,
    info: Record.Info,
};

fn getVersionHash(comptime field_infos: []const SerFieldInfo) u32 {
    var hash = std.hash.XxHash32.init(108501602);
    for (field_infos) |field| {
        hash.update(field.name);
        if (field.info.type == .type) {
            hash.update(@typeName(field.info.type.type));
            switch (@typeInfo(field.info.type.type)) {
                .Struct => |S| {
                    for (S.fields) |struct_field| {
                        hash.update(struct_field.name);
                        hash.update(@typeName(struct_field.type));
                    }
                },
                else => {},
            }
        }
    }
    return hash.final();
}

fn ReifySerializable(comptime serializable: Serializable) type {
    // poors man hashmap
    const Store = struct { name: []const u8, info: Record.Info, deleted: bool };
    var fields_info: [256]Store = undefined;
    var fields_slice: []Store = fields_info[0..0];

    comptime var versionTypes: [serializable.len]type = undefined;

    for (serializable, 0..) |version, version_id| {
        var convertFunc: ?Record.ConvertFunc = null;

        for (version) |record| {
            switch (record) {
                .Add => |add| {
                    for (fields_slice) |*field| {
                        if (std.mem.eql(u8, field.name, add.name)) {
                            if (!field.deleted) {
                                @compileError("Can't add field " ++ add.name ++ " as it already exists in previous version");
                            }
                            field.info = add.info;
                            field.deleted = false;
                            break;
                        }
                    } else {
                        fields_slice = fields_info[0 .. fields_slice.len + 1];
                        fields_slice[fields_slice.len - 1] = .{
                            .name = add.name,
                            .info = add.info,
                            .deleted = false,
                        };
                    }
                },
                .Delete => |del| {
                    for (fields_slice) |*field| {
                        if (std.mem.eql(u8, field.name, del.name)) {
                            if (field.deleted) {
                                @compileError("Can't remove field " ++ del.name ++ " as it was already removed in previous version");
                            }
                            field.deleted = true;
                            break;
                        }
                    } else {
                        @compileError("Can't remove field " ++ del.name ++ " as it does not exist");
                    }
                },
                .Convert => |func| {
                    if (convertFunc != null)
                        @compileError("A convert func already defined for this version");
                    convertFunc = func;
                },
            }
        }

        var count_active: usize = 0;
        for (fields_slice) |field| {
            if (field.deleted == false)
                count_active += 1;
        }

        var struct_fields: [count_active]std.builtin.Type.StructField = undefined;
        var field_packed: [count_active]SerFieldInfo = undefined;

        var count: usize = 0;
        for (fields_slice) |field| {
            if (field.deleted)
                continue;
            defer count += 1;
            field_packed[count] = .{
                .name = field.name,
                .info = field.info,
            };

            var def_value = field.info.default;
            var T: type = field.info.getType();

            if (def_value == null) {
                const def: T = std.mem.zeroInit(T, .{});
                def_value = &def;
            }

            struct_fields[count] = .{
                .name = field.name,
                .type = T,
                .default_value = def_value,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        }

        const VersionType: type = @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        } });

        const field_packed_final = field_packed;

        const PreviousVersionType = if (version_id > 1) versionTypes[version_id - 1] else versionTypes[0];

        const finalConvert = convertFunc;

        versionTypes[version_id] = struct {
            pub const T = VersionType;
            pub const version_fields = field_packed_final;
            pub const hash = getVersionHash(&version_fields);

            pub fn deserialize(value: *T, reader: anytype, allocator: ?std.mem.Allocator) !void {
                inline for (version_fields) |field| {
                    switch (field.info.size) {
                        .One => {
                            @field(value, field.name) = try field.info.deserializeOne(reader, allocator);
                        },
                        .Many => {
                            if (allocator) |alloc| {
                                var alloc_count = try reader.readIntLittle(u16);

                                var buffer = try alloc.alloc(field.info.getSimpleType(), alloc_count);
                                @field(value, field.name) = buffer;
                                for (buffer) |*item| {
                                    item.* = try field.info.deserializeOne(reader, allocator);
                                }
                            } else {
                                return error.MissingAlloc;
                            }
                        },
                    }
                }
            }

            pub fn convert(prev: PreviousVersionType.T, ours: *VersionType) void {
                main: inline for (PreviousVersionType.version_fields) |field| {
                    // Only copy if field was not removed by next version
                    inline for (version) |record| {
                        switch (record) {
                            .Delete => |del| {
                                if (comptime std.mem.eql(u8, del.name, field.name)) {
                                    continue :main;
                                }
                            },
                            else => {},
                        }
                    }

                    @field(ours, field.name) = @field(prev, field.name);
                }

                if (finalConvert) |f| {
                    f(prev, &ours);
                }
            }
        };
    }

    return struct {
        const versions: [versionTypes.len]type = versionTypes;
        const CurrentVersion: type = versionTypes[versionTypes.len - 1];

        pub fn serialize(value: CurrentVersion.T, writer: anytype) !void {
            try writer.writeIntLittle(u16, versionTypes.len - 1);
            try writer.writeIntLittle(u32, CurrentVersion.hash);

            inline for (CurrentVersion.version_fields) |field| {
                switch (field.info.size) {
                    .One => try field.info.serializeOne(@field(value, field.name), writer),
                    .Many => {
                        if (std.math.cast(u16, @field(value, field.name).len)) |len| {
                            try writer.writeIntLittle(u16, len);
                            for (@field(value, field.name)) |item| {
                                try field.info.serializeOne(item, writer);
                            }
                        } else {
                            return error.SliceTooBig;
                        }
                    },
                }
            }
        }

        pub fn deserialize(reader: anytype, allocator: ?std.mem.Allocator) !CurrentVersion.T {
            const version_id: usize = @intCast(try reader.readIntLittle(u16));
            if (version_id > versions.len)
                return error.UnknownVersion;

            return deserializeVersionRec(0, version_id, reader, null, allocator);
        }

        inline fn deserializeVersionRec(comptime current_version: usize, start_version: usize, reader: anytype, value: ?versions[current_version].T, allocator: ?std.mem.Allocator) !CurrentVersion.T {
            var val = value;
            const Version = versions[current_version];
            if (current_version == start_version) {
                var hash = try reader.readIntLittle(u32);
                if (hash != Version.hash)
                    return error.WrongVersionHash;

                val = .{};
                try Version.deserialize(&val.?, reader, allocator);
            }

            if (current_version < versions.len - 1) {
                const NextVer = versions[current_version + 1];

                var next_val: ?NextVer.T = null;
                if (val) |val_not_null| {
                    next_val = NextVer.T{};
                    NextVer.convert(val_not_null, &next_val.?);
                }

                return try deserializeVersionRec(current_version + 1, start_version, reader, next_val, allocator);
            } else {
                return val.?;
            }
        }
    };
}

fn writeValue(value: anytype, writer: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .Int => try writer.writeIntLittle(T, value),
        .Array => {
            for (value) |v| {
                try writeValue(v, writer);
            }
        },
        .Struct => |s| {
            comptime if (s.layout != .Packed) @compileError("Struct must be packed, for more general structs see addSer()");
            try writer.writeIntLittle(s.backing_integer.?, @bitCast(value));
        },
        else => @compileError("Can't serialize " ++ @typeName(T)),
    }
}

fn readValue(comptime T: type, reader: anytype) !T {
    const info = @typeInfo(T);
    switch (info) {
        .Int => return try reader.readIntLittle(T),
        .Array => |array| {
            var values: T = undefined;
            for (&values) |*v| {
                v.* = try readValue(array.child, reader);
            }
            return values;
        },
        .Struct => |s| {
            comptime if (s.layout != .Packed) @compileError("Struct must be packed, for more general structs see addSer()");
            return @bitCast(try reader.readIntLittle(s.backing_integer.?));
        },
        else => @compileError("Can't unserialize " ++ @typeName(T)),
    }
}

// Generic struct with slice dealocator
pub fn deinit(value: anytype, allocator: std.mem.Allocator) void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .Struct => |str| {
            inline for (str.fields) |field| {
                deinit(@field(value, field.name), allocator);
            }
        },
        .Pointer => |ptr| {
            if (ptr.size != .Slice)
                @compileError("Struct has non slice pointers");
            allocator.free(value);
        },
        .Array => {
            for (value) |child| {
                deinit(child, allocator);
            }
        },
        else => {},
    }
}

test {
    const R = Record;

    const TestStruct = packed struct {
        x: u16 = 0,
        y: u16 = 42,
        z: u16 = 0,
    };

    const child: Serializable = &.{&.{
        R.add("foo", u8, 99),
        R.add("bar", u8, 10),
    }};

    const ser: Serializable = &.{
        // V0
        &.{
            R.add("attack", u8, 42),
        },
        // V1
        &.{
            R.add("decay", u8, 0),
            R.add("sustain", u8, 0),
            R.add("array", [8]u8, [_]u8{69} ** 8), // TODO : Support static arrays
            R.add("vector", TestStruct, TestStruct{}),
            R.addSerMany("foobar", child),
        },
        // V2
        &.{
            R.del("decay"),
            // R.del("decay"), // this should not compile
            // R.add("attack", u16, 99), // this also should not compile
        },
    };

    const T = ReifySerializable(ser);
    const Foobar = ReifySerializable(child);

    {
        var t: T.CurrentVersion.T = .{};

        try std.testing.expectEqual(@as(u8, 42), t.attack);
        try std.testing.expectEqual(@as(u16, 42), t.vector.y);

        t.attack = 123;
        t.foobar = try std.testing.allocator.alloc(Foobar.CurrentVersion.T, 6);
        defer std.testing.allocator.free(t.foobar);
        for (t.foobar, 0..) |*foobar, i| {
            foobar.* = .{
                .bar = @intCast(i * 2),
            };
        }

        try std.testing.expectEqual(@as(u8, 99), t.foobar[5].foo);
        try std.testing.expectEqual(@as(u8, 10), t.foobar[5].bar);

        var buffer: [128]u8 = undefined;
        var writerBuff = std.io.fixedBufferStream(&buffer);
        try T.serialize(t, writerBuff.writer());

        var readerBuff = std.io.fixedBufferStream(&buffer);
        var unser = try T.deserialize(readerBuff.reader(), std.testing.allocator);
        defer deinit(unser, std.testing.allocator);

        try std.testing.expectEqualDeep(t, unser);
    }

    {
        const ser2: Serializable = &.{
            // V0
            &.{
                R.add("attack", u8, 42),
            },
        };
        const T2 = ReifySerializable(ser2);
        // upgrade
        var v0: T2.CurrentVersion.T = .{};
        v0.attack = 123;

        var buffer: [128]u8 = undefined;
        var writerBuff = std.io.fixedBufferStream(&buffer);
        try T2.serialize(v0, writerBuff.writer());

        var expected: T.CurrentVersion.T = .{};
        expected.attack = 123;

        var readerBuff = std.io.fixedBufferStream(&buffer);
        var unser = try T.deserialize(readerBuff.reader(), std.testing.allocator);

        try std.testing.expectEqualDeep(expected, unser);
    }
}
