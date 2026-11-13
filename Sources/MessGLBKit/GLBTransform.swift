import simd

struct GLBTransform
{
    let position: simd_double4x4
    let normal: simd_double3x3
    let reversesWinding: Bool

    init(_ matrix: simd_double4x4) throws
    {
        let linear = simd_double3x3(columns: (
            SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        ))
        let determinant = simd_determinant(linear)
        guard determinant.isFinite, abs(determinant) > 1e-12,
              matrix.columns.0.w == 0, matrix.columns.1.w == 0,
              matrix.columns.2.w == 0, matrix.columns.3.w == 1
        else { throw GLBImportError.invalidContent("A GLB transform is singular or non-affine.") }
        position = matrix
        normal = simd_transpose(simd_inverse(linear))
        reversesWinding = determinant < 0
    }
}
