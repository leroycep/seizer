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

const NotifyResult = struct { emit: u16, emit_blur: u16, emit_exit: u16,  node: ?Node };

pub fn notify_pointer(observer: *Observer, stage: *Stage, e: seizer.event.Event, mouse_pos: geom.Vec2) NotifyResult {
    const hovered = observer.hover != null;
    const focused = observer.focus != null;
    const might_blur = (e == .MouseButtonDown and focused);
    const might_exit = (e == .MouseMotion and hovered);
    const node_opt = stage.get_node_at_point(mouse_pos);
    var result = NotifyResult{ .emit = 0, .emit_blur = 0, .emit_exit = 0, .node = null };
    if (might_blur and (node_opt == null or (node_opt != null and observer.focus.?.handle != node_opt.?.handle))) {
        result.emit_blur = advancePollAction(observer.transitions, &observer.focus.?, .onblur);
        _ = stage.set_node(observer.focus.?);
        observer.focus = null;
    }
    if (might_exit and (node_opt == null or (node_opt != null and observer.hover.?.handle != node_opt.?.handle))) {
        result.emit_exit = advancePollAction(observer.transitions, &observer.hover.?, .exit);
        _ = stage.set_node(observer.hover.?);
        observer.hover = null;
    }
    if (node_opt == null) return result;
    var node = node_opt.?;
    result.node = node;
    // We are *definitely* in bounds now
    switch (e) {
        .MouseMotion => {
            result.emit = advancePollAction(observer.transitions, &node, .enter);
            observer.hover = node;
        },
        .MouseButtonDown => {
            result.emit = advancePollAction(observer.transitions, &node, .press);
            observer.focus = node;
        },
        .MouseButtonUp => {
            result.emit = advancePollAction(observer.transitions, &node, .release);
        },
        else => {},
    }
    _ = stage.set_node(node);
    return result;
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
