pub const tcp_client = @import("tcp_client.zig");
pub const display_logic = @import("display_logic.zig");
pub const simulator = @import("simulator.zig");
pub const sdf_common = @import("sdf_common.zig");
pub const dsl_parser = @import("dsl_parser.zig");
pub const dsl_runtime = @import("dsl_runtime.zig");
pub const dsl_c_emitter = @import("dsl_c_emitter.zig");

pub const display_height: u16 = tcp_client.default_display_height;
pub const display_width: u16 = tcp_client.default_display_width;
pub const default_frame_rate_hz: u16 = tcp_client.default_frame_rate_hz;

pub const PixelFormat = tcp_client.PixelFormat;
pub const TcpClient = tcp_client.TcpClient;
pub const TcpClientConfig = tcp_client.Config;
pub const DisplayBuffer = display_logic.DisplayBuffer;
pub const DisplayConfig = display_logic.Config;

test {
    _ = @import("tcp_client.zig");
    _ = @import("display_logic.zig");
    _ = @import("simulator.zig");
    _ = @import("sdf_common.zig");
    _ = @import("dsl_parser.zig");
    _ = @import("dsl_runtime.zig");
    _ = @import("dsl_c_emitter.zig");
}
