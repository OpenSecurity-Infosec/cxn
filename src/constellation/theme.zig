//! Constellation design-schema themes for `cxn`: Catppuccin Mocha (dark) and
//! Catppuccin Latte (light) with the Constellation Router accent roles.
//!
//! Role mapping, shared by both variants so a live light/dark flip retints
//! every slot consistently:
//!   Blue      primary accent: prompt rail, subtitle, selected completion,
//!             active approval button background (Crust bold foreground)
//!   Lavender  tags, system notice labels, user card accent, variables
//!   Peach     warnings, tool stderr, numbers, auto permission mode
//!   Green     success, task completed, diff added, strings
//!   Red       errors and failures, diff removed
//!   Mauve     keywords        Teal  inline code
//!   Sapphire  links           Sky   operators
//!
//! Bare `fx` never selects these themes unless a user names one; `cxn` mode
//! activates them by default (see `app_lifecycle.zig`).

const std = @import("std");
const shared_theme = @import("../core/shared/theme.zig");

const Theme = shared_theme.Theme;

/// One palette color: its truecolor value and the hand-picked xterm-256 index
/// used when the terminal lacks truecolor support.
const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    idx: u8,
};

const Palette = struct {
    crust: Color,
    surface0: Color,
    surface1: Color,
    overlay0: Color,
    subtext0: Color,
    subtext1: Color,
    text: Color,
    blue: Color,
    lavender: Color,
    peach: Color,
    green: Color,
    red: Color,
    mauve: Color,
    teal: Color,
    sapphire: Color,
    sky: Color,
};

fn c(r: u8, g: u8, b: u8, idx: u8) Color {
    return .{ .r = r, .g = g, .b = b, .idx = idx };
}

const mocha_palette: Palette = .{
    .crust = c(0x11, 0x11, 0x1b, 233),
    .surface0 = c(0x31, 0x32, 0x44, 236),
    .surface1 = c(0x45, 0x47, 0x5a, 238),
    .overlay0 = c(0x6c, 0x70, 0x86, 243),
    .subtext0 = c(0xa6, 0xad, 0xc8, 248),
    .subtext1 = c(0xba, 0xc2, 0xde, 250),
    .text = c(0xcd, 0xd6, 0xf4, 189),
    .blue = c(0x89, 0xb4, 0xfa, 111),
    .lavender = c(0xb4, 0xbe, 0xfe, 147),
    .peach = c(0xfa, 0xb3, 0x87, 216),
    .green = c(0xa6, 0xe3, 0xa1, 151),
    .red = c(0xf3, 0x8b, 0xa8, 211),
    .mauve = c(0xcb, 0xa6, 0xf7, 183),
    .teal = c(0x94, 0xe2, 0xd5, 116),
    .sapphire = c(0x74, 0xc7, 0xec, 74),
    .sky = c(0x89, 0xdc, 0xeb, 117),
};

const latte_palette: Palette = .{
    .crust = c(0xdc, 0xe0, 0xe8, 254),
    .surface0 = c(0xcc, 0xd0, 0xda, 253),
    .surface1 = c(0xbc, 0xc0, 0xcc, 250),
    .overlay0 = c(0x9c, 0xa0, 0xb0, 247),
    .subtext0 = c(0x6c, 0x6f, 0x85, 243),
    .subtext1 = c(0x5c, 0x5f, 0x77, 241),
    .text = c(0x4c, 0x4f, 0x69, 60),
    .blue = c(0x1e, 0x66, 0xf5, 27),
    .lavender = c(0x72, 0x87, 0xfd, 105),
    .peach = c(0xfe, 0x64, 0x0b, 202),
    .green = c(0x40, 0xa0, 0x2b, 34),
    .red = c(0xd2, 0x0f, 0x39, 161),
    .mauve = c(0x88, 0x39, 0xef, 135),
    .teal = c(0x17, 0x92, 0x99, 30),
    .sapphire = c(0x20, 0x9f, 0xb5, 38),
    .sky = c(0x04, 0xa5, 0xe5, 39),
};

fn colorParam(comptime prefix: []const u8, comptime color: Color, comptime truecolor: bool) []const u8 {
    return if (truecolor)
        std.fmt.comptimePrint("{s};2;{d};{d};{d}", .{ prefix, color.r, color.g, color.b })
    else
        std.fmt.comptimePrint("{s};5;{d}", .{ prefix, color.idx });
}

fn fg(comptime color: Color, comptime truecolor: bool) []const u8 {
    return "\x1b[" ++ colorParam("38", color, truecolor) ++ "m";
}

fn fgBold(comptime color: Color, comptime truecolor: bool) []const u8 {
    return "\x1b[1;" ++ colorParam("38", color, truecolor) ++ "m";
}

fn bgFg(comptime bg: Color, comptime fg_color: Color, comptime truecolor: bool, comptime bold: bool) []const u8 {
    return "\x1b[" ++ colorParam("48", bg, truecolor) ++ "m\x1b[" ++ colorParam("38", fg_color, truecolor) ++ "m" ++
        (if (bold) "\x1b[1m" else "");
}

fn build(comptime name: []const u8, comptime light: bool, comptime p: Palette, comptime truecolor: bool) Theme {
    // Each slot formats its escape at comptime; 40 or so comptimePrint calls
    // exceed the default branch quota.
    @setEvalBranchQuota(2_000_000);
    return .{
        .name = name,
        .light = light,

        .divider_style = fg(p.surface1, truecolor),
        .hint_style = fg(p.subtext1, truecolor),
        .statusline_style = fg(p.subtext0, truecolor),
        .tag_style = fgBold(p.lavender, truecolor),
        .subtitle_style = fgBold(p.blue, truecolor),
        .system_notice_label_style = fgBold(p.lavender, truecolor),
        .system_notice_text_style = fg(p.subtext0, truecolor),
        .dim_style = fg(p.overlay0, truecolor),
        .warning_style = fg(p.peach, truecolor),
        .green_style = fg(p.green, truecolor),
        .red_style = fg(p.red, truecolor),
        .diff_added_style = fg(p.green, truecolor),
        .diff_removed_style = fg(p.red, truecolor),
        // The marker slots ship both capability variants in every theme; the
        // renderer picks one from the terminal's truecolor support.
        .diff_added_marker_truecolor = fg(p.green, true),
        .diff_removed_marker_truecolor = fg(p.red, true),
        .diff_added_marker_fallback = fg(p.green, false),
        .diff_removed_marker_fallback = fg(p.red, false),
        .approval_button_active_style = bgFg(p.blue, p.crust, truecolor, true),
        .approval_button_inactive_style = bgFg(p.surface0, p.text, truecolor, false),
        .selected_completion_style = fgBold(p.blue, truecolor),
        .permission_auto_style = fg(p.peach, truecolor),
        .user_card_marker_style = fg(p.blue, truecolor),
        .user_card_accent_style = fg(p.lavender, truecolor),
        .inline_code_open = fg(p.teal, truecolor),
        .task_completed_open = fg(p.green, truecolor),
        .tool_stdout_style = fg(p.subtext0, truecolor),
        .tool_stderr_style = fg(p.peach, truecolor),
        .link_style = fg(p.sapphire, truecolor),
        .syntax = .{
            .keyword_style = fg(p.mauve, truecolor),
            .string_style = fg(p.green, truecolor),
            .number_style = fg(p.peach, truecolor),
            .comment_style = fg(p.overlay0, truecolor),
            .function_style = fg(p.blue, truecolor),
            .variable_style = fg(p.lavender, truecolor),
            .operator_style = fg(p.sky, truecolor),
        },
    };
}

pub const constellation_mocha_truecolor: Theme = build("constellation-mocha", false, mocha_palette, true);
pub const constellation_mocha_256: Theme = build("constellation-mocha", false, mocha_palette, false);
pub const constellation_latte_truecolor: Theme = build("constellation-latte", true, latte_palette, true);
pub const constellation_latte_256: Theme = build("constellation-latte", true, latte_palette, false);

/// The Constellation theme for the terminal's light/dark mode and color
/// capability.
pub fn builtinFor(light: bool, truecolor: bool) Theme {
    if (light) return if (truecolor) constellation_latte_truecolor else constellation_latte_256;
    return if (truecolor) constellation_mocha_truecolor else constellation_mocha_256;
}

/// Resolves an explicit built-in theme name (case-insensitive). The variant is
/// fixed by the name: `mocha` is always dark and `latte` always light. The
/// generic `constellation` / `catppuccin` names are not handled here because
/// they follow the terminal; see `resolveNamed`. Returns null for any other
/// name.
pub fn resolveBuiltinNamed(name: []const u8, truecolor: bool) ?Theme {
    if (matchesAny(name, &.{ "constellation-mocha", "catppuccin-mocha", "mocha" })) return builtinFor(false, truecolor);
    if (matchesAny(name, &.{ "constellation-latte", "catppuccin-latte", "latte" })) return builtinFor(true, truecolor);
    if (std.ascii.eqlIgnoreCase(name, "fx-dark")) return shared_theme.fx_dark;
    if (std.ascii.eqlIgnoreCase(name, "fx-light")) return shared_theme.fx_light;
    return null;
}

/// True for the generic names that follow the terminal's light/dark mode.
pub fn isGenericName(name: []const u8) bool {
    return matchesAny(name, &.{ "constellation", "catppuccin" });
}

/// Resolves any built-in Constellation name for the terminal's mode: explicit
/// variant names keep their variant, and the generic `constellation` /
/// `catppuccin` names pick Mocha or Latte from `terminal_light`.
pub fn resolveNamed(name: []const u8, terminal_light: bool, truecolor: bool) ?Theme {
    if (isGenericName(name)) return builtinFor(terminal_light, truecolor);
    return resolveBuiltinNamed(name, truecolor);
}

fn matchesAny(name: []const u8, comptime candidates: []const []const u8) bool {
    inline for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

// --- Tests ---

const all_variants = [_]Theme{
    constellation_mocha_truecolor,
    constellation_mocha_256,
    constellation_latte_truecolor,
    constellation_latte_256,
};

fn expectValidSgr(escape: []const u8) !void {
    try std.testing.expect(escape.len >= 4);
    try std.testing.expect(std.mem.startsWith(u8, escape, "\x1b["));
    try std.testing.expect(escape[escape.len - 1] == 'm');
    // Every escape is a run of well-formed SGR sequences.
    var rest = escape;
    while (rest.len > 0) {
        try std.testing.expect(std.mem.startsWith(u8, rest, "\x1b["));
        const end = std.mem.findScalar(u8, rest, 'm') orelse return error.TestUnexpectedResult;
        for (rest[2..end]) |byte| {
            try std.testing.expect(std.ascii.isDigit(byte) or byte == ';');
        }
        rest = rest[end + 1 ..];
    }
}

test "constellation.theme every slot is a populated SGR escape in every variant" {
    for (all_variants) |theme| {
        try std.testing.expect(theme.name.len > 0);
        for (0..shared_theme.style_slot_count) |index| {
            const slot = shared_theme.styleSlot(theme, index);
            try std.testing.expect(slot.len > 0);
            try expectValidSgr(slot);
            // Foreground-only opens must stay restorable after a wrap; the
            // composite background slots are exempt like fx's own.
            if (!shared_theme.sgrHasParam(slot, "48")) {
                try std.testing.expect(slot.len <= shared_theme.max_restorable_open_bytes);
            }
        }
        try std.testing.expect(theme.syntax.enabled);
    }
}

test "constellation.theme names and light flags" {
    try std.testing.expectEqualStrings("constellation-mocha", constellation_mocha_truecolor.name);
    try std.testing.expectEqualStrings("constellation-mocha", constellation_mocha_256.name);
    try std.testing.expectEqualStrings("constellation-latte", constellation_latte_truecolor.name);
    try std.testing.expectEqualStrings("constellation-latte", constellation_latte_256.name);
    try std.testing.expect(!constellation_mocha_truecolor.light);
    try std.testing.expect(!constellation_mocha_256.light);
    try std.testing.expect(constellation_latte_truecolor.light);
    try std.testing.expect(constellation_latte_256.light);
}

test "constellation.theme mocha truecolor carries the design schema colors" {
    const t = constellation_mocha_truecolor;
    // Blue primary accent.
    try std.testing.expectEqualStrings("\x1b[38;2;137;180;250m", t.user_card_marker_style);
    try std.testing.expectEqualStrings("\x1b[1;38;2;137;180;250m", t.subtitle_style);
    try std.testing.expectEqualStrings("\x1b[1;38;2;137;180;250m", t.selected_completion_style);
    // Active approval button: Blue background, bold Crust foreground.
    try std.testing.expectEqualStrings("\x1b[48;2;137;180;250m\x1b[38;2;17;17;27m\x1b[1m", t.approval_button_active_style);
    // Inactive approval button: Text on Surface0.
    try std.testing.expectEqualStrings("\x1b[48;2;49;50;68m\x1b[38;2;205;214;244m", t.approval_button_inactive_style);
    // Lavender.
    try std.testing.expectEqualStrings("\x1b[1;38;2;180;190;254m", t.tag_style);
    try std.testing.expectEqualStrings("\x1b[1;38;2;180;190;254m", t.system_notice_label_style);
    try std.testing.expectEqualStrings("\x1b[38;2;180;190;254m", t.user_card_accent_style);
    try std.testing.expectEqualStrings("\x1b[38;2;180;190;254m", t.syntax.variable_style);
    // Peach.
    try std.testing.expectEqualStrings("\x1b[38;2;250;179;135m", t.warning_style);
    try std.testing.expectEqualStrings("\x1b[38;2;250;179;135m", t.tool_stderr_style);
    try std.testing.expectEqualStrings("\x1b[38;2;250;179;135m", t.permission_auto_style);
    try std.testing.expectEqualStrings("\x1b[38;2;250;179;135m", t.syntax.number_style);
    // Green, Red.
    try std.testing.expectEqualStrings("\x1b[38;2;166;227;161m", t.green_style);
    try std.testing.expectEqualStrings("\x1b[38;2;166;227;161m", t.diff_added_style);
    try std.testing.expectEqualStrings("\x1b[38;2;166;227;161m", t.task_completed_open);
    try std.testing.expectEqualStrings("\x1b[38;2;166;227;161m", t.syntax.string_style);
    try std.testing.expectEqualStrings("\x1b[38;2;243;139;168m", t.red_style);
    try std.testing.expectEqualStrings("\x1b[38;2;243;139;168m", t.diff_removed_style);
    // Mauve, Teal, Sapphire, Sky.
    try std.testing.expectEqualStrings("\x1b[38;2;203;166;247m", t.syntax.keyword_style);
    try std.testing.expectEqualStrings("\x1b[38;2;148;226;213m", t.inline_code_open);
    try std.testing.expectEqualStrings("\x1b[38;2;116;199;236m", t.link_style);
    try std.testing.expectEqualStrings("\x1b[38;2;137;220;235m", t.syntax.operator_style);
}

test "constellation.theme 256-color variants use palette indexes and truecolor variants do not" {
    for ([_]Theme{ constellation_mocha_256, constellation_latte_256 }) |theme| {
        try std.testing.expect(std.mem.find(u8, theme.user_card_marker_style, "38;5;") != null);
        try std.testing.expect(std.mem.find(u8, theme.user_card_marker_style, "38;2;") == null);
        try std.testing.expect(std.mem.find(u8, theme.approval_button_active_style, "48;5;") != null);
        try std.testing.expect(std.mem.find(u8, theme.syntax.keyword_style, "38;5;") != null);
        // Marker slots keep both capability variants.
        try std.testing.expect(std.mem.find(u8, theme.diff_added_marker_truecolor, "38;2;") != null);
        try std.testing.expect(std.mem.find(u8, theme.diff_added_marker_fallback, "38;5;") != null);
        try std.testing.expect(std.mem.find(u8, theme.diff_removed_marker_truecolor, "38;2;") != null);
        try std.testing.expect(std.mem.find(u8, theme.diff_removed_marker_fallback, "38;5;") != null);
    }
    for ([_]Theme{ constellation_mocha_truecolor, constellation_latte_truecolor }) |theme| {
        try std.testing.expect(std.mem.find(u8, theme.user_card_marker_style, "38;2;") != null);
        try std.testing.expect(std.mem.find(u8, theme.user_card_marker_style, "38;5;") == null);
        try std.testing.expect(std.mem.find(u8, theme.approval_button_active_style, "48;2;") != null);
    }
    try std.testing.expectEqualStrings("\x1b[38;5;111m", constellation_mocha_256.user_card_marker_style);
    try std.testing.expectEqualStrings("\x1b[48;5;111m\x1b[38;5;233m\x1b[1m", constellation_mocha_256.approval_button_active_style);
}

test "constellation.theme mocha and latte differ and share one slot-sharing structure" {
    // Slots that share an escape in Mocha must share one in Latte (and the
    // reverse), so a live light/dark flip retints every slot consistently.
    const pairs = [_][2]Theme{
        .{ constellation_mocha_truecolor, constellation_latte_truecolor },
        .{ constellation_mocha_256, constellation_latte_256 },
    };
    for (pairs) |pair| {
        var differing: usize = 0;
        for (0..shared_theme.style_slot_count) |i| {
            if (!std.mem.eql(u8, shared_theme.styleSlot(pair[0], i), shared_theme.styleSlot(pair[1], i))) differing += 1;
            for (i + 1..shared_theme.style_slot_count) |j| {
                const dark_same = std.mem.eql(u8, shared_theme.styleSlot(pair[0], i), shared_theme.styleSlot(pair[0], j));
                const light_same = std.mem.eql(u8, shared_theme.styleSlot(pair[1], i), shared_theme.styleSlot(pair[1], j));
                try std.testing.expectEqual(dark_same, light_same);
            }
        }
        // Only the diff marker truecolor/fallback slots may coincide.
        try std.testing.expect(differing >= shared_theme.style_slot_count - 4);
    }
}

test "constellation.theme builtinFor selects by light and truecolor" {
    try std.testing.expectEqualStrings(constellation_mocha_truecolor.user_card_marker_style, builtinFor(false, true).user_card_marker_style);
    try std.testing.expect(!builtinFor(false, true).light);
    try std.testing.expectEqualStrings(constellation_mocha_256.user_card_marker_style, builtinFor(false, false).user_card_marker_style);
    try std.testing.expect(builtinFor(true, true).light);
    try std.testing.expectEqualStrings("constellation-latte", builtinFor(true, true).name);
    try std.testing.expectEqualStrings(constellation_latte_256.user_card_marker_style, builtinFor(true, false).user_card_marker_style);
    try std.testing.expectEqualStrings("constellation-mocha", builtinFor(false, false).name);
}

test "constellation.theme resolveBuiltinNamed recognizes every alias case-insensitively" {
    for ([_][]const u8{ "constellation-mocha", "catppuccin-mocha", "mocha", "Constellation-Mocha", "CATPPUCCIN-MOCHA", "MoCha" }) |name| {
        const theme = resolveBuiltinNamed(name, true) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!theme.light);
        try std.testing.expectEqualStrings("constellation-mocha", theme.name);
    }
    for ([_][]const u8{ "constellation-latte", "catppuccin-latte", "latte", "Constellation-Latte", "CATPPUCCIN-LATTE", "LATTE" }) |name| {
        const theme = resolveBuiltinNamed(name, false) orelse return error.TestUnexpectedResult;
        try std.testing.expect(theme.light);
        try std.testing.expectEqualStrings("constellation-latte", theme.name);
        try std.testing.expect(std.mem.find(u8, theme.user_card_marker_style, "38;5;") != null);
    }
    const dark = resolveBuiltinNamed("FX-Dark", true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(shared_theme.fx_dark.name, dark.name);
    try std.testing.expectEqualStrings(shared_theme.fx_dark.hint_style, dark.hint_style);
    const light = resolveBuiltinNamed("fx-light", true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(shared_theme.fx_light.name, light.name);
    try std.testing.expect(light.light);
}

test "constellation.theme resolveBuiltinNamed rejects unknown and generic names" {
    try std.testing.expect(resolveBuiltinNamed("", true) == null);
    try std.testing.expect(resolveBuiltinNamed("github-dark", true) == null);
    try std.testing.expect(resolveBuiltinNamed("mocha-extra", true) == null);
    // Generic names follow the terminal, so they resolve through resolveNamed.
    try std.testing.expect(resolveBuiltinNamed("constellation", true) == null);
    try std.testing.expect(resolveBuiltinNamed("catppuccin", true) == null);
}

test "constellation.theme generic names follow the terminal while explicit names do not" {
    for ([_][]const u8{ "constellation", "Catppuccin", "CONSTELLATION" }) |name| {
        const dark = resolveNamed(name, false, true) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("constellation-mocha", dark.name);
        const light = resolveNamed(name, true, true) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("constellation-latte", light.name);
    }
    // An explicit variant name wins over the terminal's mode.
    const mocha = resolveNamed("constellation-mocha", true, true) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!mocha.light);
    const latte = resolveNamed("latte", false, true) orelse return error.TestUnexpectedResult;
    try std.testing.expect(latte.light);
    try std.testing.expect(resolveNamed("not-a-builtin", false, true) == null);
}
