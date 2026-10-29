const std = @import("std");
const helpers = @import("helpers.zig");

const corpus = "differential/corpus.mjs";

fn exitedOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Splits on `\n` and ignores the empty piece a trailing newline produces.
fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        // Drop the empty piece produced by a trailing newline only.
        if (it.peek() == null and line.len == 0) continue;
        try lines.append(allocator, line);
    }
    return lines.toOwnedSlice(allocator);
}

const DiffLine = struct {
    prefix: u8,
    text: []const u8,
    /// 1-based line numbers in node and jsz before this line is applied.
    old: usize,
    new: usize,
};

fn countLines(lines: []const DiffLine, comptime is_old: bool) usize {
    var count: usize = 0;
    for (lines) |line| {
        if (is_old) {
            if (line.prefix != '+') count += 1;
        } else if (line.prefix != '-') {
            count += 1;
        }
    }
    return count;
}

/// Prints an LCS-based unified diff so a mismatch is readable in the test log.
fn printDiff(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) !void {
    const expected_lines = try splitLines(allocator, expected);
    defer allocator.free(expected_lines);
    const actual_lines = try splitLines(allocator, actual);
    defer allocator.free(actual_lines);

    const width = actual_lines.len + 1;
    const cells = try allocator.alloc(usize, (expected_lines.len + 1) * width);
    defer allocator.free(cells);
    @memset(cells, 0);

    var i = expected_lines.len;
    while (i > 0) {
        i -= 1;
        var j = actual_lines.len;
        while (j > 0) {
            j -= 1;
            cells[i * width + j] = if (std.mem.eql(u8, expected_lines[i], actual_lines[j]))
                cells[(i + 1) * width + j + 1] + 1
            else
                @max(cells[(i + 1) * width + j], cells[i * width + j + 1]);
        }
    }

    var ops: std.ArrayList(DiffLine) = .empty;
    defer ops.deinit(allocator);
    var old_line: usize = 1;
    var new_line: usize = 1;
    i = 0;
    var j: usize = 0;
    while (i < expected_lines.len or j < actual_lines.len) {
        const same = i < expected_lines.len and j < actual_lines.len and
            std.mem.eql(u8, expected_lines[i], actual_lines[j]);
        const delete = !same and (j >= actual_lines.len or
            (i < expected_lines.len and cells[(i + 1) * width + j] >= cells[i * width + j + 1]));

        const line = DiffLine{
            .prefix = if (same) ' ' else if (delete) '-' else '+',
            .text = if (same or delete) expected_lines[i] else actual_lines[j],
            .old = old_line,
            .new = new_line,
        };
        if (same) {
            i += 1;
            j += 1;
            old_line += 1;
            new_line += 1;
        } else if (delete) {
            i += 1;
            old_line += 1;
        } else {
            j += 1;
            new_line += 1;
        }
        try ops.append(allocator, line);
    }

    var changes: std.ArrayList(usize) = .empty;
    defer changes.deinit(allocator);
    for (ops.items, 0..) |op, index| {
        if (op.prefix != ' ') try changes.append(allocator, index);
    }

    std.debug.print(
        "differential corpus mismatch\n  node: {d} lines\n  jsz:  {d} lines\n--- node\n+++ jsz\n",
        .{ expected_lines.len, actual_lines.len },
    );

    const context = 3;
    const max_printed = 200;
    var printed: usize = 0;
    var change_index: usize = 0;
    while (change_index < changes.items.len) {
        const first = changes.items[change_index];
        var last = first;
        change_index += 1;
        while (change_index < changes.items.len and
            changes.items[change_index] - last <= 2 * context + 1)
        {
            last = changes.items[change_index];
            change_index += 1;
        }

        const start = first - @min(first, context);
        const end = @min(last + context + 1, ops.items.len);
        const hunk = ops.items[start..end];
        std.debug.print("@@ -{d},{d} +{d},{d} @@\n", .{
            hunk[0].old,
            countLines(hunk, true),
            hunk[0].new,
            countLines(hunk, false),
        });
        for (hunk) |op| {
            if (printed >= max_printed) break;
            std.debug.print("{c}{s}\n", .{ op.prefix, op.text });
            printed += 1;
        }
    }
    if (printed >= max_printed) {
        std.debug.print("... diff truncated at {d} lines\n", .{max_printed});
    }
}

test "differential corpus matches node" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Offline CI has no node; probing keeps the suite green there.
    const probe = std.process.run(allocator, io, .{
        .argv = &.{ "node", "--version" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer {
        allocator.free(probe.stdout);
        allocator.free(probe.stderr);
    }
    if (!exitedOk(probe.term)) return error.SkipZigTest;

    const corpus_path = try std.fs.path.join(allocator, &.{ helpers.fixture_dir, corpus });
    defer allocator.free(corpus_path);

    const jsz_stdout = try helpers.runFixtureStdout(allocator, corpus);
    defer allocator.free(jsz_stdout);

    const node = try std.process.run(allocator, io, .{
        .argv = &.{ "node", corpus_path },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(node.stdout);
        allocator.free(node.stderr);
    }

    if (!exitedOk(node.term)) {
        std.debug.print("node failed to run {s}:\n{s}", .{ corpus_path, node.stderr });
        return error.TestUnexpectedResult;
    }

    if (!std.mem.eql(u8, jsz_stdout, node.stdout)) {
        try printDiff(allocator, node.stdout, jsz_stdout);
        return error.TestUnexpectedResult;
    }
}
