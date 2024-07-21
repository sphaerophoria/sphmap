pub const Point = struct {
    x: f32,
    y: f32,

    pub fn add(self: Point, other: Vec) Point {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
        };
    }

    pub fn sub(self: Point, other: Point) Vec {
        return .{
            .x = self.x - other.x,
            .y = self.y - other.y,
        };
    }
};

pub const Vec = struct {
    x: f32,
    y: f32,

    pub fn dot(self: Vec, other: Vec) f32 {
        return self.x * other.x + self.y * other.y;
    }

    pub fn cross(self: Vec, other: Vec) f32 {
        return self.x * other.y - self.y * other.x;
    }

    pub fn mul(self: Vec, val: f32) Vec {
        return .{
            .x = self.x * val,
            .y = self.y * val,
        };
    }

    pub fn normalized(self: Vec) Vec {
        const vec_len = self.length();
        return .{
            .x = self.x / vec_len,
            .y = self.y / vec_len,
        };
    }

    pub fn length(self: Vec) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn normal(self: Vec) Vec {
        const len = self.length();
        return .{
            .x = self.y / len,
            .y = -self.x / len,
        };
    }
};

pub fn closestPointOnLine(p: Point, a: Point, b: Point) Point {
    const ab = b.sub(a);
    const ab_len = ab.length();
    const ab_norm = ab.mul(1.0 / ab_len);
    const ap = p.sub(a);

    const dot = ap.dot(ab_norm);
    if (dot < 0) {
        return a;
    }

    if (dot > ab_len) {
        return b;
    }

    const cross = ap.cross(ab);
    const dist = cross / ab_len;
    const norm = ab.normal().mul(-1.0);
    return p.add(norm.mul(dist));
}
