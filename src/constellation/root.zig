const std = @import("std");

pub const runtime = @import("runtime.zig");
pub const profiles = @import("profiles.zig");
pub const signaling = @import("signaling.zig");
pub const transport = @import("transport.zig");
pub const catalog = @import("catalog.zig");
pub const permission_reviewer = @import("permission_reviewer.zig");
pub const bundle = @import("bundle.zig");
pub const provider = @import("provider.zig");
pub const commands = @import("commands.zig");
pub const editor = @import("editor.zig");
pub const transcript = @import("transcript.zig");
pub const surfaces = @import("surfaces.zig");
pub const integration = @import("integration.zig");
pub const tui = @import("tui.zig");
pub const console_runtime = @import("console_runtime.zig");
pub const theme = @import("theme.zig");

pub const product_name = "constellation";
pub const mvp_scope = "Constellation-exclusive agent harness underneath T3 Code backed by Constellation Router";

test {
    _ = runtime;
    _ = profiles;
    _ = signaling;
    _ = transport;
    _ = catalog;
    _ = permission_reviewer;
    _ = bundle;
    _ = provider;
    _ = commands;
    _ = editor;
    _ = transcript;
    _ = surfaces;
    _ = integration;
    _ = tui;
    _ = theme;
    _ = @import("tui_render_tests.zig");
}

test "constellation root exposes the mvp scope" {
    try std.testing.expectEqualStrings("constellation", product_name);
    try std.testing.expect(mvp_scope.len > 0);
}
