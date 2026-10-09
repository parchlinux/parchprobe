pub fn List(comptime T: type) type {
    return struct {
        list: ?*c.alpm_list_t = null,

        pub const Iterator = struct {
            list: ?*c.alpm_list_t,

            pub fn next(self: *Iterator) ?T {
                const node = self.list orelse return null;
                self.list = c.alpm_list_next(self.list);
                return @ptrCast(@alignCast(node.data.?));
            }
        };

        pub fn fromSlice(gpa: mem.Allocator, slice: []const T) !@This() {
            var list: @This() = .{};
            for (slice) |item| try list.add(gpa, item);
            return list;
        }

        pub fn iterator(self: *const @This()) Iterator {
            return .{ .list = self.list };
        }

        pub fn eql(self: @This(), other: @This()) bool {
            var it_a = self.iterator();
            while (it_a.next()) |a| {
                var it_b = other.iterator();
                if (it_b.next()) |b| {
                    if (!mem.eql(u8, mem.span(a), mem.span(b))) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        }

        pub fn add(self: *@This(), gpa: mem.Allocator, data: T) !void {
            try self.appendInternal(gpa, @ptrCast(@constCast(data)));
        }

        pub fn count(self: *const @This()) usize {
            return @intCast(c.alpm_list_count(self.list));
        }

        pub fn empty(self: *const @This()) bool {
            return self.list == null;
        }

        // It's good practice for the name 'append' to signify adding to the end.
        pub fn append(self: *@This(), gpa: mem.Allocator, data: T) !void {
            std.debug.assert(self.list != null);
            try self.appendInternal(gpa, @ptrCast(@constCast(data)));
        }

        fn appendInternal(self: *@This(), gpa: mem.Allocator, data: *anyopaque) !void {
            var new_node = try gpa.create(c.alpm_list_t);
            new_node.data = data;
            new_node.next = null;
            // new_node.prev will be set below.
            defer self.list = new_node;

            if (self.list) |head| {
                // List exists: find the end and link the new node.
                const last = head.prev;
                last.*.next = new_node;
                new_node.prev = last;
                self.list.?.prev = new_node;
            } else {
                // List is empty: the new node becomes the head.
                self.list = new_node;
                new_node.prev = new_node;
            }
        }
    };
}

pub fn ListWrapper(comptime T: type, comptime ChildType: type) type {
    return struct {
        child: Child,

        const Child = List(ChildType);

        pub const Iterator = struct {
            iter: Child.Iterator,

            pub fn next(self: *Iterator) ?T {
                return .{
                    .ptr = self.iter.next() orelse return null,
                };
            }
        };

        pub fn count(self: *const @This()) usize {
            return self.child.count();
        }

        pub fn empty(self: *const @This()) bool {
            return self.child.empty();
        }

        pub fn fromList(list: ?*c.alpm_list_t) @This() {
            return .{ .child = .{ .list = list } };
        }

        pub fn findGroupPackages(self: *const @This(), name: [*:0]const u8) Package.List {
            if (T != alpm.Database) @compileError("unsupported operation");
            return .fromList(c.alpm_find_group_pkgs(self.child.list, name));
        }

        pub fn iterator(self: *const @This()) Iterator {
            return .{
                .iter = self.child.iterator(),
            };
        }
    };
}

const std = @import("std");
const mem = std.mem;
const alpm = @import("../alpm.zig");
const Package = alpm.Package;
const c = @import("c");
