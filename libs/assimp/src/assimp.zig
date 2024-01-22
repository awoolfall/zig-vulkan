const c = @cImport({
    @cInclude("assimp/cimport.h");
});

pub const aiBool = c.aiBool;
pub const AI_FALSE: aiBool = 0;
pub const AI_TRUE: aiBool = 1;

pub const aiScene = opaque {};

pub inline fn aiImportFile(pFile: [*:0]const u8, pFlags: u32) *const aiScene {
    return @ptrCast(c.aiImportFile(pFile, pFlags));
}
