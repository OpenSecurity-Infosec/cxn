const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("../gateway/client.zig");
const runtime = @import("runtime.zig");
const signaling = @import("signaling.zig");

const Allocator = std.mem.Allocator;

const max_catalog_models: usize = 512;
const max_model_id_bytes: usize = 1024;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const refresh_interval_ms: i64 = 5 * 60 * 1000;

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
    .provider_id = .gateway,
    .refresh_interval_ms = refresh_interval_ms,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const auth_token: ?[]const u8 = switch (input.access) {
        .host_managed => null,
        .authenticated => |authenticated| authenticated.credential,
        .public_only => runtime.resolveApiKey(),
    };
    if (input.access != .host_managed and auth_token == null) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });

    const request_url = runtime.endpointUrl(alloc, runtime.resolveBaseUrl(), "/models") catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);

    var operation = FetchOperation{
        .alloc = alloc,
        .url = request_url,
        .credential = auth_token,
    };
    var response = gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{
            .category = if (err == error.Cancelled) .cancellation else .transport,
            .retryable = err != error.Cancelled,
        } };
    };
    defer response.deinit(alloc);

    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    signaling.setRouterSupportsBodySignaling(response.supports_signaling_v1);

    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,
    supports_signaling_v1: bool = false,

    pub fn deinit(self: *FetchResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: ?[]const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();

        var auth_header: ?[]u8 = null;
        defer if (auth_header) |value| secret.zeroAndFree(self.alloc, value);
        var headers: std.http.Client.Request.Headers = .{
            .user_agent = .{ .override = gateway_client.user_agent },
            .accept_encoding = .omit,
        };
        if (self.credential) |credential| {
            auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{credential});
            headers.authorization = .{ .override = auth_header.? };
        }

        const extra_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = runtime.client_header_name, .value = runtime.client_header_value },
        };
        const uri = try std.Uri.parse(self.url);
        var http_request = try client.request(.GET, uri, .{
            .headers = headers,
            .extra_headers = &extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        });
        defer http_request.deinit();
        try http_request.sendBodiless();

        var head_buffer: [16 * 1024]u8 = undefined;
        var response = try http_request.receiveHead(&head_buffer);
        var supports_signaling_v1 = false;
        var header_it = response.head.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-constellation-capabilities") and
                std.ascii.indexOfIgnoreCase(header.value, "signaling-v1") != null)
            {
                supports_signaling_v1 = true;
            }
        }

        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(self.alloc, .limited(max_catalog_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ConstellationModelCatalogTooLarge,
            else => return err,
        };
        return .{
            .status = response.head.status,
            .body = body,
            .supports_signaling_v1 = supports_signaling_v1,
        };
    }
};

pub fn parseCatalog(
    alloc: Allocator,
    json_text: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConstellationModelCatalog;
    const data_value = parsed.value.object.get("data") orelse
        return error.InvalidConstellationModelCatalog;
    if (data_value != .array or data_value.array.items.len > max_catalog_models) {
        return error.InvalidConstellationModelCatalog;
    }

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);

    for (data_value.array.items) |value| {
        if (value != .object) return error.InvalidConstellationModelCatalog;
        const obj = value.object;
        const id_val = obj.get("id") orelse return error.InvalidConstellationModelCatalog;
        if (id_val != .string) return error.InvalidConstellationModelCatalog;
        try validateModelId(id_val.string);
        if (containsIdIgnoreCase(catalog.items, id_val.string)) continue;

        const id = try alloc.dupe(u8, id_val.string);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);

        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);
        try parseReasoningEfforts(alloc, &reasoning_efforts, obj);

        const is_workflow_alias = std.mem.startsWith(u8, id, "constellation/");
        const caps = parseCapabilities(obj, is_workflow_alias);
        if (reasoning_efforts.items.len == 0 and is_workflow_alias) {
            try appendDefaultWorkflowEfforts(alloc, &reasoning_efforts);
        }

        const context_window = optionalPositiveU32(obj, "context_window") orelse 0;
        const max_tokens = optionalPositiveU32(obj, "max_completion_tokens") orelse
            optionalPositiveU32(obj, "max_output_tokens") orelse 0;

        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = caps.tools,
            .has_reasoning = reasoning_efforts.items.len > 0,
            .reasoning_efforts = reasoning_efforts,
            .supports_fast_mode = false,
            .has_vision = caps.vision,
            .has_file_input = caps.vision,
            .has_implicit_caching = true,
            .context_window = context_window,
            .max_tokens = max_tokens,
        });
    }
    return catalog;
}

const ParsedCapabilities = struct {
    tools: bool,
    vision: bool,
};

fn parseCapabilities(obj: std.json.ObjectMap, is_workflow_alias: bool) ParsedCapabilities {
    if (obj.get("capabilities")) |caps_val| {
        if (caps_val == .array) {
            return parseCapabilityArray(caps_val.array.items, is_workflow_alias);
        }
    }
    if (obj.get("constellation")) |cxn_val| {
        if (cxn_val == .object) {
            if (cxn_val.object.get("capabilities")) |caps_val| {
                if (caps_val == .array) {
                    return parseCapabilityArray(caps_val.array.items, is_workflow_alias);
                }
            }
        }
    }
    // Router models without explicit capability metadata default to tool-capable.
    return .{ .tools = true, .vision = is_workflow_alias };
}

fn parseCapabilityArray(items: []const std.json.Value, is_workflow_alias: bool) ParsedCapabilities {
    if (items.len == 0) return .{ .tools = true, .vision = is_workflow_alias };
    var tools = is_workflow_alias;
    var vision = false;
    for (items) |entry| {
        if (entry != .string) continue;
        if (std.ascii.eqlIgnoreCase(entry.string, "tools")) tools = true;
        if (std.ascii.eqlIgnoreCase(entry.string, "vision")) vision = true;
    }
    return .{ .tools = tools, .vision = vision };
}

fn parseReasoningEfforts(
    alloc: Allocator,
    out: *std.ArrayList(types.ReasoningEffort),
    obj: std.json.ObjectMap,
) !void {
    const value = obj.get("reasoning_efforts") orelse return;
    if (value != .array) return;
    for (value.array.items) |entry| {
        if (out.items.len >= types.ReasoningEffort.max_options) break;
        const raw: ?[]const u8 = switch (entry) {
            .string => |s| s,
            .object => |m| blk: {
                if (m.get("value")) |v| {
                    if (v == .string) break :blk v.string;
                }
                if (m.get("effort")) |v| {
                    if (v == .string) break :blk v.string;
                }
                break :blk null;
            },
            else => null,
        };
        const label = raw orelse continue;
        const parsed = types.ReasoningEffort.parse(label) orelse continue;
        if (containsEffort(out.items, parsed)) continue;
        try out.append(alloc, parsed);
    }
}

fn appendDefaultWorkflowEfforts(alloc: Allocator, out: *std.ArrayList(types.ReasoningEffort)) !void {
    for ([_][]const u8{ "low", "medium", "high", "xhigh" }) |label| {
        if (types.ReasoningEffort.parse(label)) |effort| {
            try out.append(alloc, effort);
        }
    }
}

fn containsEffort(items: []const types.ReasoningEffort, candidate: types.ReasoningEffort) bool {
    for (items) |item| {
        if (item.eql(candidate)) return true;
    }
    return false;
}

fn containsIdIgnoreCase(items: []const model_catalog.ModelCatalogEntry, candidate: []const u8) bool {
    for (items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.id, candidate)) return true;
    }
    return false;
}

fn optionalPositiveU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = obj.get(key) orelse return null;
    if (value != .integer or value.integer <= 0) return null;
    return std.math.cast(u32, value.integer);
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidConstellationModelCatalog;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidConstellationModelCatalog;
    }
}

test "Constellation catalog parses public router models dynamically" {
    const alloc = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"constellation/auto","object":"model","owned_by":"constellation"},
        \\  {"id":"openai/gpt-5.4","object":"model","owned_by":"codex","capabilities":["chat","tools","vision"],"context_window":272000,"max_completion_tokens":32768,"reasoning_efforts":[{"value":"low"},{"value":"medium"},{"value":"high"}]},
        \\  {"id":"openai/gpt-5.4","object":"model","owned_by":"codex"},
        \\  {"id":"anthropic/claude-sonnet-4.6","object":"model","owned_by":"claude","capabilities":["chat","tools"],"reasoning_efforts":["medium","high"]}
        \\]}
    ;
    var catalog = try parseCatalog(alloc, json);
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 3), catalog.items.len);
    try std.testing.expectEqualStrings("constellation/auto", catalog.items[0].id);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(catalog.items[0].has_reasoning);
    try std.testing.expectEqual(@as(usize, 4), catalog.items[0].reasoning_efforts.items.len);

    try std.testing.expectEqualStrings("openai/gpt-5.4", catalog.items[1].id);
    try std.testing.expect(catalog.items[1].has_tool_use);
    try std.testing.expect(catalog.items[1].has_vision);
    try std.testing.expectEqual(@as(u32, 272000), catalog.items[1].context_window);
    try std.testing.expectEqual(@as(u32, 32768), catalog.items[1].max_tokens);
    try std.testing.expectEqual(@as(usize, 3), catalog.items[1].reasoning_efforts.items.len);

    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4.6", catalog.items[2].id);
    try std.testing.expect(catalog.items[2].has_tool_use);
    try std.testing.expect(!catalog.items[2].has_vision);
    try std.testing.expectEqual(@as(usize, 2), catalog.items[2].reasoning_efforts.items.len);
}
