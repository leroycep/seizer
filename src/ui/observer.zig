const std = @import("std");
const seizer = @import("../seizer.zig");
const geom = seizer.geometry;
const Node = seizer.ui.Node;
const Stage = seizer.ui.Stage;

pub const State = u16;
pub const Condition = enum { enter, exit, press, release, onblur };
pub const Action = u16;
pub const Transition = struct { begin: State, event: Condition, end: State, emit: Action = 0 };

const Observer = @This();

focus: ?Node = null,
hover: ?Node = null,
transitions: []const Transition,

// pub fn init(transitions: []const Transition) Observer {
//     return Observer {
//         .transitions = transitions,
//     };
// }

const NotifyResult = struct { emit: u16, node: ?Node };

pub fn notify_pointer(observer: *Observer, stage: *Stage, e: seizer.event.Event, mouse_pos: geom.Vec2) NotifyResult {
    const hovered = observer.hover != null;
    const focused = observer.focus != null;
    const might_blur = (e == .MouseButtonDown and focused);
    const might_exit = (e == .MouseMotion and hovered);
    const node_opt = stage.get_node_at_point(mouse_pos);
    var emit: u16 = 0;
    if (might_blur and (node_opt == null or (node_opt != null and observer.focus.?.handle != node_opt.?.handle))) {
        emit = advancePollAction(observer.transitions, &observer.focus.?, .onblur);
        _ = stage.set_node(observer.focus.?);
        observer.focus = null;
    }
    if (might_exit and (node_opt == null or (node_opt != null and observer.hover.?.handle != node_opt.?.handle))) {
        emit = advancePollAction(observer.transitions, &observer.hover.?, .exit);
        _ = stage.set_node(observer.hover.?);
        observer.hover = null;
    }
    if (node_opt == null) return .{ .emit = emit, .node = null };
    var node = node_opt.?;
    // We are *definitely* in bounds now
    switch (e) {
        .MouseMotion => {
            emit = advancePollAction(observer.transitions, &node, .enter);
            observer.hover = node;
        },
        .MouseButtonDown => {
            emit = advancePollAction(observer.transitions, &node, .press);
            observer.focus = node;
        },
        .MouseButtonUp => {
            emit = advancePollAction(observer.transitions, &node, .release);
        },
        else => {},
    }
    _ = stage.set_node(node);
    return .{ .emit = emit, .node = node };
}

// -------------------------------------------------------------------------------------------------

pub fn advancePollAction(transitions: []const Transition, node: *Node, condition: Condition) Action {
    for (transitions) |transition| {
        if (node.style == transition.begin and transition.event == condition) {
            node.style = transition.end;
            return transition.emit;
        }
    }
    return 0;
}
