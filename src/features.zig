const std = @import("std");

const main = @import("main");
const featuresList = @import("features/index.zig");
const ZonElement = @import("zon.zig").ZonElement;

var registeredBlockFeatures: std.ArrayList(BlockFeatureFactory) = undefined;

pub const FeatureId = u32;
const TypeId = u64;

fn allocAlignedSlice(allocator: std.mem.Allocator, alignment: usize, len: usize) ![]u8 {
	const ptr = allocator.rawAlloc(len, std.mem.Alignment.fromByteUnits(alignment), @returnAddress()) 
		orelse unreachable; // out of memory
	return ptr[0..len];
}

pub fn init() void {
	registeredBlockFeatures = .init(main.globalAllocator.allocator);

	inline for (@typeInfo(featuresList).@"struct".decls) |decl| {
		@field(featuresList, decl.name).initFeature();
	}
}

pub fn OnUnloadAssets() void {
	inline for (@typeInfo(featuresList).@"struct".decls) |decl| {
		@field(featuresList, decl.name).OnUnloadAssets();
	}
}

pub fn deinit() void {
	inline for (@typeInfo(featuresList).@"struct".decls) |decl| {
		@field(featuresList, decl.name).deinitFeature();
	}

	registeredBlockFeatures.clearAndFree();
}

const FeatureTypeData = struct {
	const Self = @This();

	var numFeatureClasses: FeatureId = 0;

	id: FeatureId,
	name: []const u8,
	dependancy: [][]const u8,

	implSize: usize,
	implAlign: usize,
	implTypeName: []const u8,

	fn init(comptime inFeatureName: []const u8, comptime ImplType: type) Self {
		const newInstance = Self{
			.id = numFeatureClasses,
			.name = inFeatureName,
			.dependancy = undefined,
			.implSize = @sizeOf(ImplType),
			.implAlign = @alignOf(ImplType),
			.implTypeName = comptime @typeName(ImplType),
		};

		numFeatureClasses += 1;

		return newInstance;
	}

	fn getImplOffset(self: *const Self) usize {
		return std.mem.alignForward(usize, @sizeOf(Feature), self.implAlign);
	}
	
	fn getTotalSize(self: *const Self) usize {
		return self.getImplOffset() + self.implSize;
	}

	fn getMaxAlign(self: *const Self) usize {
		return @max(@alignOf(Feature), self.implAlign);
	}

	fn alloc(self: *const Self, allocator: std.mem.Allocator) !*Feature {
		const totalSize = self.getTotalSize();
		const mem = try allocAlignedSlice(allocator, self.getMaxAlign(), totalSize);
		
		const feature: *Feature = @ptrCast(@alignCast(mem.ptr));
		feature.runtimetypeInfo = self;
		
		@memset(mem[self.getImplOffset()..totalSize], 0);

		return feature;
	}

	pub fn initInPlace(self: *const Self, mem: [*]u8) *Feature {
		const feature: *Feature = @ptrCast(@alignCast(mem));
		feature.runtimetypeInfo = self;
		
		const implOffset = self.getImplOffset();
		const totalSize = self.getTotalSize();
		@memset(mem[implOffset..totalSize], 0);

		return feature;
	}
};

pub const Feature = struct {
	const Self = @This();
	
	runtimetypeInfo: *const FeatureTypeData,
	
	pub fn cast(self: *Self, comptime ImplType: type) *ImplType {
		if (!std.mem.eql(u8, self.runtimetypeInfo.implTypeName, @typeName(ImplType))) {
			@branchHint(.cold);

			std.debug.panic("Cannot cast feature '{s}' from type '{s}' to type '{s}'", .{
				self.runtimetypeInfo.name,
				self.runtimetypeInfo.implTypeName,
				@typeName(ImplType),
			});
		}
		
		const implOffset = std.mem.alignForward(usize, @sizeOf(Feature), @alignOf(ImplType));
		const mem: [*]u8 = @ptrCast(self);
		return @ptrCast(@alignCast(mem + implOffset));
	}
};

pub const FeatureListBase = struct {
	const Self = @This();
	
	allocator: std.mem.Allocator,
	memory: ?[]u8,
	totalSize: usize,
	capacity: usize,
	featureCount: usize,
	storageAlignment: usize,
	
	pub fn init(allocator: std.mem.Allocator) Self {
		return .{
			.allocator = allocator,
			.memory = null,
			.totalSize = 0,
			.capacity = 0,
			.featureCount = 0,
			.storageAlignment = @alignOf(Feature),
		};
	}
	
	pub fn deinit(self: *Self) void {
		if (self.memory) |mem| {
			self.allocator.free(mem);
			self.memory = null;
		}
		self.totalSize = 0;
		self.capacity = 0;
		self.featureCount = 0;
		self.storageAlignment = @alignOf(Feature);
	}
	
	fn appendFeature(self: *Self, featureFactory: *const BlockFeatureFactory) *Feature {
		const featureSize = featureFactory.typeData.getTotalSize();
		const featureAlign = featureFactory.typeData.getMaxAlign();
		const newAlignment = @max(self.storageAlignment, featureAlign);
		
		const alignedOffset = std.mem.alignForward(usize, self.totalSize, featureAlign);
		const requiredSize = alignedOffset + featureSize;

		const needsRealloc = self.memory == null or 
			requiredSize > self.capacity or 
			newAlignment > self.storageAlignment;
		
		if (needsRealloc) {
			const newCapacity = requiredSize * 2;
			const newMem = allocAlignedSlice(self.allocator, newAlignment, newCapacity) catch unreachable;
			
			if (self.memory) |oldMem| {
				@memcpy(newMem[0..self.totalSize], oldMem[0..self.totalSize]);
				self.allocator.free(oldMem);
			}
			
			self.memory = newMem;
			self.capacity = newCapacity;
			self.storageAlignment = newAlignment;
		}

		const featurePtr = featureFactory.typeData.initInPlace(self.memory.?.ptr + alignedOffset);
		
		self.totalSize = requiredSize;
		self.featureCount += 1;
		
		return featurePtr;
	}
	
	pub fn find(self: *Self, comptime FeatureType: type) ?*FeatureType {
		if (self.memory == null or self.featureCount == 0) return null;
		const targetTypeName = @typeName(FeatureType);
		
		var currentOffset: usize = 0;
		var index: usize = 0;
		
		while (index < self.featureCount) {
			const feature: *Feature = @ptrCast(@alignCast(self.memory.?.ptr + currentOffset));

			if (std.mem.eql(u8, feature.runtimetypeInfo.implTypeName, targetTypeName)) {
				return feature.cast(FeatureType);
			}
			
			const typeData = feature.runtimetypeInfo;
			const featureSize = typeData.getTotalSize();
			const featureAlign = typeData.getMaxAlign();
			currentOffset = std.mem.alignForward(usize, currentOffset + featureSize, featureAlign);
			index += 1;
		}
		
		return null;
	}

	pub inline fn forEach(self: *Self, bodyFn: anytype) void {
		if (self.memory == null or self.featureCount == 0) return;

		var currentOffset: usize = 0;
		var index: usize = 0;

		while (index < self.featureCount) {
			const feature: *Feature = @ptrCast(@alignCast(self.memory.?.ptr + currentOffset));

			if (bodyFn(feature)) return;

			const typeData = feature.runtimetypeInfo;
			const featureSize = typeData.getTotalSize();
			const featureAlign = typeData.getMaxAlign();
			currentOffset = std.mem.alignForward(usize, currentOffset + featureSize, featureAlign);
			index += 1;
		}
	}
};

pub const BlockFeatureFactory = struct {
	const Self = @This();
	const RegisterBlockFn = *const fn(feature: *Feature, blockId: u16, zon: ZonElement) void;
	const VTable = struct {
		registerBlock: RegisterBlockFn,
	};

	typeData: FeatureTypeData = undefined,
	vtable: VTable = undefined,

	pub inline fn init(comptime inFeatureName: []const u8, comptime ImplType: type, inRegisterFn: RegisterBlockFn) Self {
		return Self{
			.vtable = .{ 
				.registerBlock = inRegisterFn,
			},
			.typeData = .init(inFeatureName, ImplType),
		};
	}

	fn new(self: *Self, allocator: std.mem.Allocator, blockId: u16, zon: ZonElement) *Feature {
		const feature = self.typeData.alloc(allocator) catch unreachable;
		self.vtable.registerBlock(feature, blockId, zon);
		return feature;
	}

	pub fn newInPlace(self: *const Self, memory: [*]u8, blockId: u16, zon: ZonElement) *Feature {
		const feature = self.typeData.initInPlace(memory);
		self.vtable.registerBlock(feature, blockId, zon);
		return feature;
	}
	
	fn free(feature: *Feature, allocator: std.mem.Allocator) void {
		const totalSize = feature.runtimetypeInfo.getTotalSize();
		const mem: [*]u8 = @ptrCast(feature);
		allocator.free(mem[0..totalSize]);
	}
};

pub const BlockFeatureList = struct {
	const Self = @This();
	
	base: FeatureListBase,
	
	pub fn init(allocator: std.mem.Allocator) Self {
		return .{
			.base = FeatureListBase.init(allocator),
		};
	}
	
	pub fn deinit(self: *Self) void {
		self.base.deinit();
	}
	
	pub fn registerBlock(self: *Self, featureFactory: *const BlockFeatureFactory, blockId: u16, zon: ZonElement) *Feature {
		const feature = self.base.appendFeature(featureFactory);
		featureFactory.vtable.registerBlock(feature, blockId, zon);
		return feature;
	}
	
	pub fn find(self: *Self, comptime FeatureType: type) ?*FeatureType {
		return self.base.find(FeatureType);
	}

	pub inline fn forEach(self: *Self, bodyFn: anytype) void {
		self.base.forEach(bodyFn);
	}
};

pub fn registerBlockFeature(featureClass: BlockFeatureFactory) FeatureId {
	registeredBlockFeatures.append(featureClass) catch unreachable;
	return featureClass.typeData.id;
}

pub fn getRegisteredBlockFeatures() []BlockFeatureFactory {
	return registeredBlockFeatures.items;
}