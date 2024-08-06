const c = @cImport({
    @cInclude("sqlite3.h");
});

const std = @import("std");
const Allocator = std.mem.Allocator;

const Point = struct {
    lon: f32,
    lat: f32,
};

db: *c.sqlite3,

const Db = @This();

pub fn init(db_path: [:0]const u8) !Db {
    var db_opt: ?*c.sqlite3 = undefined;
    if (c.sqlite3_open(db_path, &db_opt) != c.SQLITE_OK) {
        closeDb(db_opt);
        return error.Sql;
    }

    const db = db_opt orelse unreachable;

    return .{
        .db = db,
    };
}

pub fn deinit(self: *Db) void {
    closeDb(self.db);
}


pub fn getOneTripPerRoute(self: *Db) ![]i64 {
    // FIXME: don't hard code route id :)
    const statement = try makeStatement(self.db, "SELECT trip_id FROM trips WHERE route_id = 6617", "get trip id");
    defer finalizeStatement(statement);

    const sqlite_ret = c.sqlite3_step(statement);
    if (sqlite_ret != c.SQLITE_ROW) {
        std.log.err("Failed to run add user", .{});
        return error.Sql;
    }
    const trip_id = c.sqlite3_column_int64(statement, 0);

    return trip_id;
}

const RouteInfo = struct {
    route_id: i64,
    path: []const Point,
    stop_ids: []const i64,
};

pub fn getAllStops(self: *Db, alloc: Allocator) ![]RouteInfo {
    const statement = try makeStatement(self.db, "SELECT route_id FROM routes", "get routes points");
    defer finalizeStatement(statement);

    var ret = std.ArrayList(RouteInfo).init(alloc);
    defer ret.deinit();
    while (true) {
        const sqlite_ret = c.sqlite3_step(statement);
        if (sqlite_ret == c.SQLITE_DONE) {
            break;
        }

        if (sqlite_ret != c.SQLITE_ROW) {
            return error.Invalid;
        }

        const row = c.sqlite3_column_int64(statement, 0);
        const seq = try self.getStops(alloc, row);
        try ret.append(.{
            .route_id = row,
            .path = seq.points,
            .stop_ids = seq.ids,
        });
    }

    return ret.toOwnedSlice();
}

const StopSequence = struct {
    ids: []i64,
    points: []Point,
};

pub fn getStops(self: *Db, alloc: Allocator, route_id: i64) !StopSequence {
    const statement = try makeStatement(self.db,
        \\ SELECT stops.stop_lon, stops.stop_lat, stop_times.stop_id
        \\ FROM stop_times
        \\ LEFT JOIN stops ON stop_times.stop_id == stops.stop_id
        \\ WHERE trip_id = (
        \\    SELECT trip_id from trips where route_id = ?1 LIMIT 1
        \\ )
        \\ ORDER BY cast(stop_times.stop_sequence as integer);
        , "get stop points");
    defer finalizeStatement(statement);

    try checkSqliteRet("bind route id", c.sqlite3_bind_int64(statement, 1, route_id));

    var ret_points = std.ArrayList(Point).init(alloc);
    defer ret_points.deinit();

    var ret_ids = std.ArrayList(i64).init(alloc);
    defer ret_ids.deinit();
    while (true) {
        const sqlite_ret = c.sqlite3_step(statement);
        if (sqlite_ret == c.SQLITE_DONE) {
            break;
        }

        if (sqlite_ret != c.SQLITE_ROW) {
            return error.Invalid;
        }
        const lon_s = extractColumnTextTemporary(statement, 0) orelse return error.NoLon;
        const lon = try std.fmt.parseFloat(f32, lon_s);

        const lat_s = extractColumnTextTemporary(statement, 1) orelse return error.NoLat;
        const lat = try std.fmt.parseFloat(f32, lat_s);

        const stop_id = c.sqlite3_column_int64(statement, 2);

        try ret_points.append(.{
            .lon = lon,
            .lat = lat,
        });

        try ret_ids.append(stop_id);
    }

    return .{
        .points = try ret_points.toOwnedSlice(),
        .ids = try ret_ids.toOwnedSlice(),
    };
}

fn getRoutePoints(self: *Db, alloc: Allocator) ![]Point {
    const trip_id = try self.getTripId();
    return try self.getStops(alloc, trip_id);
}

fn toSqlLen(len: usize) !c_int {
    return std.math.cast(c_int, len) orelse {
        return error.Sql;
    };
}

fn fromSqlLen(len: c_int) !usize {
    return std.math.cast(usize, len) orelse {
        return error.Sql;
    };
}

fn closeDb(db: ?*c.sqlite3) void {
    if (c.sqlite3_close(db) != c.SQLITE_OK) {
        std.log.err("Failed to close db\n", .{});
    }
}

fn makeStatement(db: *c.sqlite3, sql: [:0]const u8, purpose: []const u8) !*c.sqlite3_stmt {
    var statement: ?*c.sqlite3_stmt = null;

    const ret = c.sqlite3_prepare_v2(db, sql, try toSqlLen(sql.len + 1), &statement, null);

    if (ret != c.SQLITE_OK) {
        std.log.err("Failed to prepare {s} statement", .{purpose});
        return error.Sql;
    }
    return statement orelse unreachable;
}

fn finalizeStatement(statement: *c.sqlite3_stmt) void {
    _ = c.sqlite3_finalize(statement);
}

fn checkSqliteRet(purpose: []const u8, ret: i32) !void {
    if (ret != c.SQLITE_OK) {
        std.log.err("Failed to {s}", .{purpose});
        return error.Sql;
    }
}

fn dupeSqliteData(alloc: Allocator, item_opt: ?[*]const u8, item_len: i32) !?[]const u8 {
    const item = item_opt orelse {
        return null;
    };
    const item_clone = try alloc.dupe(u8, item[0..try fromSqlLen(item_len)]);
    return item_clone;
}


fn extractColumnTextTemporary(statement: *c.sqlite3_stmt, column_id: c_int) ?[]const u8 {
    const item_opt: ?[*]const u8 = @ptrCast(c.sqlite3_column_text(statement, column_id));
    const item_len = c.sqlite3_column_bytes(statement, column_id);
    if (item_opt == null) {
        return null;
    }
    return item_opt.?[0..@intCast(item_len)];
}

fn extractColumnBlob(alloc: Allocator, statement: *c.sqlite3_stmt, column_id: c_int) !?[]const u8 {
    const item_opt: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(statement, column_id));
    const item_len = c.sqlite3_column_bytes(statement, column_id);
    return dupeSqliteData(alloc, item_opt, item_len);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();
    var db = try Db.init("test.db");
    const points = try db.getAllStops(alloc);
    std.debug.print("points: {any}", .{points});
}
