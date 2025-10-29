const std = @import("std");

const main = @import("main");
const blockFeaturesList = @import("block_features/index.zig");
const ZonElement = @import("zon.zig").ZonElement;

pub fn init() void {
	registeredFeatures = .init(main.globalAllocator.allocator);

	inline for (@typeInfo(blockFeaturesList).@"struct".decls) |decl| {
		@field(blockFeaturesList, decl.name).initFeature();
	}
}

pub fn reset() void {
	inline for (@typeInfo(blockFeaturesList).@"struct".decls) |decl| {
		@field(blockFeaturesList, decl.name).resetFeature();
	}

	registeredFeatures.clearAndFree();
}

pub fn deinit() void {
	inline for (@typeInfo(blockFeaturesList).@"struct".decls) |decl| {
		@field(blockFeaturesList, decl.name).deinitFeature();
	}

	registeredFeatures.clearAndFree();
}

var registeredFeatures: std.ArrayList(FeatureFactory) = undefined;
pub const FeatureId = u32;
const TypeId = u64;

fn typeId(comptime T: type) TypeId {
    return comptime std.hash.Wyhash.hash(0, @typeName(T));
}

pub const FeatureFactory = struct {
	const Self = @This();
	const ConstructorFn = *const fn(feature: *Feature, blockId: u16, zon: ZonElement) void;
	const VTable = struct {
		constructor: ConstructorFn,
	};

	var numFeatureClasses: FeatureId = 0;

	Id: FeatureId,
	vtable: VTable = undefined,
	name: []const u8,
	dependancy: [][]const u8,
	implSize: usize,
	implAlign: u8,
	implTypeId: TypeId,
	implTypeName: []const u8,
	
	pub inline fn init(comptime inFeatureName: []const u8, comptime ImplType: type, inConstructor: ConstructorFn) Self {
		return blk: {
			const newInstance = Self {
				.Id = Self.numFeatureClasses,
				.vtable = .{ 
					.constructor = inConstructor
				},
				.name = inFeatureName,
				.dependancy = undefined,
				.implSize = @sizeOf(ImplType),
				.implAlign = @intCast(@alignOf(ImplType)),
				.implTypeId = comptime typeId(ImplType),
				.implTypeName = comptime @typeName(ImplType)
			};

			Self.numFeatureClasses += 1;

			break :blk newInstance;
		};
	}
	
	fn getMaxAlign(self: *const Self) usize {
		return @max(@alignOf(Feature), self.implAlign);
	}
	
	fn getImplOffset(self: *const Self) usize {
		return std.mem.alignForward(usize, @sizeOf(Feature), self.implAlign);
	}
	
	fn getTotalSize(self: *const Self) usize {
		return self.getImplOffset() + self.implSize;
	}
	
	fn initFeature(self: *const Self, feature: *Feature) void {
		feature.* = .{
			.implTypeId = self.implTypeId,
			.implSize = self.implSize,
			.implAlign = self.implAlign,
			.classId = self.Id,
		};
	}

	fn new(self: *Self, allocator: main.heap.NeverFailingAllocator, blockId: u16, zon: ZonElement) *Feature {
		const totalSize = self.getTotalSize();
		const mem = allocator.alignedAlloc(u8, self.getMaxAlign(), totalSize) catch unreachable;
		
		const feature: *Feature = @ptrCast(@alignCast(mem.ptr));
		self.initFeature(feature);
		
		@memset(mem[self.getImplOffset()..totalSize], 0);
		
		self.vtable.constructor(feature, blockId, zon);
		return feature;
	}

	fn free(feature: *Feature, allocator: main.heap.NeverFailingAllocator) void {
		const mem: [*]u8 = @ptrCast(feature);
		allocator.free(mem[0..feature.getTotalSize()]);
	}
};

pub const Feature = struct {
	const Self = @This();
	
	implTypeId: TypeId,
	implSize: usize,
	implAlign: u8,
	classId: FeatureId,

    pub fn getRegisteredFeatures() []const FeatureFactory {
        return registeredFeatures.items;
    }
	
	fn getImplOffset(self: *const Self) usize {
		return std.mem.alignForward(usize, @sizeOf(Feature), self.implAlign);
	}
	
	fn getTotalSize(self: *const Self) usize {
		return self.getImplOffset() + self.implSize;
	}
	
	fn getImplPtr(self: *Self) [*]u8 {
		const mem: [*]u8 = @ptrCast(self);
		return mem + self.getImplOffset();
	}
	
	pub fn cast(self: *Self, comptime ImplType: type) *ImplType {
		if (self.implTypeId != comptime typeId(ImplType)) {
			@branchHint(.cold);

			var featureClass: ?*FeatureFactory = null;
			for (registeredFeatures.items) |*fc| {
				if (fc.Id == self.classId) {
					featureClass = fc;
					break;
				}
			}
			
			if (featureClass) |fc| {
				std.debug.panic("Cannot cast feature '{s}' from type '{s}' to type '{s}'", .{
					fc.name,
					fc.implTypeName,
					@typeName(ImplType)
				});
			} else unreachable;
		}
		
		const implOffset = std.mem.alignForward(usize, @sizeOf(Feature), @alignOf(ImplType));
		const mem: [*]u8 = @ptrCast(self);
		return @ptrCast(@alignCast(mem + implOffset));
	}
};

pub fn registerFeature(featureClass: FeatureFactory) FeatureId {
	registeredFeatures.append(featureClass) catch unreachable;
	return featureClass.Id;
}

pub const FeatureList = struct {
	const Self = @This();
	
	allocator: main.heap.NeverFailingAllocator,
	memory: ?[*]u8,
	allocatedMemory: ?[]u8,
	totalSize: usize,
	count: usize,
	
	pub fn init(allocator: main.heap.NeverFailingAllocator) Self {
		return .{
			.memory = null,
			.allocatedMemory = null,
			.count = 0,
			.totalSize = 0,
			.allocator = allocator,
		};
	}
	
	pub fn deinit(self: *Self) void {
		if (self.memory) |mem| {
			self.allocator.free(mem[0..self.totalSize]);
			self.memory = null;
		}
		self.count = 0;
		self.totalSize = 0;
	}
	
	pub fn append(self: *Self, featureClass: *const FeatureFactory, blockId: u16, zon: ZonElement) *Feature {
		const featureBlockSize = featureClass.getTotalSize();
		const maxAlign = featureClass.getMaxAlign();
		const oldSize = self.totalSize;

		const extraPadding = maxAlign - 1;
		const allocSize = oldSize + featureBlockSize + extraPadding;
		
		const rawMemory = self.allocator.alloc(u8, allocSize);
		
		const alignedStart = std.mem.alignForward(usize, @intFromPtr(rawMemory.ptr), maxAlign);
		const aligned = rawMemory.ptr + (alignedStart - @intFromPtr(rawMemory.ptr));
		
		if (self.memory) |oldMem| {
			@memcpy(aligned[0..oldSize], oldMem[0..oldSize]);
			if (self.allocatedMemory) |oldAlloc| {
				self.allocator.free(oldAlloc);
			}
		}
		
		const newFeaturePtr: *Feature = @ptrCast(@alignCast(aligned + oldSize));
		featureClass.initFeature(newFeaturePtr);
		
		@memset(aligned[oldSize + featureClass.getImplOffset()..oldSize + featureBlockSize], 0);
		
		featureClass.vtable.constructor(newFeaturePtr, blockId, zon);
		
		self.memory = aligned;
		self.allocatedMemory = rawMemory;
		self.count += 1;
		self.totalSize = oldSize + featureBlockSize;
		
		return newFeaturePtr;
	}
	
	pub fn get(self: *Self, index: usize) ?*Feature {
		if (index >= self.count or self.memory == null) return null;
		
		var offset: usize = 0;
		var i: usize = 0;
		while (i < index) : (i += 1) {
			const feature: *Feature = @ptrCast(@alignCast(self.memory.? + offset));
			offset += feature.getTotalSize();
		}
		
		return @ptrCast(@alignCast(self.memory.? + offset));
	}
	
	pub fn find(self: *Self, featureType: type) ?*Feature {
		if (self.memory == null) return null;
		
		var offset: usize = 0;
		var i: usize = 0;
		while (i < self.count) : (i += 1) {
			const feature: *Feature = @ptrCast(@alignCast(self.memory.? + offset));
			if (feature.classId == featureType.classId) return feature;
			offset += feature.getTotalSize();
		}
		
		return null;
	}
};