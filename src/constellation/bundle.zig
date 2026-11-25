const std = @import("std");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");
const types = @import("../core/shared/types.zig");
const runtime = @import("runtime.zig");
const transport = @import("transport.zig");
const catalog = @import("catalog.zig");
const permission_reviewer = @import("permission_reviewer.zig");

pub const presentation = provider_catalog.Entry{
    .id = .gateway,
    .slug = "constellation",
    .aliases = &.{ "cxn", "gateway" },
    .name = "Constellation Router",
    .route_name = "Constellation Router",
    .description = "Constellation Router dynamic inference",
    .subscription = false,
    .login_source = .ai_gateway_api_key,
};

pub fn fallbackModelCapabilities(_: []const u8) model_capabilities.Capabilities {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("medium"),
        types.ReasoningEffort.literal("high"),
        types.ReasoningEffort.literal("xhigh"),
    };
    return .{
        .supports_reasoning = true,
        .reasoning_efforts = model_capabilities.ReasoningEffortOptions.fromSlice(&efforts),
        .supports_fast_mode = false,
        .supports_tool_use = true,
        .supports_vision = true,
        .supports_file_input = true,
        .image_input_support = .native,
        .supports_web_search = false,
        .supports_explicit_caching = false,
        .supports_implicit_caching = true,
        .parallel_tool_calls = true,
        .context_window = 200_000,
    };
}

fn unavailablePreferredBackends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
    return null;
}

fn unavailableWebSearchExecute(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: web_search_provider.Inputs,
    _: web_search_contract.ProviderRequest,
    _: ?web_search_contract.ProgressFn,
    _: ?*anyopaque,
) anyerror!web_search_contract.ProviderResponse {
    return error.WebSearchUnavailable;
}

const unavailable_fx_search_provider = web_search_provider.Provider{
    .policy = .{},
    .preferred_backends_fn = unavailablePreferredBackends,
    .execute_fn = unavailableWebSearchExecute,
};

pub const provider_bundle = provider_set.Bundle{
    .capabilities = .{
        .fx_search = false,
        .vision_fallback = false,
    },
    .presentation = &presentation,
    .auth_strategy = null,
    .fallback_model_capabilities_fn = fallbackModelCapabilities,
    .agent_stream = transport.agent_stream_provider,
    .cli_model_catalog = catalog.cli_model_catalog_provider,
    .model_catalog = catalog.model_catalog_provider,
    .permission_reviewer = permission_reviewer.provider,
    .credits = gateway_provider.unavailable_credits_provider,
    .fx_search = unavailable_fx_search_provider,
};

/// Exclusive Constellation provider set. Every slot resolves to Constellation
/// Router so stale upstream provider preferences can never leak to Vercel,
/// ChatGPT/Codex, or Grok.
pub const provider_set_exclusive = provider_set.Set{
    .gateway = provider_bundle,
    .codex = provider_bundle,
    .grok = provider_bundle,
};

fn resolveChatUrl(_: ?*anyopaque, _: []const u8) []const u8 {
    return runtime.resolveBaseUrl();
}

pub const gateway_provider_exclusive = gateway_provider.Provider{
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = .{ .resolve_fn = resolveChatUrl },
};

test "Constellation exclusive provider set routes every slot to Constellation" {
    for ([_][]const u8{ "constellation/auto", "openai/gpt-5.4" }) |model| {
        const caps = provider_set_exclusive.gateway.fallbackModelCapabilities(model);
        try std.testing.expect(caps.supports_tool_use);
        try std.testing.expect(caps.supports_reasoning);
        try std.testing.expectEqual(@as(u32, 200_000), caps.context_window.?);
    }
    try std.testing.expectEqualStrings("constellation", provider_set_exclusive.select(.gateway).presentation.?.slug);
    try std.testing.expectEqualStrings("constellation", provider_set_exclusive.select(.codex).presentation.?.slug);
    try std.testing.expectEqualStrings("constellation", provider_set_exclusive.select(.grok).presentation.?.slug);
    try std.testing.expect(!provider_set_exclusive.gateway.capabilities.fx_search);
    try std.testing.expect(!provider_set_exclusive.gateway.capabilities.vision_fallback);
}
