const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("../gateway/client.zig");
const responses_protocol = @import("../gateway/responses_protocol.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

const max_error_body_bytes: usize = 1024 * 1024;
const max_sse_line_bytes: usize = 32 * 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_provider_state_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

const StreamLimits = struct {
    aggregate_bytes: usize = max_sse_aggregate_bytes,
    events: usize = max_sse_events,
    tool_calls: usize = max_tool_calls,
    tool_identity_bytes: usize = max_tool_identity_bytes,
    tool_arguments_bytes: usize = max_tool_arguments_bytes,
    provider_state_bytes: usize = max_provider_state_bytes,
};

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
    .build_request_fn = buildRequestForProvider,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidConstellationModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidConstellationModel;
    }
}

fn mapReasoningEffort(raw: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, raw, "none") or
        std.mem.eql(u8, raw, "minimal") or
        std.mem.eql(u8, raw, "low") or
        std.mem.eql(u8, raw, "medium") or
        std.mem.eql(u8, raw, "high") or
        std.mem.eql(u8, raw, "xhigh"))
    {
        return raw;
    }
    if (std.mem.eql(u8, raw, "max")) return "xhigh";
    return null;
}

/// Serializes an OpenAI Responses API request conforming strictly to
/// Constellation Router's public Responses allowlist (`validatePublicBody`).
pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    try request.validatePrompt();
    try validateModel(request.model);
    const budget: image_attachments.CaptureBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        .{};
    try budget.check();

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.instructions) |instruction| {
        const text = instruction.content.?;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }
    if (instructions.written().len == 0) {
        try instructions.writer.writeAll("You are a helpful assistant.");
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true,\"instructions\":");
    try std.json.Stringify.value(instructions.written(), .{}, writer);
    try writer.writeAll(",\"input\":[");
    try writeResponsesInput(writer, alloc, request.messages, request.verified_images, budget);
    try writer.writeByte(']');

    const tool_count = try responses_protocol.writeTools(writer, alloc, request.tools);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
        const parallel = request.provider_options.parallel_tool_calls orelse true;
        try writer.writeAll(if (parallel) ",\"parallel_tool_calls\":true" else ",\"parallel_tool_calls\":false");
    }

    try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");

    if (request.provider_options.reasoning) |effort| {
        if (mapReasoningEffort(effort.label())) |label| {
            try writer.writeAll(",\"reasoning\":{\"effort\":");
            try std.json.Stringify.value(label, .{}, writer);
            try writer.writeAll(",\"summary\":\"auto\"}");
        }
    }

    if (request.max_output_tokens) |max_tokens| {
        if (max_tokens > 0) {
            try writer.print(",\"max_output_tokens\":{d}", .{max_tokens});
        }
    }

    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn buildRequestForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.RequestData,
) anyerror![]u8 {
    return buildRequest(alloc, request);
}

fn writeResponsesInput(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    images: ?[]const image_attachments.VerifiedSnapshot,
    budget: image_attachments.CaptureBudget,
) !void {
    return responses_protocol.writeInput(writer, alloc, messages, images, .{
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    }, budget) catch |err| switch (err) {
        error.ProviderStateTooLarge => error.ConstellationProviderStateTooLarge,
        error.InvalidProviderState => error.InvalidConstellationProviderState,
        error.ToolCallLimitExceeded => error.ConstellationToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.ConstellationToolArgumentsTooLarge,
        else => err,
    };
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    try validateModel(request.model);
    const payload = request.prepared_request_body orelse
        try buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);

    var operation = PreparedStreamOperation{
        .alloc = alloc,
        .request = request,
        .payload = payload,
    };
    return (if (request.deadline) |deadline|
        gateway_client.runBoundedHttpOperation(
            stream_provider.Result,
            alloc,
            request.cancel_flag,
            deadline,
            &operation,
        )
    else
        operation.run()) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
}

const PreparedStreamOperation = struct {
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,

    pub fn run(self: *@This()) !stream_provider.Result {
        return streamPrepared(self.alloc, self.request, self.payload);
    }
};

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: ?[]const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        var headers: std.http.Client.Request.Headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = gateway_client.user_agent },
        };
        if (self.auth_header) |authorization| {
            headers.authorization = .{ .override = authorization };
        }
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = headers,
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn buildAuthHeader(alloc: Allocator, auth: stream_provider.CredentialLease) !?[]u8 {
    return switch (auth) {
        .host_managed => null,
        .direct => |direct| blk: {
            if (direct.secret_bytes.len == 0) return error.MissingConstellationApiKey;
            break :blk try std.fmt.allocPrint(alloc, "Bearer {s}", .{direct.secret_bytes});
        },
    };
}

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    const auth_header = try buildAuthHeader(alloc, request.credential);
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);

    const request_endpoint = try runtime.endpointUrl(alloc, runtime.resolveBaseUrl(), "/responses");
    defer alloc.free(request_endpoint);
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [6]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = runtime.client_header_name, .value = runtime.client_header_value };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-constellation-client-id", .value = runtime.client_header_value };
    extra_count += 1;
    if (request.session_id) |session_id| if (session_id.len > 0) {
        extra_headers_buf[extra_count] = .{ .name = "session-id", .value = session_id };
        extra_count += 1;
        extra_headers_buf[extra_count] = .{ .name = "x-constellation-conversation-id", .value = session_id };
        extra_count += 1;
    };

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
        .extra_headers = extra_headers_buf[0..extra_count],
    };
    const connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        try gateway_client.spawnHttpCancelWatcher(
            &cancel_watch_done,
            request.cancel_flag,
            connection.stream_writer.stream,
        )
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var head_buffer: [16 * 1024]u8 = undefined;
    var response = try http_request.receiveHead(&head_buffer);
    if (response.head.status != .ok) {
        const retry_after = parseRetryAfterHeader(&response.head);
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Constellation Router error response exceeded the local limit"),
            else => return err,
        };
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .retry_after_seconds = retry_after,
            .ownership = .owned,
        } };
    }

    var telemetry = collectRouteTelemetry(alloc, &response.head);
    defer telemetry.deinit(alloc);
    if (telemetry.hasAny()) {
        runtime.storeRouteTelemetry(request.session_id, telemetry);
        debug_trace.eventf(
            "constellation",
            "route_decision",
            request.trace_ctx,
            "requested_model={s} route_model={s} route_path={s} route_label={s} route_effort={s} route_classify={s}",
            .{
                request.model,
                telemetry.route_model orelse "none",
                telemetry.route_path orelse "none",
                telemetry.route_label orelse "none",
                telemetry.route_effort orelse "none",
                telemetry.route_classify orelse "none",
            },
        );
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    var completion = try consumeSse(
        alloc,
        reader,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        EventBridge.toolInput,
        request.cancel_flag,
        request.content_capture_limit,
        .{},
    );
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }

    const billed_model = telemetry.route_model orelse request.model;
    const usage_outcome: stream_provider.UsageOutcome = usage: {
        if (completion.generation_id == null) {
            break :usage .{ .unavailable = .possibly_billed };
        }
        completion.billing = try buildConstellationBilling(
            alloc,
            billed_model,
            @max(io_mod.milliTimestamp(), 0),
            completion.usage,
        ) orelse break :usage .{ .unavailable = .possibly_billed };
        break :usage .{ .exact = .gateway };
    };

    return .{ .completed = .{
        .completion = completion,
        .usage = usage_outcome,
        .ownership = .owned,
    } };
}

fn buildConstellationBilling(
    alloc: Allocator,
    model: []const u8,
    created_at_ms: i64,
    usage: types.Usage,
) !?types.ProviderBilling {
    if (created_at_ms < 0) return null;
    const input_tokens = usage.input_tokens orelse return null;
    const output_tokens = usage.output_tokens orelse return null;
    const model_copy = try alloc.dupe(u8, model);
    return .{
        .created_at_ms = created_at_ms,
        .model = model_copy,
        .total_cost = 0,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = if (usage.cache_read_tokens) |v| @min(v, input_tokens) else 0,
        .cache_write_tokens = if (usage.cache_write_tokens) |v| @min(v, input_tokens) else 0,
        .reasoning_tokens = if (usage.reasoning_tokens) |v| @min(v, output_tokens) else null,
        .billable_web_search_calls = 0,
    };
}

fn collectRouteTelemetry(alloc: Allocator, head: *const std.http.Client.Response.Head) runtime.RouteTelemetry {
    var telemetry: runtime.RouteTelemetry = .{};
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        telemetry.recordHeader(alloc, header.name, header.value) catch {};
    }
    return telemetry;
}

fn parseRetryAfterHeader(head: *const std.http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            const trimmed = std.mem.trim(u8, header.value, " \t\r\n");
            return std.fmt.parseUnsigned(u64, trimmed, 10) catch null;
        }
    }
    return null;
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.ConstellationSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.ConstellationSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return self.pending_line.items;
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.ConstellationSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return fragment;
            try self.pending_line.appendSlice(alloc, fragment);
            return self.pending_line.items;
        }
    }
};

fn consumeSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
    limits: StreamLimits,
) !types.ModelCompletion {
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    const callbacks = responses_protocol.StreamCallbacks{
        .context = callback_ctx,
        .on_content = on_content_chunk,
        .on_tool_start = on_tool_start,
        .on_reasoning = on_reasoning_chunk,
        .on_tool_input = on_tool_input_chunk,
    };
    const stream_limits = responses_protocol.StreamLimits{
        .aggregate_bytes = limits.aggregate_bytes,
        .events = limits.events,
        .tool_calls = limits.tool_calls,
        .tool_identity_bytes = limits.tool_identity_bytes,
        .tool_arguments_bytes = limits.tool_arguments_bytes,
        .provider_state_bytes = limits.provider_state_bytes,
    };
    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (reducer.applyJson(
            alloc,
            json_text,
            callbacks,
            cancel_flag,
            content_capture_limit,
            stream_limits,
        ) catch |err| return mapReducerError(err)) break;
    }
    return reducer.finish(alloc, cancel_flag, stream_limits) catch |err|
        return mapReducerError(err);
}

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidEvent => error.InvalidConstellationSseEvent,
        error.ResponseFailed => error.ConstellationResponseFailed,
        error.StreamIncomplete => error.ConstellationStreamIncomplete,
        error.ToolCallLimitExceeded => error.ConstellationToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.ConstellationToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.ConstellationResourceLimitExceeded,
        else => err,
    };
}

test "Constellation Responses request obeys public router allowlist without tools" {
    const alloc = std.testing.allocator;
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "Be direct." }};
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello" }};
    const body = try buildRequest(alloc, .{
        .model = "constellation/auto",
        .instructions = &instructions,
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("max"), .fast = true },
        .max_output_tokens = 1024,
    });
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("constellation/auto", obj.get("model").?.string);
    try std.testing.expectEqual(false, obj.get("store").?.bool);
    try std.testing.expectEqual(true, obj.get("stream").?.bool);
    try std.testing.expectEqualStrings("Be direct.", obj.get("instructions").?.string);
    try std.testing.expectEqual(@as(i64, 1024), obj.get("max_output_tokens").?.integer);
    try std.testing.expectEqualStrings("xhigh", obj.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expect(obj.get("tools") == null);
    try std.testing.expect(obj.get("tool_choice") == null);
    try std.testing.expect(obj.get("parallel_tool_calls") == null);
    try std.testing.expect(obj.get("text") == null);
    try std.testing.expect(obj.get("service_tier") == null);
}

test "Constellation Responses request emits tool_choice and parallel_tool_calls when tools exist" {
    const alloc = std.testing.allocator;
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read a file",
        .input_schema = .{},
    };
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Read README.md" }};
    const body = try buildRequest(alloc, .{
        .model = "constellation/smart",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{read_file_schema} },
        .tool_choice = .required,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("medium") },
    });
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1), obj.get("tools").?.array.items.len);
    try std.testing.expectEqualStrings("required", obj.get("tool_choice").?.string);
    try std.testing.expectEqual(true, obj.get("parallel_tool_calls").?.bool);
    try std.testing.expectEqualStrings("medium", obj.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expect(obj.get("text") == null);
    try std.testing.expect(obj.get("service_tier") == null);
}
