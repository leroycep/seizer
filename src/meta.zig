pub fn interfaceFromConcreteTypeFns(Interface: type, T: type, comptime concrete_type_fns: ConcreteTypeFns(Interface, T)) Interface {
    var interface: Interface = undefined;

    inline for (@typeInfo(Interface).Struct.fields) |field| {
        switch (@typeInfo(field.type)) {
            .Enum => @field(interface, field.name) = @field(concrete_type_fns, field.name),
            .Pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
                .Int => @field(interface, field.name) = @field(concrete_type_fns, field.name),
                .Fn => |fn_info| {
                    // Only replace anyopaque pointers in the first parameter
                    if (fn_info.params.len == 0 or fn_info.params[0].type != ?*anyopaque) {
                        @field(interface, field.name) = @field(concrete_type_fns, field.name);
                        continue;
                    }

                    comptime var Params: [fn_info.params.len]type = undefined;
                    for (&Params, fn_info.params) |*Param, param_info| {
                        Param.* = param_info.type.?;
                    }

                    const ptr_cast_fns = struct {
                        pub fn one_param(param0: Params[0]) fn_info.return_type.? {
                            return @call(
                                .always_inline,
                                @field(concrete_type_fns, field.name),
                                .{
                                    @as(*T, @ptrCast(@alignCast(param0))),
                                },
                            );
                        }
                        pub fn two_param(param0: Params[0], param1: Params[1]) fn_info.return_type.? {
                            return @call(
                                .always_inline,
                                @field(concrete_type_fns, field.name),
                                .{
                                    @as(*T, @ptrCast(@alignCast(param0))),
                                    param1,
                                },
                            );
                        }
                        pub fn three_param(param0: Params[0], param1: Params[1], param2: Params[2]) fn_info.return_type.? {
                            return @call(
                                .always_inline,
                                @field(concrete_type_fns, field.name),
                                .{
                                    @as(*T, @ptrCast(@alignCast(param0))),
                                    param1,
                                    param2,
                                },
                            );
                        }
                        pub fn four_param(param0: Params[0], param1: Params[1], param2: Params[2], param3: Params[3]) fn_info.return_type.? {
                            return @call(
                                .always_inline,
                                @field(concrete_type_fns, field.name),
                                .{
                                    @as(*T, @ptrCast(@alignCast(param0))),
                                    param1,
                                    param2,
                                    param3,
                                },
                            );
                        }
                        pub fn five_param(param0: Params[0], param1: Params[1], param2: Params[2], param3: Params[3], param4: Params[4]) fn_info.return_type.? {
                            return @call(
                                .always_inline,
                                @field(concrete_type_fns, field.name),
                                .{
                                    @as(*T, @ptrCast(@alignCast(param0))),
                                    param1,
                                    param2,
                                    param3,
                                    param4,
                                },
                            );
                        }
                        pub fn six_param(param0: Params[0], param1: Params[1], param2: Params[2], param3: Params[3], param4: Params[4], param5: Params[5]) fn_info.return_type.? {
                            return @call(
                                .always_inline,
                                @field(concrete_type_fns, field.name),
                                .{
                                    @as(*T, @ptrCast(@alignCast(param0))),
                                    param1,
                                    param2,
                                    param3,
                                    param4,
                                    param5,
                                },
                            );
                        }
                        pub fn seven_param(param0: Params[0], param1: Params[1], param2: Params[2], param3: Params[3], param4: Params[4], param5: Params[5], param6: Params[6]) fn_info.return_type.? {
                            return @call(
                                .always_inline,
                                @field(concrete_type_fns, field.name),
                                .{
                                    @as(*T, @ptrCast(@alignCast(param0))),
                                    param1,
                                    param2,
                                    param3,
                                    param4,
                                    param5,
                                    param6,
                                },
                            );
                        }
                    };

                    @field(interface, field.name) = switch (Params.len) {
                        1 => ptr_cast_fns.one_param,
                        2 => ptr_cast_fns.two_param,
                        3 => ptr_cast_fns.three_param,
                        4 => ptr_cast_fns.four_param,
                        5 => ptr_cast_fns.five_param,
                        6 => ptr_cast_fns.six_param,
                        7 => ptr_cast_fns.seven_param,
                        else => {
                            @compileLog("Unsupported number of function parameters", field.name, Params.len);
                            continue;
                        },
                    };
                },
                else => @compileError("Unsupported Interface field type: " ++ @typeName(field.type)),
            },
            else => @compileError("Unsupported Interface field type: " ++ @typeName(field.type)),
        }
    }

    return interface;
}

pub fn ConcreteTypeFns(Interface: type, Concrete: type) type {
    const generic_interface_info = @typeInfo(Interface).Struct;
    var concrete_interface_fields_info: [generic_interface_info.fields.len]std.builtin.Type.StructField = undefined;

    inline for (&concrete_interface_fields_info, generic_interface_info.fields) |*concrete_field_info, generic_field_info| {
        concrete_field_info.* = generic_field_info;

        const field_type_info = @typeInfo(concrete_field_info.type);
        if (std.meta.activeTag(field_type_info) != .Pointer) continue;

        const pointer_type_info = @typeInfo(field_type_info.Pointer.child);
        if (std.meta.activeTag(pointer_type_info) != .Fn) continue;

        // Only replace anyopaque pointers in the first parameter
        if (pointer_type_info.Fn.params.len == 0 or pointer_type_info.Fn.params[0].type != ?*anyopaque) continue;

        var new_params: [pointer_type_info.Fn.params.len]std.builtin.Type.Fn.Param = undefined;
        @memcpy(&new_params, pointer_type_info.Fn.params);
        new_params[0].type = *Concrete;

        var new_fn_info = pointer_type_info.Fn;
        new_fn_info.params = &new_params;

        concrete_field_info.type = @Type(.{ .Fn = new_fn_info });
    }

    var concrete_interface_info = generic_interface_info;
    concrete_interface_info.fields = &concrete_interface_fields_info;
    concrete_interface_info.decls = &.{};

    return @Type(.{ .Struct = concrete_interface_info });
}

const std = @import("std");
