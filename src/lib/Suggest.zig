//! String suggestion helpers used for typo hints.

const std = @import("std");

/// Returns the closest candidate to `needle` using Levenshtein distance.
pub fn closest(needle: []const u8, candidates: []const []const u8) ?[]const u8 {
    if (needle.len == 0 or candidates.len == 0) return null;

    var best: ?[]const u8 = null;
    var best_score: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        const score = levenshtein(needle, candidate);
        if (score < best_score) {
            best_score = score;
            best = candidate;
        }
    }

    if (best) |_| {
        const threshold = if (needle.len <= 4) @as(usize, 1) else @max(@as(usize, 2), needle.len / 3);
        if (best_score <= threshold) return best;
    }
    return null;
}

/// Computes Levenshtein edit distance between two ASCII strings.
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    const alloc = std.heap.page_allocator;
    var prev = std.ArrayList(usize).initCapacity(alloc, b.len + 1) catch return std.math.maxInt(usize);
    defer prev.deinit(alloc);
    var curr = std.ArrayList(usize).initCapacity(alloc, b.len + 1) catch return std.math.maxInt(usize);
    defer curr.deinit(alloc);

    prev.append(alloc, 0) catch return std.math.maxInt(usize);
    var j: usize = 0;
    while (j < b.len) : (j += 1) {
        prev.append(alloc, j + 1) catch return std.math.maxInt(usize);
    }

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        curr.clearRetainingCapacity();
        curr.append(alloc, i + 1) catch return std.math.maxInt(usize);
        j = 0;
        while (j < b.len) : (j += 1) {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            const deletion = prev.items[j + 1] + 1;
            const insertion = curr.items[j] + 1;
            const substitution = prev.items[j] + cost;
            const next = @min(@min(deletion, insertion), substitution);
            curr.append(alloc, next) catch return std.math.maxInt(usize);
        }

        const tmp = prev;
        prev = curr;
        curr = tmp;
    }
    return prev.items[b.len];
}
