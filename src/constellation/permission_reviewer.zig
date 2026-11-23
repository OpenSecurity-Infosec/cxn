const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const responses_reviewer = @import("../gateway/responses_permission_reviewer.zig");
const runtime = @import("runtime.zig");
const transport = @import("transport.zig");

const Allocator = std.mem.Allocator;

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewConstellation,
};

fn reviewConstellation(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return responses_reviewer.review(alloc, input, request, .{
        .source = .ai_gateway_api_key,
        .model = runtime.resolveReviewModel(runtime.default_review_model),
        .require_account = false,
        .validate_fn = validateCredential,
        .build_fn = transport.buildRequest,
        .send_fn = sendPrepared,
    });
}

fn validateCredential(
    _: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    if (input.credential.len == 0) return error.MissingConstellationApiKey;
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return transport.streamPrepared(alloc, request, payload);
}

test "Constellation reviewer builds a public-allowlisted Responses request" {
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "Review the pending action." }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "User requested the change." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{
                .id = "call_review",
                .name = "write_file",
                .arguments_json = "{\"path\":\"a.txt\"}",
            }},
        },
    };
    var cancelled = std.atomic.Value(bool).init(false);
    const body = try responses_reviewer.buildPayloadForTest(
        std.testing.allocator,
        runtime.default_review_model,
        &instructions,
        &messages,
        "call_review",
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
        transport.buildRequest,
    );
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("constellation/auto", obj.get("model").?.string);
    try std.testing.expectEqualStrings("required", obj.get("tool_choice").?.string);
    try std.testing.expect(obj.get("text") == null);
    try std.testing.expect(obj.get("service_tier") == null);
    try std.testing.expect(std.mem.find(u8, body, "ai-gateway") == null);
}
