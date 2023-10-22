const std = @import("std");

const Record = union(enum) {
    Add: Add,
    Delete: Delete,
    //Convert: *const fn (from: anytype, to: anytype) void,

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
            serializable: Serializable,
        };

        const Size = enum {
            One,
            Many,
        };
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

    pub fn del(comptime name: []const u8) Record {
        return .{ .Delete = .{
            .name = name,
        } };
    }
};

const SerializableVersion = []const Record;
const Serializable = []const SerializableVersion;

const SerFieldInfo = struct { name: []const u8, info: Record.Info };

fn ReifySerializable(comptime serializable: Serializable) type {
    return ReifySerializableWithError(serializable, false);
}

fn getVersionHash(comptime field_infos: []const SerFieldInfo) u32 {
    var hash = std.hash.XxHash32.init(108501602);
    for (field_infos) |field| {
        hash.update(field.name);
        if (field.info.type == .type) {
            hash.update(@typeName(field.info.type.type));
        }
    }
    return hash.final();
}

fn ReifySerializableWithError(comptime serializable: Serializable, comptime comptime_error: bool) brk: {
    if (comptime_error) break :brk !type else break :brk type;
} {
    // poors man hashmap
    const Store = struct { name: []const u8, info: Record.Info, deleted: bool };
    var fields_info: [256]Store = undefined;
    var fields_slice: []Store = fields_info[0..0];

    comptime var versionTypes: [serializable.len]type = undefined;

    for (serializable, 0..) |version, version_id| {
        for (version) |record| {
            switch (record) {
                .Add => |add| {
                    for (fields_slice) |*field| {
                        if (std.mem.eql(u8, field.name, add.name)) {
                            if (!field.deleted) {
                                if (comptime_error)
                                    return error.AddingValueThatAlreadyExsists
                                else
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
                                if (comptime_error)
                                    return error.FieldAlreadyDeleted
                                else
                                    @compileError("Can't remove field " ++ del.name ++ " as it was already removed in previous version");
                            }
                            field.deleted = true;
                            break;
                        }
                    } else {
                        if (comptime_error)
                            return error.FieldDoentExist
                        else
                            @compileError("Can't remove field " ++ del.name ++ " as it does not exist");
                    }
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
            var T: type = brk: {
                switch (field.info.type) {
                    .type => |t| break :brk t,
                    .serializable => |ser| {
                        const R = ReifySerializableWithError(ser, comptime_error);
                        break :brk if (comptime_error) try R.CurrentVersion.T else R.CurrentVersion.T;
                    },
                }
            };

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

        versionTypes[version_id] = struct {
            pub const T = VersionType;
            pub const version_fields = field_packed_final;
            pub const hash = getVersionHash(&version_fields);

            pub fn deserialize(value: *T, reader: anytype) !void {
                inline for (version_fields) |field| {
                    switch (field.info.type) {
                        .type => |FieldType| {
                            @field(value, field.name) = try reader.readIntBig(FieldType);
                        },
                        .serializable => |ser| {
                            const R = ReifySerializableWithError(ser, comptime_error);
                            @field(value, field.name) = try R.deserialize(reader);
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

                // todo : add user conversion routines
            }
        };
    }

    return struct {
        const versions: [versionTypes.len]type = versionTypes;
        const CurrentVersion: type = versionTypes[versionTypes.len - 1];

        pub fn serialize(value: CurrentVersion.T, writer: anytype) !void {
            try writer.writeIntBig(u16, versionTypes.len - 1);
            try writer.writeIntBig(u32, CurrentVersion.hash);

            inline for (CurrentVersion.version_fields) |field| {
                switch (field.info.type) {
                    .type => |FieldType| {
                        try writer.writeIntBig(FieldType, @field(value, field.name));
                    },
                    .serializable => |ser| {
                        const SerT = ReifySerializableWithError(ser, comptime_error);
                        try SerT.serialize(@field(value, field.name), writer);
                    },
                }
            }
        }

        pub fn deserialize(reader: anytype) !CurrentVersion.T {
            const version_id: usize = @intCast(try reader.readIntBig(u16));
            if (version_id > versions.len)
                return error.UnknownVersion;

            return deserializeVersionRec(0, version_id, reader, null);
        }

        inline fn deserializeVersionRec(comptime current_version: usize, start_version: usize, reader: anytype, value: ?versions[current_version].T) !CurrentVersion.T {
            var val = value;
            const Version = versions[current_version];
            if (current_version == start_version) {
                var hash = try reader.readIntBig(u32);
                if (hash != Version.hash)
                    return error.WrongVersionHash;

                val = .{};
                try Version.deserialize(&val.?, reader);
            }

            if (current_version < versions.len - 1) {
                const NextVer = versions[current_version + 1];

                var next_val: ?NextVer.T = null;
                if (val) |val_not_null| {
                    next_val = NextVer.T{};
                    NextVer.convert(val_not_null, &next_val.?);
                }

                return try deserializeVersionRec(current_version + 1, start_version, reader, next_val);
            } else {
                return val.?;
            }
        }
    };
}

test {
    const R = Record;

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
            R.addSer("foobar", child),
        },
        // V2
        &.{
            R.del("decay"),
        },
    };

    const T = ReifySerializable(ser);

    var t: T.CurrentVersion.T = .{};

    try std.testing.expectEqual(@as(u8, 99), t.foobar.foo);
    try std.testing.expectEqual(@as(u8, 42), t.attack);

    t.attack = 123;
    t.foobar.bar = 211;

    var buffer: [128]u8 = undefined;
    var writerBuff = std.io.fixedBufferStream(&buffer);
    try T.serialize(t, writerBuff.writer());

    std.debug.print("\n{any}\n", .{writerBuff.getWritten()});

    var readerBuff = std.io.fixedBufferStream(&buffer);
    var unser = try T.deserialize(readerBuff.reader());

    try std.testing.expectEqualDeep(t, unser);
}