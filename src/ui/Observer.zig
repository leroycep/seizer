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

const NotifyResult = struct { emit: u16, emit_blur: u16, emit_exit: u16, node: ?Node };

pub fn notify_pointer(observer: *Observer, stage: *Stage, e: seizer.event.Event, mouse_pos: geom.Vec2) NotifyResult {
    var result = NotifyResult{ .emit = 0, .emit_blur = 0, .emit_exit = 0, .node = null };
    if (stage.get_node_at_point(mouse_pos)) |*node| {
        result.emit_exit = observer.exit(stage, e);
        result.emit_blur = observer.unfocus(stage, e);
        switch (e) {
            .MouseMotion => {
                result.emit = advancePollAction(observer.transitions, node, .enter);
                observer.hover = node.*;
            },
            .MouseButtonDown => {
                const can_focus = observer.focusable(node.*);
                result.emit = advancePollAction(observer.transitions, node, .press);
                if (can_focus) observer.focus = node.*;
            },
            .MouseButtonUp => {
                result.emit = advancePollAction(observer.transitions, node, .release);
            },
            else => {},
        }
        _ = stage.set_node(node.*);
        result.node = node.*;
    } else {
        result.emit_exit = observer.exit(stage, e);
        result.emit_blur = observer.unfocus(stage, e);
    }
    // We are *definitely* in bounds now
    return result;
}

fn focusable(observer: *Observer, node: Node) bool {
    for (observer.transitions) |transition| {
        if (node.style == transition.end and transition.event == .onblur) {
            return true;
        }
    }
    return false;
}

fn unfocus(observer: *Observer, stage: *Stage, e: seizer.event.Event) u16 {
    if (e == .MouseButtonDown) {
        if (observer.focus) |*focus| {
            const emit_blur = advancePollAction(observer.transitions, focus, .onblur);
            _ = stage.set_node(focus.*);
            observer.focus = null;
            return emit_blur;
        }
    }
    return 0;
}

fn exit(observer: *Observer, stage: *Stage, e: seizer.event.Event) u16 {
    if (e == .MouseMotion) {
        if (observer.hover) |*hover| {
            const emit_exit = advancePollAction(observer.transitions, hover, .exit);
            _ = stage.set_node(hover.*);
            observer.hover = null;
            return emit_exit;
        }
    }
    return 0;
}

// -------------------------------------------------------------------------------------------------

fn advancePollAction(transitions: []const Transition, node: *Node, condition: Condition) Action {
    for (transitions) |transition| {
        if (node.style == transition.begin and transition.event == condition) {
            node.style = transition.end;
            return transition.emit;
        }
    }
    return 0;
}
