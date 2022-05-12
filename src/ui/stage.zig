// NOTE: Below this point is unfinished thoughts

pub const StagePipelines = struct {
    /// Takes an array of layout nodes and returns screen space rectangles
    /// for rendering and events
    pub fn layout(layout_list: []LayoutNode) LayoutResult {}
    /// Recieve pointer input, return a user event
    pub fn point([]PointerListenNode, event: Event) ?UserEvent {}
    /// Recieve a focus input, return a user event
    pub fn focus([]FocusNodes, event: Event) ?UserEvent {}
};

/// A default UI renderer
pub const Painter = struct {
    pub fn paint(this: @This()) void {}
};

pub const Stage2 = struct {
    nodes: std.ArrayList(LayoutNode),
    pub fn init() @This() {}
    pub fn layout() void {}
    fn layout_raw() LayoutResult {}
};

pub const LayoutNodeType = enum {
    Container,
    Frame,
    Control,
};

pub const LayoutNode = union(LayoutNodeType) {
    Container: ContainerNode,
    Frame: FrameNode,
    Control: ControlNode,

    pub const ContainerNode = struct {
        /// What layout function to use on children
        layout: Layout,
        /// How many descendants this node has
        descendants: usize,
    };

    pub const FrameNode = struct {
        /// Stores the style of the frame. The Painter struct determines how the value
        /// is interpreted.
        style: usize,
        /// Space between each edge of the bounding box and child components.
        padding: Rect,
    };

    pub const ControlNode = struct {
        /// User specified type
        data: Store.Ref,
        /// Minimum size of the element
        size: Vec,
    };
};

/// Rules give behavior to nodes.
pub const Rule = union(enum) {
    grab_focus,
    set_style: usize,
    stop_and_emit: UserEvent,
    stop,
};
fn execute_rule(stage, node, rule) ?UserEvent {}

const EventFilter = union(enum) {
    Prevent,
    Pass,
    PassExcept: Event,
};

pub const ListenNode = struct {
    /// Index of layout node
    target: usize,
};

pub const PointerListenNode = struct {
    target: usize,
    event: Event, // Can we just create one of these lists for each event that is listened to?
    /// If the node prevents other nodes from recieving events after it
    filter: EventFilter,
    bounds: geom.Rect,
};

pub const RenderNode = union(enum) {
    DataNode: DataNode,
    FrameNode: FrameNode,

    /// Frames are background elements, used to seperate content and add emphasis.
    /// NOTE: These are separated from the DataNode type because I expect there to be
    /// a great deal more of them.
    /// TODO: Build more UIs and determine if this is actually the case.
    pub const FrameNode = struct {
        style: usize,
        bounds: geom.Rect,
    };

    /// Data nodes are user defined. The data can be a i32, f32, or slice of u8's.
    /// Use T to store the node "type". In other words, use T to tell the renderer how
    /// to interpret the value in the `data` field. Possible uses include graphs,
    /// progress bars, labels, tickers, calenders, clocks, etc.
    pub const DataNode = struct {
        T: u16,
        data: store.Value,
        bounds: geom.Rect,
    };
};

/// Stores the result of running the layout algorithms. Must be recomputed every time
/// the layout changes.
pub const LayoutResult = struct {
    /// Loop from the bottom to the top.
    pointer_listen_list: []PointerListenNode,
    /// Loop from the top to the bottom, drawing new nodes on top of old
    /// nodes. If overdraw of UI elements is a concern for you, let me know -
    /// I don't think it will be the bottleneck in the vast majority of cases.
    render_list: []RenderNode,
};
