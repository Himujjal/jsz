const quickjs = @import("quickjs");

fn moduleInit(_: *quickjs.Context, _: *quickjs.ModuleDef) bool {
    return true;
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    return quickjs.ModuleDef.init(ctx, "node:_url", moduleInit);
}
