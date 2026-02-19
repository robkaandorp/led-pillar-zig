pub const tcp_client = @import("tcp_client.zig");
pub const display_logic = @import("display_logic.zig");
pub const effects = @import("effects.zig");
pub const simulator = @import("simulator.zig");
pub const sdf_common = @import("sdf_common.zig");
pub const dsl_parser = @import("dsl_parser.zig");
pub const dsl_runtime = @import("dsl_runtime.zig");

pub const display_height: u16 = tcp_client.default_display_height;
pub const display_width: u16 = tcp_client.default_display_width;
pub const default_frame_rate_hz: u16 = tcp_client.default_frame_rate_hz;

pub const PixelFormat = tcp_client.PixelFormat;
pub const TcpClient = tcp_client.TcpClient;
pub const TcpClientConfig = tcp_client.Config;
pub const DisplayBuffer = display_logic.DisplayBuffer;
pub const DisplayConfig = display_logic.Config;
pub const PixelHealthTestConfig = effects.PixelHealthTestConfig;
pub const RunningDotConfig = effects.RunningDotConfig;
pub const SoapBubblesConfig = effects.SoapBubblesConfig;
pub const CampfireConfig = effects.CampfireConfig;
pub const AuroraRibbonsConfig = effects.AuroraRibbonsConfig;
pub const RainRippleConfig = effects.RainRippleConfig;
pub const InfiniteLineConfig = effects.InfiniteLineConfig;
pub const InfiniteLinesConfig = effects.InfiniteLinesConfig;

test {
    _ = @import("tcp_client.zig");
    _ = @import("display_logic.zig");
    _ = @import("effects.zig");
    _ = @import("simulator.zig");
    _ = @import("sdf_common.zig");
    _ = @import("dsl_parser.zig");
    _ = @import("dsl_runtime.zig");
}
