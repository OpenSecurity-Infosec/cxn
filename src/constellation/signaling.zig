const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const profiles = @import("profiles.zig");
const runtime = @import("runtime.zig");

pub const signal_version: u8 = 1;
pub const harness_name = "cxn";
pub const harness_version = runtime.version;

pub const Mode = enum {
    auto,
    headers,
    body,
    off,
};

pub const Phase = enum {
    initial_plan,
    tool_continuation,
    recovery,
    final_synthesis,

    pub fn label(self: Phase) []const u8 {
        return @tagName(self);
    }
};

pub const TaskClass = enum {
    exploration,
    mechanical_edit,
    debugging,
    verification,
    architecture,
    general,

    pub fn label(self: TaskClass) []const u8 {
        return @tagName(self);
    }
};

pub const Tier = enum {
    low,
    medium,
    high,
    xhigh,

    pub fn label(self: Tier) []const u8 {
        return @tagName(self);
    }
};

pub const SignalEnvelope = struct {
    signal_version: u8 = signal_version,
    harness: []const u8 = harness_name,
    harness_version: []const u8 = harness_version,
    profile: []const u8,
    session_id: ?[]const u8 = null,
    turn_index: usize = 1,
    step_index: usize = 0,
    phase: Phase = .initial_plan,
    task_class: TaskClass = .general,
    complexity: Tier = .medium,
    reasoning_need: Tier = .medium,
    latency_sensitivity: []const u8 = "normal",
    context_fill_ratio: f64 = 0.0,
    tool_calls_in_turn: usize = 0,
    recent_tool_error: bool = false,
    allow_mid_turn_route_change: bool = true,
};

var router_supports_body_signaling = std.atomic.Value(bool).init(false);

pub fn setRouterSupportsBodySignaling(supported: bool) void {
    router_supports_body_signaling.store(supported, .seq_cst);
}

pub fn routerSupportsBodySignaling() bool {
    return router_supports_body_signaling.load(.seq_cst);
}

pub fn resolveMode() Mode {
    const raw = io_mod.getenv("CXN_SIGNALING") orelse return .auto;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(trimmed, "body") or
        std.ascii.eqlIgnoreCase(trimmed, "full") or
        std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true"))
    {
        return .body;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "headers")) return .headers;
    if (std.ascii.eqlIgnoreCase(trimmed, "off") or
        std.ascii.eqlIgnoreCase(trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "false"))
    {
        return .off;
    }
    return .auto;
}

pub fn shouldEmitHeaders(profile: profiles.Profile) bool {
    if (!profile.signaling.anyEnabled()) return false;
    return resolveMode() != .off;
}

pub fn shouldEmitBodyEnvelope(profile: profiles.Profile) bool {
    if (!profile.signaling.anyEnabled()) return false;
    return switch (resolveMode()) {
        .body => true,
        .auto => routerSupportsBodySignaling(),
        .headers, .off => false,
    };
}

/// Deterministic zero-latency workflow analyzer deriving phase, task class,
/// complexity, and reasoning need from real harness message and tool state.
pub fn analyze(
    request: stream_provider.RequestData,
    profile: profiles.Profile,
    session_id: ?[]const u8,
    context_window: u32,
) SignalEnvelope {
    var turn_index: usize = 0;
    var last_user_idx: ?usize = null;
    var total_bytes: usize = 0;

    for (request.instructions) |inst| {
        if (inst.content) |text| total_bytes += text.len;
    }
    for (request.messages, 0..) |msg, idx| {
        if (msg.content) |text| total_bytes += text.len;
        for (msg.tool_calls) |call| {
            total_bytes += call.name.len + call.arguments_json.len;
        }
        if (msg.role == .user) {
            turn_index += 1;
            last_user_idx = idx;
        }
    }
    if (turn_index == 0) turn_index = 1;

    const turn_start = if (last_user_idx) |idx| idx + 1 else 0;
    var step_index: usize = 0;
    var tool_calls_in_turn: usize = 0;
    var recent_tool_error = false;
    var saw_edit_tool = false;
    var saw_read_tool = false;
    var saw_shell_tool = false;
    var last_role: types.ChatRole = .user;

    for (request.messages[turn_start..]) |msg| {
        last_role = msg.role;
        switch (msg.role) {
            .assistant => {
                step_index += 1;
                tool_calls_in_turn += msg.tool_calls.len;
                for (msg.tool_calls) |call| {
                    if (isEditTool(call.name)) {
                        saw_edit_tool = true;
                    } else if (isReadTool(call.name)) {
                        saw_read_tool = true;
                    } else if (std.mem.eql(u8, call.name, "shell")) {
                        saw_shell_tool = true;
                    }
                }
            },
            .tool => {
                if (msg.tool_result_status == .failure or looksLikeToolError(msg.content)) {
                    recent_tool_error = true;
                } else {
                    recent_tool_error = false;
                }
            },
            .user, .system => {},
        }
    }

    const phase: Phase = if (step_index == 0)
        .initial_plan
    else if (recent_tool_error)
        .recovery
    else if (last_role == .tool and tool_calls_in_turn > 0)
        .tool_continuation
    else
        .final_synthesis;

    const user_text = if (last_user_idx) |idx| (request.messages[idx].content orelse "") else "";
    const task_class = classifyTask(user_text, saw_edit_tool, saw_read_tool, saw_shell_tool, recent_tool_error);

    var complexity = deriveComplexity(phase, task_class, recent_tool_error, tool_calls_in_turn);
    var reasoning_need = complexity;

    switch (profile.complexity_bias) {
        .economy => {
            if (!recent_tool_error and (phase == .tool_continuation or phase == .final_synthesis)) {
                complexity = lowerTier(complexity);
                reasoning_need = lowerTier(reasoning_need);
            }
        },
        .deep => {
            if (complexity == .low or complexity == .medium) complexity = .high;
            if (reasoning_need == .low or reasoning_need == .medium) reasoning_need = .high;
        },
        .balanced => {},
    }

    if (profile.effort_policy.fixedEffortLabel()) |fixed| {
        reasoning_need = parseTier(fixed) orelse reasoning_need;
    } else if (request.provider_options.reasoning) |explicit_effort| {
        if (parseTier(explicit_effort.label())) |tier| {
            reasoning_need = tier;
        }
    }

    const effective_window: f64 = @floatFromInt(if (context_window > 0) context_window else 200_000);
    // Approximate 4 bytes per token, clamped to [0.0, 1.0].
    const estimated_tokens: f64 = @as(f64, @floatFromInt(total_bytes)) / 4.0;
    const raw_ratio = estimated_tokens / effective_window;
    const context_fill_ratio = @min(1.0, @max(0.0, @round(raw_ratio * 100.0) / 100.0));

    const latency_sensitivity: []const u8 = if (profile.complexity_bias == .economy)
        "high"
    else if (phase == .tool_continuation and !recent_tool_error)
        "normal"
    else if (profile.complexity_bias == .deep)
        "low"
    else
        "normal";

    return .{
        .profile = profile.name,
        .session_id = session_id,
        .turn_index = turn_index,
        .step_index = step_index,
        .phase = phase,
        .task_class = task_class,
        .complexity = complexity,
        .reasoning_need = reasoning_need,
        .latency_sensitivity = latency_sensitivity,
        .context_fill_ratio = context_fill_ratio,
        .tool_calls_in_turn = tool_calls_in_turn,
        .recent_tool_error = recent_tool_error,
        .allow_mid_turn_route_change = profile.allow_mid_turn_route_change,
    };
}

pub fn writeEnvelopeField(
    writer: *std.Io.Writer,
    envelope: SignalEnvelope,
    flags: profiles.SignalingFlags,
) !void {
    try writer.writeAll(",\"constellation\":{\"signal_version\":");
    try writer.print("{d}", .{envelope.signal_version});
    try writer.writeAll(",\"harness\":");
    try std.json.Stringify.value(envelope.harness, .{}, writer);
    try writer.writeAll(",\"harness_version\":");
    try std.json.Stringify.value(envelope.harness_version, .{}, writer);
    try writer.writeAll(",\"profile\":");
    try std.json.Stringify.value(envelope.profile, .{}, writer);
    if (envelope.session_id) |sid| if (sid.len > 0) {
        try writer.writeAll(",\"session_id\":");
        try std.json.Stringify.value(sid, .{}, writer);
    };
    try writer.print(",\"turn_index\":{d},\"step_index\":{d}", .{ envelope.turn_index, envelope.step_index });
    if (flags.step_phase) {
        try writer.writeAll(",\"phase\":");
        try std.json.Stringify.value(envelope.phase.label(), .{}, writer);
    }
    try writer.print(",\"allow_mid_turn_route_change\":{s}", .{
        if (envelope.allow_mid_turn_route_change) "true" else "false",
    });

    if (flags.workflow_hint or flags.reasoning_advisory or flags.context_telemetry) {
        try writer.writeAll(",\"advisory\":{");
        var first = true;
        if (flags.workflow_hint) {
            try writer.writeAll("\"task_class\":");
            try std.json.Stringify.value(envelope.task_class.label(), .{}, writer);
            try writer.writeAll(",\"complexity\":");
            try std.json.Stringify.value(envelope.complexity.label(), .{}, writer);
            first = false;
        }
        if (flags.reasoning_advisory) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"reasoning_need\":");
            try std.json.Stringify.value(envelope.reasoning_need.label(), .{}, writer);
            try writer.writeAll(",\"latency_sensitivity\":");
            try std.json.Stringify.value(envelope.latency_sensitivity, .{}, writer);
            first = false;
        }
        if (flags.context_telemetry) {
            if (!first) try writer.writeByte(',');
            try writer.print("\"context_fill_ratio\":{d:.2},\"tool_calls_in_turn\":{d},\"recent_tool_error\":{s}", .{
                envelope.context_fill_ratio,
                envelope.tool_calls_in_turn,
                if (envelope.recent_tool_error) "true" else "false",
            });
        }
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

fn isEditTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "edit_file") or
        std.mem.eql(u8, name, "write_file") or
        std.mem.eql(u8, name, "apply_patch") or
        std.mem.eql(u8, name, "delete_file");
}

fn isReadTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "read_file") or
        std.mem.eql(u8, name, "grep_files") or
        std.mem.eql(u8, name, "list_files") or
        std.mem.eql(u8, name, "find_files");
}

fn looksLikeToolError(content: ?[]const u8) bool {
    const text = content orelse return false;
    return std.mem.startsWith(u8, text, "Tool error:") or
        std.mem.startsWith(u8, text, "Error:") or
        std.mem.find(u8, text, "exit_code\":1") != null;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    if (haystack.len == 0) return false;
    for (needles) |needle| {
        if (std.ascii.findIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

fn classifyTask(
    user_text: []const u8,
    saw_edit_tool: bool,
    saw_read_tool: bool,
    saw_shell_tool: bool,
    recent_tool_error: bool,
) TaskClass {
    if (recent_tool_error) return .debugging;
    if (saw_edit_tool) return .mechanical_edit;
    if (containsAnyIgnoreCase(user_text, &.{ "architect", "design", "security", "audit", "rfc", "prd", "spec" })) {
        return .architecture;
    }
    if (containsAnyIgnoreCase(user_text, &.{ "debug", "bug", "crash", "panic", "broken", "fix ", "error", "fail" })) {
        return .debugging;
    }
    if (containsAnyIgnoreCase(user_text, &.{ "test", "verify", "lint", "build", "check" })) {
        return .verification;
    }
    if (saw_read_tool and !saw_shell_tool) return .exploration;
    if (containsAnyIgnoreCase(user_text, &.{ "rename", "format", "replace", "typo", "update " })) {
        return .mechanical_edit;
    }
    return .general;
}

fn deriveComplexity(phase: Phase, task_class: TaskClass, recent_tool_error: bool, tool_calls_in_turn: usize) Tier {
    if (recent_tool_error or phase == .recovery) return .high;
    if (task_class == .architecture) return .high;
    if (task_class == .debugging and phase == .initial_plan) return .high;
    if (phase == .tool_continuation and (task_class == .mechanical_edit or task_class == .exploration)) {
        return if (tool_calls_in_turn >= 3) .medium else .low;
    }
    if (phase == .final_synthesis and task_class != .architecture) return .low;
    return .medium;
}

fn lowerTier(tier: Tier) Tier {
    return switch (tier) {
        .xhigh => .high,
        .high => .medium,
        .medium => .low,
        .low => .low,
    };
}

fn parseTier(raw: []const u8) ?Tier {
    if (std.ascii.eqlIgnoreCase(raw, "low") or std.ascii.eqlIgnoreCase(raw, "minimal")) return .low;
    if (std.ascii.eqlIgnoreCase(raw, "medium")) return .medium;
    if (std.ascii.eqlIgnoreCase(raw, "high")) return .high;
    if (std.ascii.eqlIgnoreCase(raw, "xhigh") or std.ascii.eqlIgnoreCase(raw, "max")) return .xhigh;
    return null;
}

test "deterministic analyzer differentiates initial plan, mechanical continuation, and error recovery" {
    const balanced = profiles.findBuiltin("balanced").?;
    const economy = profiles.findBuiltin("economy").?;
    const deep = profiles.findBuiltin("deep").?;

    const initial_msgs = [_]types.ChatMessage{
        .{ .role = .user, .content = "Design the security architecture for the new router." },
    };
    const initial = analyze(.{
        .model = "constellation/auto",
        .messages = &initial_msgs,
        .tool_choice = .auto,
        .provider_options = .{},
    }, balanced, "sess-1", 200_000);
    try std.testing.expectEqual(Phase.initial_plan, initial.phase);
    try std.testing.expectEqual(TaskClass.architecture, initial.task_class);
    try std.testing.expectEqual(Tier.high, initial.complexity);
    try std.testing.expectEqual(Tier.high, initial.reasoning_need);

    const edit_calls = [_]types.ToolCall{.{ .id = "c1", .name = "edit_file", .arguments_json = "{}" }};
    const cont_msgs = [_]types.ChatMessage{
        .{ .role = .user, .content = "Rename helper and update call sites." },
        .{ .role = .assistant, .tool_calls = &edit_calls },
        .{ .role = .tool, .tool_call_id = "c1", .tool_name = "edit_file", .content = "ok" },
    };
    const cont_econ = analyze(.{
        .model = "constellation/efficient",
        .messages = &cont_msgs,
        .tool_choice = .auto,
        .provider_options = .{},
    }, economy, "sess-1", 200_000);
    try std.testing.expectEqual(Phase.tool_continuation, cont_econ.phase);
    try std.testing.expectEqual(TaskClass.mechanical_edit, cont_econ.task_class);
    try std.testing.expectEqual(Tier.low, cont_econ.reasoning_need);
    try std.testing.expectEqual(@as(usize, 1), cont_econ.step_index);

    const err_msgs = [_]types.ChatMessage{
        .{ .role = .user, .content = "Run tests" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "c2", .name = "shell", .arguments_json = "{}" }} },
        .{ .role = .tool, .tool_call_id = "c2", .tool_name = "shell", .content = "Tool error: exit 1", .tool_result_status = .failure },
    };
    const recovery = analyze(.{
        .model = "constellation/auto",
        .messages = &err_msgs,
        .tool_choice = .auto,
        .provider_options = .{},
    }, deep, "sess-1", 200_000);
    try std.testing.expectEqual(Phase.recovery, recovery.phase);
    try std.testing.expect(recovery.recent_tool_error);
    try std.testing.expectEqual(Tier.high, recovery.reasoning_need);
}

test "writeEnvelopeField serializes PRD-008 signal_version 1 JSON envelope" {
    const alloc = std.testing.allocator;
    const balanced = profiles.findBuiltin("balanced").?;
    const msgs = [_]types.ChatMessage{.{ .role = .user, .content = "Fix the failing test." }};
    const env = analyze(.{
        .model = "constellation/auto",
        .messages = &msgs,
        .tool_choice = .auto,
        .provider_options = .{},
    }, balanced, "sess_42", 200_000);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"model\":\"constellation/auto\"");
    try writeEnvelopeField(&out.writer, env, balanced.signaling);
    try out.writer.writeByte('}');

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    const cxn = parsed.value.object.get("constellation").?.object;
    try std.testing.expectEqual(@as(i64, 1), cxn.get("signal_version").?.integer);
    try std.testing.expectEqualStrings("cxn", cxn.get("harness").?.string);
    try std.testing.expectEqualStrings("balanced", cxn.get("profile").?.string);
    try std.testing.expectEqualStrings("sess_42", cxn.get("session_id").?.string);
    try std.testing.expectEqualStrings("initial_plan", cxn.get("phase").?.string);
    const advisory = cxn.get("advisory").?.object;
    try std.testing.expectEqualStrings("debugging", advisory.get("task_class").?.string);
    try std.testing.expectEqualStrings("high", advisory.get("reasoning_need").?.string);
}
