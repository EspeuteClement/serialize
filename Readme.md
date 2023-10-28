# Serialize
## Disclaimer
This library has not been thoroughly tested against malicious data and properly fused.
Most of the library assumes that the reader interface will properly handle data that is
too long. There is also currently no checksum in place to check if the data has been
properly deserialized.
Use at your own risk.
## Goals
Proof of concept serialization library for zig, with built in versioning and
backwards compatibility (can open previous version of serialized data), with
support for custom upgrade functions, serializable inside a serializable struct and
slices.
## Usage
Use the `Serializable` function to create a Struct that will contains the following decls :
- `Struct` : The actual struct you can use to store your data
- `serialize(value: Struct, writer: anytype) !void` : The function that will allow you to serialize your data
to the writer struct of your choice as a binary stream.
- `deserialize(reader:anytype, allocator: ?std.mem.Allocator) !Struct` : The function to transform data outputted by the serialize function back to a Struct. Optionally takes an allocator if Struct has some dynamically allocated data (if you used `Record.addMany()` or `Record.addSerMany()` inside).

The `Serializable` function takes a Definition as its sole parameter. This `Definition` is a slice of `Version`, which is a slice of `Record`
Records are additions or removals of fields to the final struct. Here's an example :
```zig
    const ser: Definition = &.{
        // V0
        &.{
            Record.add("foo", u8, 42),
        },
        // V1
        &.{
            Record.add("bar", u8, 0),
            Record.remove("foo"),
        },
    };

    var Ser = Serializable(Definition);
    var ser : Ser.Struct;
    ser.bar = 99;

    // serialize to a writer
    Ser.serialize(ser, writer);

    // deserialize from a reader
    var other_ser = Ser.deserialize(reader, null); 
```
We can see that the Version 0 of our struct will only have a `foo` field that is an u8 and will have a default value of 42
then in version 1 we add the `bar` field and remove the old `foo` field.
The Serializable(ser) function will then gives us a struct with the decl Struct equals to
Struct = struct {
    bar : u8 = 0,
};
## Supported features
- Serialize arbitrary integer values
- Serialize arbitrary packed structs
- Serialize arrays of the above types
- Serialize other serializable objects : use Record.addSer();
- Serialize slices of the above types : use Record.addMany() or Record.addSerMany();
Floating point types are not supported as they don't have a portable memory layout representation
## Binary format
```
header :
    struct_version: u16
    struct_hash: u32  // Struct hash is a hash of the name and types of all the fields present in this version of the struct, used
                      // to check if the saved struct has the same layout as the one we are trying to load

fields :
    for each field in the struct:
        if the value is a simple type:
            the value serialized as a little endian integer
        if the value is an array type:
            for array.len:
                the value serialized as a little endian integer
        if the value is a serializable
            the serializable serialized with its header
        if the value is a slice
            length of the slice: u16
            then the value serialized as one of the above types
```