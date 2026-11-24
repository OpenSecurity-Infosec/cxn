const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const SignalingFlags = struct {
    workflow_hint: bool = true,
    step_phase: bool = true,
    context_telemetry: bool = true,
    reasoning_advisory: bool = true,

    pub fn anyEnabled(self: SignalingFlags) bool {
        return self.workflow_hint or self.step_phase or self.context_telemetry or self.reasoning_advisory;
    }
};

pub const EffortPolicy = enum {
    auto,
    advisory,
    fixed_low,
    fixed_medium,
    fixed_high,
    fixed_xhigh,

    pub fn fixedEffortLabel(self: EffortPolicy) ?[]const u8 {
        return switch (self) {
            .fixed_low => "low",
            .fixed_medium => "medium",
            .fixed_high => "high",
            .fixed_xhigh => "xhigh",
            .auto, .advisory => null,
        };
    }

    pub fn parse(raw: []const u8) ?EffortPolicy {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "advisory")) return .advisory;
        if (std.ascii.eqlIgnoreCase(raw, "fixed:low") or std.ascii.eqlIgnoreCase(raw, "low")) return .fixed_low;
        if (std.ascii.eqlIgnoreCase(raw, "fixed:medium") or std.ascii.eqlIgnoreCase(raw, "medium")) return .fixed_medium;
        if (std.ascii.eqlIgnoreCase(raw, "fixed:high") or std.ascii.eqlIgnoreCase(raw, "high")) return .fixed_high;
        if (std.ascii.eqlIgnoreCase(raw, "fixed:xhigh") or std.ascii.eqlIgnoreCase(raw, "xhigh")) return .fixed_xhigh;
        return null;
    }
};

pub const ComplexityBias = enum {
    balanced,
    economy,
    deep,
};

pub const Profile = struct {
    name: []const u8,
    description: []const u8,
    default_model: []const u8,
    signaling: SignalingFlags = .{},
    effort_policy: EffortPolicy = .advisory,
    complexity_bias: ComplexityBias = .balanced,
    allow_mid_turn_route_change: bool = true,
};

pub const builtin_profiles = [_]Profile{
    .{
        .name = "balanced",
        .description = "Adaptive routing with step-phase and complexity hints",
        .default_model = "constellation/auto",
        .signaling = .{
            .workflow_hint = true,
            .step_phase = true,
            .context_telemetry = true,
            .reasoning_advisory = true,
        },
        .effort_policy = .advisory,
        .complexity_bias = .balanced,
        .allow_mid_turn_route_change = true,
    },
    .{
        .name = "economy",
        .description = "Cost- and quota-efficient routing on mechanical edits and continuations",
        .default_model = "constellation/efficient",
        .signaling = .{
            .workflow_hint = true,
            .step_phase = true,
            .context_telemetry = true,
            .reasoning_advisory = true,
        },
        .effort_policy = .advisory,
        .complexity_bias = .economy,
        .allow_mid_turn_route_change = true,
    },
    .{
        .name = "deep",
        .description = "High-reasoning frontier routing for architecture, debugging, and security",
        .default_model = "constellation/smart",
        .signaling = .{
            .workflow_hint = true,
            .step_phase = true,
            .context_telemetry = true,
            .reasoning_advisory = true,
        },
        .effort_policy = .fixed_high,
        .complexity_bias = .deep,
        .allow_mid_turn_route_change = false,
    },
    .{
        .name = "pinned",
        .description = "Disable adaptive model overrides while preserving session affinity and telemetry",
        .default_model = "",
        .signaling = .{
            .workflow_hint = false,
            .step_phase = true,
            .context_telemetry = true,
            .reasoning_advisory = false,
        },
        .effort_policy = .auto,
        .complexity_bias = .balanced,
        .allow_mid_turn_route_change = false,
    },
};

pub const max_profile_name_bytes: usize = 64;

var active_profile_mutex: std.Io.Mutex = .init;
var active_profile_buf: [max_profile_name_bytes]u8 = [_]u8{0} ** max_profile_name_bytes;
var active_profile_len: usize = 0;

pub fn isValidProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_profile_name_bytes) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') {
            return false;
        }
    }
    return true;
}

pub fn findBuiltin(name: []const u8) ?Profile {
    const canonical = if (std.ascii.eqlIgnoreCase(name, "default")) "balanced" else name;
    for (builtin_profiles) |profile| {
        if (std.ascii.eqlIgnoreCase(profile.name, canonical)) return profile;
    }
    return null;
}

pub fn setActiveProfileName(name: []const u8) !void {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    const canonical = if (std.ascii.eqlIgnoreCase(trimmed, "default")) "balanced" else trimmed;
    if (!isValidProfileName(canonical)) return error.InvalidConstellationProfile;
    if (findBuiltin(canonical) == null) return error.UnknownConstellationProfile;

    active_profile_mutex.lockUncancelable(io_mod.getIo());
    defer active_profile_mutex.unlock(io_mod.getIo());
    @memcpy(active_profile_buf[0..canonical.len], canonical);
    active_profile_len = canonical.len;
}

pub fn clearActiveProfileOverride() void {
    active_profile_mutex.lockUncancelable(io_mod.getIo());
    defer active_profile_mutex.unlock(io_mod.getIo());
    active_profile_len = 0;
}

/// Controls whether ACP `configOptions` advertises the `profile` dropdown.
/// Hidden by default so generic ACP hosts (such as T3 Code's model picker)
/// keep their option pane focused on Reasoning Effort and Session Mode, while
/// `session/set_config_option("profile", ...)`, `--profile`, and `CXN_PROFILE`
/// remain supported. Set `CXN_ACP_EXPOSE_PROFILE=1` to advertise it in ACP.
pub fn shouldAdvertiseAcpOption() bool {
    const raw = io_mod.getenv("CXN_ACP_EXPOSE_PROFILE") orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes");
}

pub fn activeProfile() Profile {
    active_profile_mutex.lockUncancelable(io_mod.getIo());
    const explicit_len = active_profile_len;
    var local_buf: [max_profile_name_bytes]u8 = undefined;
    if (explicit_len > 0) {
        @memcpy(local_buf[0..explicit_len], active_profile_buf[0..explicit_len]);
    }
    active_profile_mutex.unlock(io_mod.getIo());

    if (explicit_len > 0) {
        if (findBuiltin(local_buf[0..explicit_len])) |profile| return profile;
    }
    if (io_mod.getenv("CXN_PROFILE")) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            if (findBuiltin(trimmed)) |profile| return profile;
        }
    }
    return builtin_profiles[0];
}

/// Loads an optional custom profile override from `~/.fx/constellation-profiles.json`
/// if present and valid. Fail-open to built-in profiles on missing or malformed files.
pub fn resolveProfileWithCustomFile(alloc: Allocator, name: []const u8, json_bytes: ?[]const u8) Profile {
    const base = findBuiltin(name) orelse builtin_profiles[0];
    const raw = json_bytes orelse return base;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return base;
    defer parsed.deinit();
    if (parsed.value != .object) return base;
    const profiles_obj = parsed.value.object.get("profiles") orelse parsed.value;
    if (profiles_obj != .object) return base;
    const entry = profiles_obj.object.get(name) orelse return base;
    if (entry != .object) return base;

    var resolved = base;
    if (entry.object.get("allow_mid_turn_route_change")) |v| {
        if (v == .bool) resolved.allow_mid_turn_route_change = v.bool;
    }
    if (entry.object.get("effort_policy")) |v| {
        if (v == .string) {
            if (EffortPolicy.parse(v.string)) |policy| resolved.effort_policy = policy;
        }
    }
    if (entry.object.get("signaling")) |sig_val| {
        if (sig_val == .object) {
            if (sig_val.object.get("workflow_hint")) |v| if (v == .bool) {
                resolved.signaling.workflow_hint = v.bool;
            };
            if (sig_val.object.get("step_phase")) |v| if (v == .bool) {
                resolved.signaling.step_phase = v.bool;
            };
            if (sig_val.object.get("context_telemetry")) |v| if (v == .bool) {
                resolved.signaling.context_telemetry = v.bool;
            };
            if (sig_val.object.get("reasoning_advisory")) |v| if (v == .bool) {
                resolved.signaling.reasoning_advisory = v.bool;
            };
        }
    }
    return resolved;
}

test "builtin profiles validate and resolve aliases cleanly" {
    defer clearActiveProfileOverride();
    try std.testing.expect(isValidProfileName("balanced"));
    try std.testing.expect(isValidProfileName("deep_review-1"));
    try std.testing.expect(!isValidProfileName(""));
    try std.testing.expect(!isValidProfileName("Bad Name"));

    try std.testing.expectEqualStrings("balanced", findBuiltin("default").?.name);
    try std.testing.expectEqualStrings("economy", findBuiltin("economy").?.name);
    try std.testing.expectEqualStrings("deep", findBuiltin("deep").?.name);
    try std.testing.expectEqualStrings("pinned", findBuiltin("pinned").?.name);
    try std.testing.expect(findBuiltin("nonexistent") == null);

    try setActiveProfileName("economy");
    try std.testing.expectEqualStrings("economy", activeProfile().name);
    try std.testing.expectEqualStrings("constellation/efficient", activeProfile().default_model);

    try std.testing.expectError(error.UnknownConstellationProfile, setActiveProfileName("unknown"));
}

test "custom profile JSON overrides signaling and effort policy safely" {
    const custom_json =
        \\{"profiles":{"balanced":{"effort_policy":"fixed:high","allow_mid_turn_route_change":false,"signaling":{"reasoning_advisory":false}}}}
    ;
    const merged = resolveProfileWithCustomFile(std.testing.allocator, "balanced", custom_json);
    try std.testing.expectEqual(EffortPolicy.fixed_high, merged.effort_policy);
    try std.testing.expect(!merged.allow_mid_turn_route_change);
    try std.testing.expect(!merged.signaling.reasoning_advisory);
    try std.testing.expect(merged.signaling.step_phase);
}
