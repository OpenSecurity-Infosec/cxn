const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const host_target = @import("../core/hosts/target.zig");
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
const background_fetch_timeout_ms: i64 = 15_000;
const refresh_interval_ms: i64 = 5 * 60 * 1000;
const cache_schema_version: i64 = 1;
const default_cache_filename = "constellation-models-cache.json";

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

const LiveFetchResult = struct {
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry),
    raw_body: []u8,
    supports_signaling_v1: bool,

    fn deinit(self: *LiveFetchResult, alloc: Allocator) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        secret.zeroAndFree(alloc, self.raw_body);
        self.* = undefined;
    }
};

const LiveFetchOutcome = union(enum) {
    loaded: LiveFetchResult,
    failed: model_catalog.Failure,
};

fn fetchLiveCatalog(
    alloc: Allocator,
    base_url: []const u8,
    auth_token: ?[]const u8,
    host_managed: bool,
    cancel_flag: *std.atomic.Value(bool),
    timeout_ms: i64,
) Allocator.Error!LiveFetchOutcome {
    if (!host_managed and auth_token == null) {
        return .{ .failed = .{ .category = .authentication, .http_status = .unauthorized } };
    }

    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });

    const request_url = runtime.endpointUrl(alloc, base_url, "/models") catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = .{ .category = .runtime } };
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
        return .{ .failed = .{
            .category = if (err == error.Cancelled) .cancellation else .transport,
            .retryable = err != error.Cancelled,
        } };
    };
    var response_owned = true;
    defer if (response_owned) response.deinit(alloc);

    if (response.status != .ok) {
        return .{ .failed = model_catalog.failureForHttpStatus(response.status) };
    }
    signaling.setRouterSupportsBodySignaling(response.supports_signaling_v1);

    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = .{ .category = .malformed_response, .http_status = .ok } };
    };
    const raw_body = response.body;
    const supports_signaling_v1 = response.supports_signaling_v1;
    response_owned = false;
    return .{ .loaded = .{
        .catalog = catalog,
        .raw_body = raw_body,
        .supports_signaling_v1 = supports_signaling_v1,
    } };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    var owned_fallback_key: ?[]u8 = null;
    defer if (owned_fallback_key) |k| secret.zeroAndFree(alloc, k);
    const auth_token: ?[]const u8 = switch (input.access) {
        .host_managed => null,
        .authenticated => |authenticated| authenticated.credential,
        .public_only => blk: {
            owned_fallback_key = try runtime.resolveApiKeyAlloc(alloc);
            break :blk owned_fallback_key;
        },
    };
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const base_url = runtime.resolveBaseUrl();

    const outcome = try fetchLiveCatalog(
        alloc,
        base_url,
        auth_token,
        input.access == .host_managed,
        cancel_flag,
        fetch_timeout_ms,
    );
    return switch (outcome) {
        .failed => |failure| .{ .failure = failure },
        .loaded => |loaded| blk: {
            saveDiskCache(alloc, null, base_url, loaded.supports_signaling_v1, loaded.raw_body);
            secret.zeroAndFree(alloc, loaded.raw_body);
            break :blk .{ .catalog = loaded.catalog };
        },
    };
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
    return parseCatalogValue(alloc, parsed.value);
}

fn parseCatalogValue(
    alloc: Allocator,
    root_value: std.json.Value,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    if (root_value != .object) return error.InvalidConstellationModelCatalog;
    const data_value = root_value.object.get("data") orelse
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

pub fn catalogFingerprint(entries: []const model_catalog.ModelCatalogEntry) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (entries) |entry| {
        hasher.update(entry.id);
        hasher.update("\x00");
        const flags = [_]u8{
            @intFromBool(entry.has_tool_use),
            @intFromBool(entry.has_vision),
            @intFromBool(entry.has_reasoning),
        };
        hasher.update(&flags);
        hasher.update(std.mem.asBytes(&entry.context_window));
        hasher.update(std.mem.asBytes(&entry.max_tokens));
        for (entry.reasoning_efforts.items) |effort| {
            hasher.update(effort.label());
            hasher.update("\x1f");
        }
        hasher.update("\x1e");
    }
    return hasher.final();
}

pub fn cloneCatalogEntries(
    alloc: Allocator,
    entries: []const model_catalog.ModelCatalogEntry,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var cloned: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &cloned);
    try cloned.ensureTotalCapacity(alloc, entries.len);
    for (entries) |entry| {
        const id = try alloc.dupe(u8, entry.id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, entry.model_type);
        errdefer alloc.free(model_type);
        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        try efforts.appendSlice(alloc, entry.reasoning_efforts.items);
        const price: ?[]u8 = if (entry.web_search_price) |p| try alloc.dupe(u8, p) else null;
        errdefer if (price) |p| alloc.free(p);
        try cloned.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = entry.released,
            .has_tool_use = entry.has_tool_use,
            .has_reasoning = entry.has_reasoning,
            .reasoning_efforts = efforts,
            .supports_fast_mode = entry.supports_fast_mode,
            .has_vision = entry.has_vision,
            .has_file_input = entry.has_file_input,
            .has_web_search = entry.has_web_search,
            .has_explicit_caching = entry.has_explicit_caching,
            .has_implicit_caching = entry.has_implicit_caching,
            .context_window = entry.context_window,
            .max_tokens = entry.max_tokens,
            .web_search_price = price,
        });
    }
    return cloned;
}

pub const CachedCatalog = struct {
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry),
    supports_signaling_v1: bool,
    updated_at_ms: i64,

    pub fn deinit(self: *CachedCatalog, alloc: Allocator) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.* = undefined;
    }
};

pub fn cacheFilePath(
    alloc: Allocator,
    home_override: ?[]const u8,
    base_url: []const u8,
) !?[]u8 {
    const home = home_override orelse io_mod.getenv("HOME") orelse return null;
    if (home.len == 0) return null;
    const normalized = runtime.normalizeBaseUrl(base_url);
    if (std.mem.eql(u8, normalized, runtime.default_base_url)) {
        return try std.fs.path.join(alloc, &.{ home, ".fx", default_cache_filename });
    }
    const url_hash = std.hash.Wyhash.hash(0, normalized);
    var filename_buf: [64]u8 = undefined;
    const filename = try std.fmt.bufPrint(
        &filename_buf,
        "constellation-models-cache-{x:0>16}.json",
        .{url_hash},
    );
    return try std.fs.path.join(alloc, &.{ home, ".fx", filename });
}

/// Loads the last synced Constellation Router catalog for `expected_base_url`
/// from `<home>/.fx/constellation-models-cache*.json` without touching the network.
/// Fail-open: returns null if missing, corrupt, or scoped to a different base URL.
pub fn loadDiskCache(
    alloc: Allocator,
    home_override: ?[]const u8,
    expected_base_url: []const u8,
) ?CachedCatalog {
    const path = (cacheFilePath(alloc, home_override, expected_base_url) catch return null) orelse return null;
    defer alloc.free(path);

    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    const bytes = io_mod.readFileToEnd(alloc, &file, max_catalog_bytes) catch return null;
    defer alloc.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const version_val = obj.get("version") orelse return null;
    if (version_val != .integer or version_val.integer != cache_schema_version) return null;

    const base_val = obj.get("base_url") orelse return null;
    if (base_val != .string) return null;
    if (!std.mem.eql(u8, runtime.normalizeBaseUrl(base_val.string), runtime.normalizeBaseUrl(expected_base_url))) {
        return null;
    }

    const catalog_val = obj.get("catalog") orelse return null;
    var catalog = parseCatalogValue(alloc, catalog_val) catch return null;
    if (catalog.items.len == 0) {
        model_catalog.freeModelCatalog(alloc, &catalog);
        return null;
    }

    const supports_signaling_v1 = if (obj.get("supports_signaling_v1")) |v|
        v == .bool and v.bool
    else
        false;
    const updated_at_ms = if (obj.get("updated_at_ms")) |v|
        if (v == .integer) v.integer else 0
    else
        0;

    signaling.setRouterSupportsBodySignaling(supports_signaling_v1);
    return .{
        .catalog = catalog,
        .supports_signaling_v1 = supports_signaling_v1,
        .updated_at_ms = updated_at_ms,
    };
}

/// Atomically persists a verified raw Constellation `/models` JSON payload to
/// `<home>/.fx/constellation-models-cache*.json`. Fail-open on any I/O error.
pub fn saveDiskCache(
    alloc: Allocator,
    home_override: ?[]const u8,
    base_url: []const u8,
    supports_signaling_v1: bool,
    raw_models_json: []const u8,
) void {
    saveDiskCacheFallible(alloc, home_override, base_url, supports_signaling_v1, raw_models_json) catch |err| {
        debug_trace.logf("catalog", "constellation disk cache save skipped err={s}", .{@errorName(err)});
    };
}

fn saveDiskCacheFallible(
    alloc: Allocator,
    home_override: ?[]const u8,
    base_url: []const u8,
    supports_signaling_v1: bool,
    raw_models_json: []const u8,
) !void {
    const trimmed_body = std.mem.trim(u8, raw_models_json, " \t\r\n");
    if (trimmed_body.len == 0 or trimmed_body[0] != '{') return;

    const path = (try cacheFilePath(alloc, home_override, base_url)) orelse return;
    defer alloc.free(path);
    const parent_dir = std.fs.path.dirname(path) orelse return;

    const io = io_mod.getIo();
    try std.Io.Dir.cwd().createDirPath(io, parent_dir);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"version\":{d},\"base_url\":", .{cache_schema_version});
    try std.json.Stringify.value(runtime.normalizeBaseUrl(base_url), .{}, &out.writer);
    try out.writer.print(",\"supports_signaling_v1\":{s},\"updated_at_ms\":{d},\"catalog\":", .{
        if (supports_signaling_v1) "true" else "false",
        io_mod.milliTimestamp(),
    });
    try out.writer.writeAll(trimmed_body);
    try out.writer.writeAll("}\n");

    var rand_bytes: [4]u8 = undefined;
    io.random(&rand_bytes);
    const rand_hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}.{s}", .{
        path,
        io_mod.nanoTimestamp(),
        rand_hex,
    });
    defer alloc.free(temp_path);

    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};

    {
        var file = try std.Io.Dir.createFileAbsolute(io, temp_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, out.writer.buffered());
    }
    try std.Io.Dir.renameAbsolute(temp_path, path, io);
    cleanup_temp = false;
}

pub const OnSyncCompleteFn = *const fn (
    ctx: ?*anyopaque,
    entries: []const model_catalog.ModelCatalogEntry,
    fingerprint: u64,
    supports_signaling_v1: bool,
) void;

pub const BackgroundSyncStartOptions = struct {
    base_url: []const u8,
    credential: ?[]const u8 = null,
    host_managed: bool = false,
    home_override: ?[]const u8 = null,
    on_complete_ctx: ?*anyopaque = null,
    on_complete_fn: ?OnSyncCompleteFn = null,
};

/// Post-init background catalog synchronizer. Spawns one cancelable worker
/// thread that fetches the live Constellation Router `/models` advertisement,
/// persists it to disk, stages the fresh catalog for adoption, and optionally
/// notifies an active session if the advertised model set changed.
pub const BackgroundSync = struct {
    mutex: std.Io.Mutex = .init,
    thread: if (host_target.is_wasm) void else ?std.Thread = if (host_target.is_wasm) {} else null,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    running: bool = false,
    completed: bool = false,
    succeeded: bool = false,
    pending_catalog: ?std.ArrayList(model_catalog.ModelCatalogEntry) = null,
    alloc: ?Allocator = null,

    const Job = struct {
        owner: *BackgroundSync,
        alloc: Allocator,
        base_url: []u8,
        credential: ?[]u8,
        host_managed: bool,
        home_override: ?[]u8,
        on_complete_ctx: ?*anyopaque,
        on_complete_fn: ?OnSyncCompleteFn,

        fn deinit(self: *Job) void {
            self.alloc.free(self.base_url);
            if (self.credential) |c| secret.zeroAndFree(self.alloc, c);
            if (self.home_override) |h| self.alloc.free(h);
            self.alloc.destroy(self);
        }
    };

    pub fn start(self: *BackgroundSync, alloc: Allocator, opts: BackgroundSyncStartOptions) void {
        if (comptime host_target.is_wasm) return;
        self.joinIfFinished();

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.running) {
            self.mutex.unlock(io);
            return;
        }
        self.alloc = alloc;
        self.cancel_flag.store(false, .seq_cst);
        self.running = true;
        self.completed = false;
        self.succeeded = false;
        self.mutex.unlock(io);

        const job = alloc.create(Job) catch {
            self.markStartFailed();
            return;
        };
        const base_url = alloc.dupe(u8, opts.base_url) catch {
            alloc.destroy(job);
            self.markStartFailed();
            return;
        };
        const credential: ?[]u8 = if (opts.credential) |c|
            if (c.len > 0) (alloc.dupe(u8, c) catch {
                alloc.free(base_url);
                alloc.destroy(job);
                self.markStartFailed();
                return;
            }) else null
        else
            null;
        const home_override: ?[]u8 = if (opts.home_override) |h|
            alloc.dupe(u8, h) catch {
                if (credential) |c| secret.zeroAndFree(alloc, c);
                alloc.free(base_url);
                alloc.destroy(job);
                self.markStartFailed();
                return;
            }
        else
            null;

        job.* = .{
            .owner = self,
            .alloc = alloc,
            .base_url = base_url,
            .credential = credential,
            .host_managed = opts.host_managed,
            .home_override = home_override,
            .on_complete_ctx = opts.on_complete_ctx,
            .on_complete_fn = opts.on_complete_fn,
        };

        self.thread = std.Thread.spawn(.{}, syncThreadMain, .{job}) catch {
            job.deinit();
            self.markStartFailed();
            return;
        };
    }

    pub fn isRunning(self: *BackgroundSync) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.running;
    }

    pub fn hasCompleted(self: *BackgroundSync) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.completed;
    }

    pub fn isCancelled(self: *const BackgroundSync) bool {
        return self.cancel_flag.load(.seq_cst);
    }

    pub fn takeCompletedCatalog(self: *BackgroundSync) ?std.ArrayList(model_catalog.ModelCatalogEntry) {
        self.joinIfFinished();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const pending = self.pending_catalog orelse return null;
        self.pending_catalog = null;
        return pending;
    }

    pub fn waitAndTakeCatalog(
        self: *BackgroundSync,
        timeout_ms: i64,
    ) ?std.ArrayList(model_catalog.ModelCatalogEntry) {
        if (self.takeCompletedCatalog()) |ready| return ready;
        const deadline_ms = io_mod.milliTimestamp() + @max(timeout_ms, 0);
        while (true) {
            const io = io_mod.getIo();
            self.mutex.lockUncancelable(io);
            if (self.pending_catalog) |pending| {
                self.pending_catalog = null;
                self.mutex.unlock(io);
                self.joinIfFinished();
                return pending;
            }
            const still_running = self.running;
            self.mutex.unlock(io);

            if (!still_running or self.cancel_flag.load(.seq_cst)) break;
            if (io_mod.milliTimestamp() >= deadline_ms) break;
            io_mod.sleep(std.time.ns_per_ms);
        }
        return self.takeCompletedCatalog();
    }

    pub fn deinit(self: *BackgroundSync) void {
        self.cancel_flag.store(true, .seq_cst);
        if (comptime !host_target.is_wasm) {
            if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            }
        }
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.pending_catalog) |*pending| {
            if (self.alloc) |alloc| {
                model_catalog.freeModelCatalog(alloc, pending);
            }
            self.pending_catalog = null;
        }
        self.running = false;
        self.mutex.unlock(io);
    }

    fn markStartFailed(self: *BackgroundSync) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.running = false;
        self.completed = true;
        self.succeeded = false;
        self.mutex.unlock(io);
    }

    fn joinIfFinished(self: *BackgroundSync) void {
        if (comptime host_target.is_wasm) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const finished = !self.running;
        self.mutex.unlock(io);
        if (finished) {
            if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            }
        }
    }

    fn syncThreadMain(job: *Job) void {
        defer job.deinit();
        const self = job.owner;
        const alloc = job.alloc;
        const io = io_mod.getIo();

        const outcome = fetchLiveCatalog(
            alloc,
            job.base_url,
            job.credential,
            job.host_managed,
            &self.cancel_flag,
            background_fetch_timeout_ms,
        ) catch {
            self.mutex.lockUncancelable(io);
            self.completed = true;
            self.succeeded = false;
            self.running = false;
            self.mutex.unlock(io);
            return;
        };

        switch (outcome) {
            .failed => |failure| {
                debug_trace.logf(
                    "catalog",
                    "constellation background catalog sync failed category={t}",
                    .{failure.category},
                );
                self.mutex.lockUncancelable(io);
                self.completed = true;
                self.succeeded = false;
                self.running = false;
                self.mutex.unlock(io);
            },
            .loaded => |loaded| {
                defer secret.zeroAndFree(alloc, loaded.raw_body);
                saveDiskCache(
                    alloc,
                    job.home_override,
                    job.base_url,
                    loaded.supports_signaling_v1,
                    loaded.raw_body,
                );
                const fp = catalogFingerprint(loaded.catalog.items);
                var notify_copy: ?std.ArrayList(model_catalog.ModelCatalogEntry) = null;
                if (job.on_complete_fn != null and !self.cancel_flag.load(.seq_cst)) {
                    notify_copy = cloneCatalogEntries(alloc, loaded.catalog.items) catch null;
                }
                defer if (notify_copy) |*copy| model_catalog.freeModelCatalog(alloc, copy);

                self.mutex.lockUncancelable(io);
                if (self.pending_catalog) |*old| {
                    model_catalog.freeModelCatalog(alloc, old);
                }
                self.pending_catalog = loaded.catalog;
                self.completed = true;
                self.succeeded = true;
                self.mutex.unlock(io);

                if (notify_copy) |copy| {
                    if (!self.cancel_flag.load(.seq_cst)) {
                        job.on_complete_fn.?(
                            job.on_complete_ctx,
                            copy.items,
                            fp,
                            loaded.supports_signaling_v1,
                        );
                    }
                }

                self.mutex.lockUncancelable(io);
                self.running = false;
                self.mutex.unlock(io);
            },
        }
    }
};

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

test "Constellation disk cache round-trips catalog, signaling capability, and base URL scope" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    const raw_models =
        \\{"object":"list","data":[
        \\  {"id":"constellation/auto","object":"model","owned_by":"constellation"},
        \\  {"id":"openai/gpt-5.4","object":"model","owned_by":"codex","capabilities":["chat","tools","vision"],"reasoning_efforts":["low","medium","high"]}
        \\]}
    ;
    const custom_url = "http://127.0.0.1:18080/api/v1";
    const other_url = "http://127.0.0.1:19999/api/v1";

    defer signaling.setRouterSupportsBodySignaling(false);
    signaling.setRouterSupportsBodySignaling(false);
    try std.testing.expect(loadDiskCache(alloc, home, custom_url) == null);

    saveDiskCache(alloc, home, custom_url, true, raw_models);
    try std.testing.expect(loadDiskCache(alloc, home, other_url) == null);

    var cached = loadDiskCache(alloc, home, custom_url ++ "/") orelse return error.TestUnexpectedResult;
    defer cached.deinit(alloc);
    try std.testing.expect(cached.supports_signaling_v1);
    try std.testing.expect(signaling.routerSupportsBodySignaling());
    try std.testing.expectEqual(@as(usize, 2), cached.catalog.items.len);
    try std.testing.expectEqualStrings("constellation/auto", cached.catalog.items[0].id);
    try std.testing.expectEqualStrings("openai/gpt-5.4", cached.catalog.items[1].id);
    try std.testing.expectEqual(@as(usize, 3), cached.catalog.items[1].reasoning_efforts.items.len);

    const fp_before = catalogFingerprint(cached.catalog.items);
    const updated_models =
        \\{"object":"list","data":[
        \\  {"id":"constellation/auto","object":"model","owned_by":"constellation"},
        \\  {"id":"openai/gpt-5.4","object":"model","owned_by":"codex","capabilities":["chat","tools","vision"],"reasoning_efforts":["low","medium","high"]},
        \\  {"id":"xai/grok-4.7","object":"model","owned_by":"grok"}
        \\]}
    ;
    var updated = try parseCatalog(alloc, updated_models);
    defer model_catalog.freeModelCatalog(alloc, &updated);
    try std.testing.expect(fp_before != catalogFingerprint(updated.items));
}

test "Constellation disk cache fails open on corrupt JSON and BackgroundSync tears down cleanly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    const path = (try cacheFilePath(alloc, home, runtime.default_base_url)).?;
    defer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), std.fs.path.dirname(path).?);
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "{not valid json");
    }
    try std.testing.expect(loadDiskCache(alloc, home, runtime.default_base_url) == null);

    var sync: BackgroundSync = .{};
    defer sync.deinit();
    try std.testing.expect(!sync.isRunning());
    try std.testing.expect(!sync.hasCompleted());
    try std.testing.expect(sync.takeCompletedCatalog() == null);
}
