
pub fn AssetId(comptime AssetType: type) type {
    return struct {
        pub const Type = AssetType;
        unique_id: u64,
    };
}
