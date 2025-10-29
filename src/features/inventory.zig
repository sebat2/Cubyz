const std = @import("std");

const main = @import("main");
const Blocks = @import("../blocks.zig");
const ZonElement = @import("../zon.zig");

const Id = Blocks.registerFeature(Blocks.FeatureClass.init("Inventory", Feature, constructor));

pub fn init() void {

}

pub fn deinit() void {

}

pub fn reset() void {

}

fn constructor(class: *Blocks.FeatureClass, instance: *Blocks.Feature, blockId: u16, zon: ZonElement) void {
    _ = class;
    _ = blockId;
    const feature = instance.cast(Feature);

    feature.inventorySize = zon.get(u16, "size", 20);
}

const Feature = struct {
    inventorySize: u16,
};