const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const default_base_url = "https://infer.cxn.sh/api/v1";
pub const default_model = "constellation/auto";
pub const default_review_model = "constellation/auto";
pub const client_header_name = "x-constellation-client";
pub const client_header_value = "cxn";
pub const missing_credential_message =
    "cxn needs access to Constellation Router. Set CXN_API_KEY (or CONSTELLATION_API_KEY), configure ~/.fx/constellation.json, or run with FX_AUTH_MODE=host-managed.";

var cxn_mode_flag = std.atomic.Value(bool).init(false);

pub fn setCxnMode(enabled: bool) void {
    cxn_mode_flag.store(enabled, .seq_cst);
}

pub fn isCxnMode() bool {
    if (cxn_mode_flag.load(.seq_cst)) return true;
    return envRequestsCxnMode(
        io_mod.getenv("CXN_MODE"),
        io_mod.getenv("CXN_EXCLUSIVE"),
    );
}

pub fn envRequestsCxnMode(cxn_mode: ?[]const u8, cxn_exclusive: ?[]const u8) bool {
    return isTruthyEnv(cxn_mode) or isTruthyEnv(cxn_exclusive);
}

fn isTruthyEnv(raw: ?[]const u8) bool {
    const value = raw orelse return false;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes");
}

pub fn isCxnInvocation(argv0: []const u8) bool {
    if (argv0.len == 0) return false;
    var end = argv0.len;
    while (end > 0 and (argv0[end - 1] == '/' or argv0[end - 1] == '\\')) {
        end -= 1;
    }
    if (end == 0) return false;
    const trimmed = argv0[0..end];
    var start = trimmed.len;
    while (start > 0 and trimmed[start - 1] != '/' and trimmed[start - 1] != '\\') {
        start -= 1;
    }
    const base = trimmed[start..];
    return std.ascii.eqlIgnoreCase(base, "cxn") or std.ascii.eqlIgnoreCase(base, "cxn.exe");
}

pub fn normalizeBaseUrl(raw: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

pub fn isValidBaseUrl(raw: []const u8) bool {
    const base = normalizeBaseUrl(raw);
    if (!std.mem.startsWith(u8, base, "http://") and !std.mem.startsWith(u8, base, "https://")) {
        return false;
    }
    const uri = std.Uri.parse(base) catch return false;
    const host = uri.host orelse return false;
    return switch (host) {
        .raw, .percent_encoded => |value| value.len > 0,
    };
}

pub fn resolveBaseUrl() []const u8 {
    inline for (.{ "CXN_ROUTER_URL", "CONSTELLATION_ROUTER_URL", "FX_CONSTELLATION_BASE_URL" }) |key| {
        if (nonEmptyEnv(key)) |value| {
            const normalized = normalizeBaseUrl(value);
            if (normalized.len > 0) return normalized;
        }
    }
    return default_base_url;
}

pub fn endpointUrl(alloc: Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    const normalized = normalizeBaseUrl(base_url);
    if (!isValidBaseUrl(normalized)) return error.InvalidConstellationBaseUrl;
    if (suffix.len == 0) return alloc.dupe(u8, normalized);
    if (suffix[0] == '/') {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ normalized, suffix });
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ normalized, suffix });
}

pub const ApiKeySource = enum(u8) {
    env = 1,
    constellation_json = 2,

    pub fn label(self: ApiKeySource) []const u8 {
        return switch (self) {
            .env => "CXN_API_KEY",
            .constellation_json => "~/.fx/constellation.json",
        };
    }
};

var last_api_key_source = std.atomic.Value(u8).init(0);

fn recordApiKeySource(source: ApiKeySource) void {
    last_api_key_source.store(@intFromEnum(source), .seq_cst);
}

pub fn activeApiKeySourceLabel() []const u8 {
    if (resolvePrimaryEnvApiKey() != null) return ApiKeySource.env.label();
    return switch (last_api_key_source.load(.seq_cst)) {
        1 => ApiKeySource.env.label(),
        2 => ApiKeySource.constellation_json.label(),
        else => ApiKeySource.env.label(),
    };
}

fn resolvePrimaryEnvApiKey() ?[]const u8 {
    inline for (.{
        "CXN_API_KEY",
        "CONSTELLATION_API_KEY",
        "FX_CONSTELLATION_API_KEY",
    }) |key| {
        if (nonEmptyEnv(key)) |value| return value;
    }
    return null;
}

pub fn resolveApiKey() ?[]const u8 {
    if (resolvePrimaryEnvApiKey()) |value| return value;
    return nonEmptyEnv("CONSTELLATION_ROUTER_API_KEY");
}

const max_local_config_bytes: usize = 256 * 1024;

/// Resolves the Constellation Router API key with precedence:
/// 1. Explicit `cxn` environment variables (`CXN_API_KEY`, `CONSTELLATION_API_KEY`, `FX_CONSTELLATION_API_KEY`)
/// 2. `$HOME/.fx/constellation.json` (`api_key` / `apiKey`)
/// 3. `CONSTELLATION_ROUTER_API_KEY` environment variable fallback
/// Caller owns the returned bytes and must zero/free them with `secret.zeroAndFree`.
pub fn resolveApiKeyAlloc(alloc: Allocator) Allocator.Error!?[]u8 {
    return resolveApiKeyFromHomeAlloc(alloc, io_mod.getenv("HOME"));
}

pub fn hasConfiguredApiKey(alloc: Allocator) bool {
    const key = (resolveApiKeyAlloc(alloc) catch return false) orelse return false;
    secret.zeroAndFree(alloc, key);
    return true;
}

pub fn hasConfiguredApiKeyProcess() bool {
    if (resolvePrimaryEnvApiKey() != null) return true;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return hasConfiguredApiKey(arena.allocator());
}

fn resolveApiKeyFromHomeAlloc(
    alloc: Allocator,
    home: ?[]const u8,
) Allocator.Error!?[]u8 {
    if (resolvePrimaryEnvApiKey()) |env_key| {
        recordApiKeySource(.env);
        return try alloc.dupe(u8, env_key);
    }
    if (home) |h| {
        if (h.len > 0) {
            const fx_path = try std.fs.path.join(alloc, &.{ h, ".fx", "constellation.json" });
            defer alloc.free(fx_path);
            if (try loadKeyFromConstellationJson(alloc, fx_path)) |key| {
                recordApiKeySource(.constellation_json);
                return key;
            }
        }
    }
    if (nonEmptyEnv("CONSTELLATION_ROUTER_API_KEY")) |fallback_key| {
        recordApiKeySource(.env);
        return try alloc.dupe(u8, fallback_key);
    }
    return null;
}

fn readConfigFileAlloc(alloc: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    return io_mod.readFileToEnd(alloc, &file, max_local_config_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn loadKeyFromConstellationJson(alloc: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    const bytes = (try readConfigFileAlloc(alloc, path)) orelse return null;
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const raw = extractApiKeyField(parsed.value.object) orelse return null;
    return try alloc.dupe(u8, raw);
}

fn extractApiKeyField(obj: std.json.ObjectMap) ?[]const u8 {
    inline for (.{ "api_key", "apiKey" }) |field| {
        if (obj.get(field)) |val| {
            if (val == .string) {
                const trimmed = std.mem.trim(u8, val.string, " \t\r\n");
                if (trimmed.len > 0) return trimmed;
            }
        }
    }
    return null;
}

/// Returns true when a host probe (such as T3 Code's `provider-fx` multi-backend
/// probe) explicitly asks for a non-Constellation upstream backend (`codex` or
/// `grok`) so Constellation models are not duplicated across legacy slots.
pub fn isNonConstellationBackendProbe() bool {
    const provider = nonEmptyEnv("FX_PROVIDER") orelse return false;
    return std.ascii.eqlIgnoreCase(provider, "codex") or
        std.ascii.eqlIgnoreCase(provider, "grok");
}

/// Normalizes a requested model identifier, stripping T3 Code `provider-fx`
/// backend slug prefixes (`gateway:<id>`, `constellation:<id>`) while preserving
/// Constellation slash-namespaced virtual models (`constellation/auto`).
pub fn normalizeRequestedModel(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    inline for (.{ "gateway:", "constellation:", "cxn:" }) |prefix| {
        if (trimmed.len > prefix.len and std.ascii.startsWithIgnoreCase(trimmed, prefix)) {
            return trimmed[prefix.len..];
        }
    }
    return trimmed;
}

pub fn resolveModelOverride() ?[]const u8 {
    if (nonEmptyEnv("CXN_MODEL")) |value| {
        const normalized = normalizeRequestedModel(value);
        if (normalized.len > 0) return normalized;
    }
    if (nonEmptyEnv("FX_MODEL")) |value| {
        // T3 Code's provider-fx probe sets FX_MODEL=default when inspecting status.
        if (std.ascii.eqlIgnoreCase(value, "default")) return null;
        const normalized = normalizeRequestedModel(value);
        if (normalized.len > 0) return normalized;
    }
    return null;
}

pub fn resolveDefaultModel() []const u8 {
    return resolveModelOverride() orelse default_model;
}

pub fn resolveReviewModel(fallback: []const u8) []const u8 {
    if (nonEmptyEnv("CXN_REVIEW_MODEL")) |value| return value;
    if (fallback.len > 0) return fallback;
    return default_review_model;
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const raw = io_mod.getenv(name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

/// Router decision headers and emitted harness signal metadata captured from
/// the most recent Constellation turn. Call `deinit` on owned values.
pub const RouteTelemetry = struct {
    route_model: ?[]u8 = null,
    route_path: ?[]u8 = null,
    route_label: ?[]u8 = null,
    route_effort: ?[]u8 = null,
    route_classify: ?[]u8 = null,
    media_dropped: ?[]u8 = null,
    media_translated: ?[]u8 = null,
    seat_pressure: ?[]u8 = null,
    context_window: ?[]u8 = null,
    signal_accepted: ?[]u8 = null,
    profile: ?[]u8 = null,
    phase: ?[]u8 = null,
    task_class: ?[]u8 = null,
    complexity: ?[]u8 = null,
    reasoning_need: ?[]u8 = null,

    pub fn hasAny(self: RouteTelemetry) bool {
        return self.route_model != null or
            self.route_path != null or
            self.route_label != null or
            self.route_effort != null or
            self.route_classify != null or
            self.media_dropped != null or
            self.media_translated != null or
            self.seat_pressure != null or
            self.context_window != null or
            self.signal_accepted != null or
            self.profile != null or
            self.phase != null or
            self.task_class != null or
            self.complexity != null or
            self.reasoning_need != null;
    }

    pub fn clone(self: RouteTelemetry, alloc: Allocator) !RouteTelemetry {
        var copy: RouteTelemetry = .{};
        errdefer copy.deinit(alloc);
        if (self.route_model) |v| copy.route_model = try alloc.dupe(u8, v);
        if (self.route_path) |v| copy.route_path = try alloc.dupe(u8, v);
        if (self.route_label) |v| copy.route_label = try alloc.dupe(u8, v);
        if (self.route_effort) |v| copy.route_effort = try alloc.dupe(u8, v);
        if (self.route_classify) |v| copy.route_classify = try alloc.dupe(u8, v);
        if (self.media_dropped) |v| copy.media_dropped = try alloc.dupe(u8, v);
        if (self.media_translated) |v| copy.media_translated = try alloc.dupe(u8, v);
        if (self.seat_pressure) |v| copy.seat_pressure = try alloc.dupe(u8, v);
        if (self.context_window) |v| copy.context_window = try alloc.dupe(u8, v);
        if (self.signal_accepted) |v| copy.signal_accepted = try alloc.dupe(u8, v);
        if (self.profile) |v| copy.profile = try alloc.dupe(u8, v);
        if (self.phase) |v| copy.phase = try alloc.dupe(u8, v);
        if (self.task_class) |v| copy.task_class = try alloc.dupe(u8, v);
        if (self.complexity) |v| copy.complexity = try alloc.dupe(u8, v);
        if (self.reasoning_need) |v| copy.reasoning_need = try alloc.dupe(u8, v);
        return copy;
    }

    pub fn deinit(self: *RouteTelemetry, alloc: Allocator) void {
        if (self.route_model) |v| alloc.free(v);
        if (self.route_path) |v| alloc.free(v);
        if (self.route_label) |v| alloc.free(v);
        if (self.route_effort) |v| alloc.free(v);
        if (self.route_classify) |v| alloc.free(v);
        if (self.media_dropped) |v| alloc.free(v);
        if (self.media_translated) |v| alloc.free(v);
        if (self.seat_pressure) |v| alloc.free(v);
        if (self.context_window) |v| alloc.free(v);
        if (self.signal_accepted) |v| alloc.free(v);
        if (self.profile) |v| alloc.free(v);
        if (self.phase) |v| alloc.free(v);
        if (self.task_class) |v| alloc.free(v);
        if (self.complexity) |v| alloc.free(v);
        if (self.reasoning_need) |v| alloc.free(v);
        self.* = .{};
    }

    pub fn recordField(slot: *?[]u8, alloc: Allocator, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 512) return;
        const duped = try alloc.dupe(u8, trimmed);
        if (slot.*) |old| alloc.free(old);
        slot.* = duped;
    }

    pub fn recordHeader(self: *RouteTelemetry, alloc: Allocator, name: []const u8, value: []const u8) !void {
        const target: ?*?[]u8 = if (std.ascii.eqlIgnoreCase(name, "x-constellation-route-model"))
            &self.route_model
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-route-path"))
            &self.route_path
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-route-label"))
            &self.route_label
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-route-effort"))
            &self.route_effort
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-route-classify"))
            &self.route_classify
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-media-dropped"))
            &self.media_dropped
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-media-translated"))
            &self.media_translated
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-seat-pressure"))
            &self.seat_pressure
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-context-window"))
            &self.context_window
        else if (std.ascii.eqlIgnoreCase(name, "x-constellation-signal-accepted"))
            &self.signal_accepted
        else
            null;
        const slot = target orelse return;
        try recordField(slot, alloc, value);
    }
};

const StoredRouteTelemetry = struct {
    session_id: ?[]u8 = null,
    telemetry: RouteTelemetry = .{},

    fn deinit(self: *StoredRouteTelemetry, alloc: Allocator) void {
        if (self.session_id) |id| alloc.free(id);
        self.telemetry.deinit(alloc);
        self.* = .{};
    }
};

var route_telemetry_mutex: std.Io.Mutex = .init;
var last_route_telemetry: StoredRouteTelemetry = .{};

pub fn storeRouteTelemetry(session_id: ?[]const u8, telemetry: RouteTelemetry) void {
    if (!telemetry.hasAny()) return;
    const alloc = std.heap.page_allocator;
    var cloned = telemetry.clone(alloc) catch return;
    const id_copy: ?[]u8 = if (session_id) |id|
        if (id.len > 0) (alloc.dupe(u8, id) catch {
            cloned.deinit(alloc);
            return;
        }) else null
    else
        null;

    route_telemetry_mutex.lockUncancelable(io_mod.getIo());
    defer route_telemetry_mutex.unlock(io_mod.getIo());
    last_route_telemetry.deinit(alloc);
    last_route_telemetry = .{
        .session_id = id_copy,
        .telemetry = cloned,
    };
}

pub fn takeRouteTelemetry(alloc: Allocator, session_id: ?[]const u8) !?RouteTelemetry {
    route_telemetry_mutex.lockUncancelable(io_mod.getIo());
    defer route_telemetry_mutex.unlock(io_mod.getIo());
    if (!last_route_telemetry.telemetry.hasAny()) return null;
    if (session_id) |requested| {
        if (last_route_telemetry.session_id) |stored| {
            if (!std.mem.eql(u8, stored, requested)) return null;
        }
    }
    const result = try last_route_telemetry.telemetry.clone(alloc);
    last_route_telemetry.deinit(std.heap.page_allocator);
    return result;
}

pub fn clearRouteTelemetry() void {
    route_telemetry_mutex.lockUncancelable(io_mod.getIo());
    defer route_telemetry_mutex.unlock(io_mod.getIo());
    last_route_telemetry.deinit(std.heap.page_allocator);
}

test "isCxnInvocation detects cxn binary paths across platforms" {
    try std.testing.expect(isCxnInvocation("cxn"));
    try std.testing.expect(isCxnInvocation("./zig-out/bin/cxn"));
    try std.testing.expect(isCxnInvocation("/usr/local/bin/cxn"));
    try std.testing.expect(isCxnInvocation("C:\\tools\\CXN.exe"));
    try std.testing.expect(!isCxnInvocation("fx"));
    try std.testing.expect(!isCxnInvocation("./zig-out/bin/fx"));
    try std.testing.expect(!isCxnInvocation("/usr/local/bin/cxn-router"));
    try std.testing.expect(!isCxnInvocation(""));
}

test "envRequestsCxnMode parses truthy flags" {
    try std.testing.expect(envRequestsCxnMode("1", null));
    try std.testing.expect(envRequestsCxnMode(null, "true"));
    try std.testing.expect(envRequestsCxnMode("YES", null));
    try std.testing.expect(!envRequestsCxnMode("0", "false"));
    try std.testing.expect(!envRequestsCxnMode(null, null));
}

test "base url normalization and endpoint joining" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings("https://infer.cxn.sh/api/v1", default_base_url);
    try std.testing.expect(isValidBaseUrl("https://infer.cxn.sh/api/v1/"));
    try std.testing.expect(isValidBaseUrl("http://127.0.0.1:8787/api/v1"));
    try std.testing.expect(!isValidBaseUrl("infer.cxn.sh/api/v1"));
    try std.testing.expect(!isValidBaseUrl(""));

    const responses = try endpointUrl(alloc, "https://infer.cxn.sh/api/v1///", "/responses");
    defer alloc.free(responses);
    try std.testing.expectEqualStrings("https://infer.cxn.sh/api/v1/responses", responses);

    const models = try endpointUrl(alloc, "http://127.0.0.1:9000/v1", "models");
    defer alloc.free(models);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/models", models);

    try std.testing.expectError(
        error.InvalidConstellationBaseUrl,
        endpointUrl(alloc, "not-a-url", "/responses"),
    );
}

test "route telemetry captures constellation headers and returns per-session snapshot" {
    const alloc = std.testing.allocator;
    defer clearRouteTelemetry();

    var telemetry: RouteTelemetry = .{};
    defer telemetry.deinit(alloc);
    try telemetry.recordHeader(alloc, "X-Constellation-Route-Model", "openai/gpt-5.4-mini");
    try telemetry.recordHeader(alloc, "X-Constellation-Route-Path", "constellation/auto");
    try telemetry.recordHeader(alloc, "X-Constellation-Route-Label", "efficient");
    try telemetry.recordHeader(alloc, "X-Constellation-Route-Effort", "medium");
    try telemetry.recordHeader(alloc, "X-Constellation-Route-Classify", "classifier-v1");
    try telemetry.recordHeader(alloc, "X-Unrelated-Header", "ignored");
    try std.testing.expect(telemetry.hasAny());

    storeRouteTelemetry("sess-1", telemetry);
    try std.testing.expect((try takeRouteTelemetry(alloc, "sess-other")) == null);

    var taken = (try takeRouteTelemetry(alloc, "sess-1")).?;
    defer taken.deinit(alloc);
    try std.testing.expectEqualStrings("openai/gpt-5.4-mini", taken.route_model.?);
    try std.testing.expectEqualStrings("constellation/auto", taken.route_path.?);
    try std.testing.expectEqualStrings("efficient", taken.route_label.?);
    try std.testing.expectEqualStrings("medium", taken.route_effort.?);
    try std.testing.expectEqualStrings("classifier-v1", taken.route_classify.?);
    try std.testing.expect((try takeRouteTelemetry(alloc, "sess-1")) == null);
}

test "resolveApiKeyFromHomeAlloc loads local constellation.json config" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    if (resolveApiKey() != null) return;
    try std.testing.expect((try resolveApiKeyFromHomeAlloc(alloc, home)) == null);

    const fx_dir = try std.fs.path.join(alloc, &.{ home, ".fx" });
    defer alloc.free(fx_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), fx_dir);
    const fx_path = try std.fs.path.join(alloc, &.{ fx_dir, "constellation.json" });
    defer alloc.free(fx_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), fx_path, .{ .truncate = true });
        defer f.close(io_mod.getIo());
        try f.writeStreamingAll(io_mod.getIo(), "{\"api_key\":\"cxn-local-secret-456\"}");
    }

    const from_fx = (try resolveApiKeyFromHomeAlloc(alloc, home)).?;
    defer secret.zeroAndFree(alloc, from_fx);
    try std.testing.expectEqualStrings("cxn-local-secret-456", from_fx);
    try std.testing.expectEqualStrings("~/.fx/constellation.json", activeApiKeySourceLabel());
}
