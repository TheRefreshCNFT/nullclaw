//! Discord Action Tool — native Discord API interactions.
//!
//! Gives the agent ability to react, pin, delete messages, create threads,
//! manage roles, and perform moderation actions via Discord REST API v10.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const http_util = @import("../root.zig").http_util;

const log = std.log.scoped(.discord_action);

pub const DiscordActionTool = struct {
    /// Bot token — set per-turn by the daemon from the current channel's config.
    bot_token: ?[]const u8 = null,
    /// Current channel ID — set per-turn from the inbound message metadata.
    current_channel_id: ?[]const u8 = null,
    /// Current message ID — set per-turn from the inbound message metadata.
    current_message_id: ?[]const u8 = null,
    /// Guild ID — set per-turn from the inbound message metadata.
    current_guild_id: ?[]const u8 = null,
    allocator: std.mem.Allocator = undefined,

    pub const tool_name = "discord_action";
    pub const tool_description =
        "Perform Discord actions: react to messages, pin/unpin, delete messages, " ++
        "create threads, add/remove roles, kick/ban members, set channel topic. " ++
        "Only works when the current channel is Discord.";
    pub const tool_params =
        \\{"type":"object","properties":{
        \\"action":{"type":"string","enum":["react","remove_react","pin","unpin","delete","create_thread","add_role","remove_role","kick","ban","unban","set_topic","get_member"],
        \\"description":"Discord action to perform"},
        \\"emoji":{"type":"string","description":"Emoji for react/remove_react (Unicode emoji or custom format name:id)"},
        \\"channel_id":{"type":"string","description":"Target channel ID (defaults to current channel)"},
        \\"message_id":{"type":"string","description":"Target message ID (defaults to current message for react/pin/delete)"},
        \\"user_id":{"type":"string","description":"Target user ID for role/kick/ban actions"},
        \\"role_id":{"type":"string","description":"Role ID for add_role/remove_role"},
        \\"name":{"type":"string","description":"Thread name for create_thread"},
        \\"topic":{"type":"string","description":"Channel topic text for set_topic"},
        \\"reason":{"type":"string","description":"Audit log reason for moderation actions"}
        \\},"required":["action"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *DiscordActionTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Set context for the current turn.
    pub fn setContext(
        self: *DiscordActionTool,
        token: ?[]const u8,
        channel_id: ?[]const u8,
        message_id: ?[]const u8,
        guild_id: ?[]const u8,
    ) void {
        self.bot_token = token;
        self.current_channel_id = channel_id;
        self.current_message_id = message_id;
        self.current_guild_id = guild_id;
    }

    pub fn execute(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const token = self.bot_token orelse
            return ToolResult.fail("discord_action: not on a Discord channel");

        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing required 'action' parameter");

        const channel_id = root.getString(args, "channel_id") orelse
            (self.current_channel_id orelse
                return ToolResult.fail("No channel_id specified and no current channel"));

        // Build auth header
        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        auth_fbs.writer().print("Authorization: Bot {s}", .{token}) catch
            return ToolResult.fail("Token too long");
        const auth_header = auth_fbs.getWritten();

        // Dispatch by action
        if (std.mem.eql(u8, action, "react")) {
            return self.doReact(allocator, args, channel_id, auth_header);
        } else if (std.mem.eql(u8, action, "remove_react")) {
            return self.doRemoveReact(allocator, args, channel_id, auth_header);
        } else if (std.mem.eql(u8, action, "pin")) {
            return self.doPin(allocator, args, channel_id, auth_header);
        } else if (std.mem.eql(u8, action, "unpin")) {
            return self.doUnpin(allocator, args, channel_id, auth_header);
        } else if (std.mem.eql(u8, action, "delete")) {
            return self.doDelete(allocator, args, channel_id, auth_header);
        } else if (std.mem.eql(u8, action, "create_thread")) {
            return self.doCreateThread(allocator, args, channel_id, auth_header);
        } else if (std.mem.eql(u8, action, "add_role")) {
            return self.doRoleAction(allocator, args, auth_header, true);
        } else if (std.mem.eql(u8, action, "remove_role")) {
            return self.doRoleAction(allocator, args, auth_header, false);
        } else if (std.mem.eql(u8, action, "kick")) {
            return self.doModeration(allocator, args, auth_header, "kick");
        } else if (std.mem.eql(u8, action, "ban")) {
            return self.doModeration(allocator, args, auth_header, "ban");
        } else if (std.mem.eql(u8, action, "unban")) {
            return self.doModeration(allocator, args, auth_header, "unban");
        } else if (std.mem.eql(u8, action, "set_topic")) {
            return self.doSetTopic(allocator, args, channel_id, auth_header);
        } else if (std.mem.eql(u8, action, "get_member")) {
            return self.doGetMember(allocator, args, auth_header);
        } else {
            return ToolResult.fail("Unknown action. Valid: react, remove_react, pin, unpin, delete, create_thread, add_role, remove_role, kick, ban, unban, set_topic, get_member");
        }
    }

    // ── Action implementations ──────────────────────────────────────

    fn doReact(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, channel_id: []const u8, auth: []const u8) !ToolResult {
        const emoji = root.getString(args, "emoji") orelse
            return ToolResult.fail("react requires 'emoji' parameter");
        const msg_id = root.getString(args, "message_id") orelse
            (self.current_message_id orelse
                return ToolResult.fail("react requires 'message_id' or a current message"));

        // URL-encode the emoji for the path
        var emoji_buf: [256]u8 = undefined;
        const encoded_emoji = uriEncodeEmoji(&emoji_buf, emoji) catch
            return ToolResult.fail("Emoji too long to encode");

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/channels/{s}/messages/{s}/reactions/{s}/@me", .{ channel_id, msg_id, encoded_emoji }) catch
            return ToolResult.fail("URL too long");

        return apiPut(allocator, url, auth);
    }

    fn doRemoveReact(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, channel_id: []const u8, auth: []const u8) !ToolResult {
        const emoji = root.getString(args, "emoji") orelse
            return ToolResult.fail("remove_react requires 'emoji' parameter");
        const msg_id = root.getString(args, "message_id") orelse
            (self.current_message_id orelse
                return ToolResult.fail("remove_react requires 'message_id'"));

        var emoji_buf: [256]u8 = undefined;
        const encoded_emoji = uriEncodeEmoji(&emoji_buf, emoji) catch
            return ToolResult.fail("Emoji too long");

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/channels/{s}/messages/{s}/reactions/{s}/@me", .{ channel_id, msg_id, encoded_emoji }) catch
            return ToolResult.fail("URL too long");

        return apiDelete(allocator, url, auth);
    }

    fn doPin(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, channel_id: []const u8, auth: []const u8) !ToolResult {
        const msg_id = root.getString(args, "message_id") orelse
            (self.current_message_id orelse
                return ToolResult.fail("pin requires 'message_id'"));

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/channels/{s}/pins/{s}", .{ channel_id, msg_id }) catch
            return ToolResult.fail("URL too long");

        return apiPut(allocator, url, auth);
    }

    fn doUnpin(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, channel_id: []const u8, auth: []const u8) !ToolResult {
        const msg_id = root.getString(args, "message_id") orelse
            (self.current_message_id orelse
                return ToolResult.fail("unpin requires 'message_id'"));

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/channels/{s}/pins/{s}", .{ channel_id, msg_id }) catch
            return ToolResult.fail("URL too long");

        return apiDelete(allocator, url, auth);
    }

    fn doDelete(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, channel_id: []const u8, auth: []const u8) !ToolResult {
        const msg_id = root.getString(args, "message_id") orelse
            (self.current_message_id orelse
                return ToolResult.fail("delete requires 'message_id'"));

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/channels/{s}/messages/{s}", .{ channel_id, msg_id }) catch
            return ToolResult.fail("URL too long");

        return apiDelete(allocator, url, auth);
    }

    fn doCreateThread(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, channel_id: []const u8, auth: []const u8) !ToolResult {
        _ = self;
        const name = root.getString(args, "name") orelse
            return ToolResult.fail("create_thread requires 'name' parameter");

        const msg_id = root.getString(args, "message_id");

        var url_buf: [256]u8 = undefined;
        const url = if (msg_id) |mid|
            std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/channels/{s}/messages/{s}/threads", .{ channel_id, mid }) catch
                return ToolResult.fail("URL too long")
        else
            std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/channels/{s}/threads", .{channel_id}) catch
                return ToolResult.fail("URL too long");

        // Build JSON body
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{\"name\":") catch return ToolResult.fail("OOM");
        @import("../json_util.zig").appendJsonString(&body_buf, allocator, name) catch return ToolResult.fail("OOM");
        if (msg_id == null) {
            // Without a message_id, must specify type (11 = public thread)
            body_buf.appendSlice(allocator, ",\"type\":11") catch return ToolResult.fail("OOM");
        }
        body_buf.appendSlice(allocator, "}") catch return ToolResult.fail("OOM");

        return apiPost(allocator, url, body_buf.items, auth);
    }

    fn doRoleAction(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, auth: []const u8, add: bool) !ToolResult {
        const guild_id = self.current_guild_id orelse
            return ToolResult.fail("Role actions require a guild context");
        const user_id = root.getString(args, "user_id") orelse
            return ToolResult.fail("add_role/remove_role requires 'user_id'");
        const role_id = root.getString(args, "role_id") orelse
            return ToolResult.fail("add_role/remove_role requires 'role_id'");

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/guilds/{s}/members/{s}/roles/{s}", .{ guild_id, user_id, role_id }) catch
            return ToolResult.fail("URL too long");

        if (add) {
            return apiPut(allocator, url, auth);
        } else {
            return apiDelete(allocator, url, auth);
        }
    }

    fn doModeration(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, auth: []const u8, mod_action: []const u8) !ToolResult {
        const guild_id = self.current_guild_id orelse
            return ToolResult.fail("Moderation actions require a guild context");
        const user_id = root.getString(args, "user_id") orelse
            return ToolResult.fail("Moderation requires 'user_id'");

        var url_buf: [256]u8 = undefined;

        if (std.mem.eql(u8, mod_action, "kick")) {
            const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/guilds/{s}/members/{s}", .{ guild_id, user_id }) catch
                return ToolResult.fail("URL too long");
            return apiDelete(allocator, url, auth);
        } else if (std.mem.eql(u8, mod_action, "ban")) {
            const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/guilds/{s}/bans/{s}", .{ guild_id, user_id }) catch
                return ToolResult.fail("URL too long");
            return apiPut(allocator, url, auth);
        } else if (std.mem.eql(u8, mod_action, "unban")) {
            const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/guilds/{s}/bans/{s}", .{ guild_id, user_id }) catch
                return ToolResult.fail("URL too long");
            return apiDelete(allocator, url, auth);
        }
        return ToolResult.fail("Unknown moderation action");
    }

    fn doSetTopic(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, channel_id: []const u8, auth: []const u8) !ToolResult {
        _ = self;
        const topic = root.getString(args, "topic") orelse
            return ToolResult.fail("set_topic requires 'topic' parameter");

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/channels/{s}", .{channel_id}) catch
            return ToolResult.fail("URL too long");

        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);
        body_buf.appendSlice(allocator, "{\"topic\":") catch return ToolResult.fail("OOM");
        @import("../json_util.zig").appendJsonString(&body_buf, allocator, topic) catch return ToolResult.fail("OOM");
        body_buf.appendSlice(allocator, "}") catch return ToolResult.fail("OOM");

        return apiPatch(allocator, url, body_buf.items, auth);
    }

    fn doGetMember(self: *DiscordActionTool, allocator: std.mem.Allocator, args: JsonObjectMap, auth: []const u8) !ToolResult {
        const guild_id = self.current_guild_id orelse
            return ToolResult.fail("get_member requires a guild context");
        const user_id = root.getString(args, "user_id") orelse
            return ToolResult.fail("get_member requires 'user_id'");

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://discord.com/api/v10/guilds/{s}/members/{s}", .{ guild_id, user_id }) catch
            return ToolResult.fail("URL too long");

        const resp = http_util.curlGet(allocator, url, &.{auth}, "10") catch
            return ToolResult.fail("Discord API GET failed");

        return ToolResult{ .success = true, .output = resp };
    }

    // ── HTTP helpers ────────────────────────────────────────────────

    fn apiPut(allocator: std.mem.Allocator, url: []const u8, auth: []const u8) !ToolResult {
        const resp = http_util.curlPut(allocator, url, "", &.{auth}) catch |err| {
            log.err("Discord API PUT failed: {}", .{err});
            return ToolResult.fail("Discord API PUT failed");
        };
        defer allocator.free(resp);

        if (resp.len == 0 or resp[0] != '{' or std.mem.indexOf(u8, resp, "\"code\"") == null) {
            return ToolResult.ok("Done");
        }
        // Response has content — return it (might be error JSON)
        const out = try allocator.dupe(u8, resp);
        return ToolResult{ .success = true, .output = out };
    }

    fn apiDelete(allocator: std.mem.Allocator, url: []const u8, auth: []const u8) !ToolResult {
        // No curlDelete in http_util, use curl subprocess directly
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "curl", "-s", "-X", "DELETE",
                "-H", "Content-Type: application/json",
                "-H", auth,
                url,
            },
        }) catch {
            return ToolResult.fail("Discord API DELETE failed");
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.stdout.len == 0) {
            return ToolResult.ok("Done");
        }
        const out = try allocator.dupe(u8, result.stdout);
        return ToolResult{ .success = true, .output = out };
    }

    fn apiPost(allocator: std.mem.Allocator, url: []const u8, body: []const u8, auth: []const u8) !ToolResult {
        const resp = http_util.curlPost(allocator, url, body, &.{auth}) catch |err| {
            log.err("Discord API POST failed: {}", .{err});
            return ToolResult.fail("Discord API POST failed");
        };
        if (resp.len == 0) {
            return ToolResult.ok("Done");
        }
        return ToolResult{ .success = true, .output = resp };
    }

    fn apiPatch(allocator: std.mem.Allocator, url: []const u8, body: []const u8, auth: []const u8) !ToolResult {
        // PATCH via curl subprocess (no curlPatch in http_util)
        var child = std.process.Child.init(
            &.{
                "curl", "-s", "-X", "PATCH",
                "-H", "Content-Type: application/json",
                "-H", auth,
                "-d", body,
                url,
            },
            allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return ToolResult.fail("Discord API PATCH read failed");
        };
        _ = child.wait() catch {
            allocator.free(stdout);
            return ToolResult.fail("Discord API PATCH wait failed");
        };

        if (stdout.len == 0) {
            allocator.free(stdout);
            return ToolResult.ok("Done");
        }
        return ToolResult{ .success = true, .output = stdout };
    }

    // ── Emoji URI encoding ──────────────────────────────────────────

    /// Percent-encode a Unicode emoji or pass through custom emoji format (name:id).
    fn uriEncodeEmoji(buf: []u8, emoji: []const u8) ![]const u8 {
        // Custom emoji format: "name:id" — pass through as-is
        if (std.mem.indexOf(u8, emoji, ":") != null) {
            if (emoji.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[0..emoji.len], emoji);
            return buf[0..emoji.len];
        }
        // Unicode emoji — percent-encode each byte
        var pos: usize = 0;
        for (emoji) |byte| {
            if (pos + 3 > buf.len) return error.BufferTooSmall;
            buf[pos] = '%';
            pos += 1;
            const hex = "0123456789ABCDEF";
            buf[pos] = hex[byte >> 4];
            pos += 1;
            buf[pos] = hex[byte & 0x0F];
            pos += 1;
        }
        return buf[0..pos];
    }
};

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const testing = std.testing;

test "DiscordActionTool name and description" {
    var dt = DiscordActionTool{};
    const t = dt.tool();
    try testing.expectEqualStrings("discord_action", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "DiscordActionTool execute without token fails" {
    var dt = DiscordActionTool{};
    const parsed = try root.parseTestArgs("{\"action\":\"react\",\"emoji\":\"👍\"}");
    defer parsed.deinit();
    const result = try dt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("discord_action: not on a Discord channel", result.error_msg.?);
}

test "DiscordActionTool react without emoji fails" {
    var dt = DiscordActionTool{};
    dt.setContext("fake_token", "chan1", "msg1", "guild1");
    const parsed = try root.parseTestArgs("{\"action\":\"react\"}");
    defer parsed.deinit();
    const result = try dt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("react requires 'emoji' parameter", result.error_msg.?);
}

test "DiscordActionTool unknown action fails" {
    var dt = DiscordActionTool{};
    dt.setContext("fake_token", "chan1", "msg1", "guild1");
    const parsed = try root.parseTestArgs("{\"action\":\"explode\"}");
    defer parsed.deinit();
    const result = try dt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
}

test "uriEncodeEmoji unicode" {
    var buf: [256]u8 = undefined;
    // thumbs up emoji bytes: 0xF0 0x9F 0x91 0x8D
    const result = DiscordActionTool.uriEncodeEmoji(&buf, "\xF0\x9F\x91\x8D") catch unreachable;
    try testing.expectEqualStrings("%F0%9F%91%8D", result);
}

test "uriEncodeEmoji custom format" {
    var buf: [256]u8 = undefined;
    const result = DiscordActionTool.uriEncodeEmoji(&buf, "pepe:123456789") catch unreachable;
    try testing.expectEqualStrings("pepe:123456789", result);
}
