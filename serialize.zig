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

const SerrializableVersion = []const Record;
const Serializable = []const SerrializableVersion;

fn ReifySerializable(comptime serializable: Serializable) type {
    return ReifySerializableWithError(serializable, false);
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
                        if (field.name.ptr == add.name.ptr) {
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
                        if (field.name.ptr == del.name.ptr) {
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

        var count: usize = 0;
        for (fields_slice) |field| {
            if (field.deleted)
                continue;
            defer count += 1;

            var T: type = switch (field.info.type) {
                .type => |t| t,
                .serializable => @compileError("not handled yet"),
            };
            struct_fields[count] = .{
                .name = field.name,
                .type = T,
                .default_value = field.info.default,
                .is_comptime = false,
                .alignment = @alignOf(T),
            };
        }

        versionTypes[version_id] = @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    }

    return struct {
        const versions: [versionTypes.len]type = versionTypes;
        const T: type = versionTypes[versionTypes.len - 1];
    };
}

test {
    const R = Record;
    const ser: Serializable = &.{
        // V0
        &.{
            R.add("attack", u8, 42),
        },
        // V1
        &.{
            R.add("decay", u8, 0),
            R.add("sustain", u8, 0),
        },
        // V2
        &.{
            R.del("decay"),
        },
    };

    const T = ReifySerializable(ser);

    comptime {
        if (ser[1][0].Add.name.ptr != ser[2][0].Delete.name.ptr)
            @compileError("assert");
    }

    try std.testing.expectEqual(ser[1][0].Add.name.ptr, ser[2][0].Delete.name.ptr);
    var t: T.T = .{};
    std.debug.print("\n\n{any}\n\n", .{t});
}
