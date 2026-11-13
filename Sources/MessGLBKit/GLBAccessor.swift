import Foundation
import GLTFKit2
import simd

enum GLBAccessor
{
    static func readFloats(
        accessor: GLTFAccessor,
        dimension: GLTFValueDimension,
        componentCount: Int,
        maximumCount: Int
    ) throws -> [Float]
    {
        guard accessor.dimension == dimension, accessor.count > 0, accessor.count <= maximumCount
        else { throw GLBImportError.invalidContent("Vertex accessor shape or count is invalid.") }
        try validateBuffer(accessor: accessor, componentCount: componentCount)
        let packed = GLTFPackedDataForAccessor(accessor)
        guard packed.count == accessor.count * componentCount * Int(GLTFBytesPerComponentForComponentType(accessor.componentType))
        else { throw GLBImportError.invalidContent("Vertex accessor payload is truncated.") }
        let floats = GLTFTransformPackedDataToFloat(packed, accessor)
        guard floats.count == accessor.count * componentCount * MemoryLayout<Float>.size
        else { throw GLBImportError.invalidContent("Vertex accessor payload is truncated.") }
        let values = floats.withUnsafeBytes
        { bytes in
            (0 ..< accessor.count * componentCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard values.allSatisfy(\.isFinite)
        else { throw GLBImportError.invalidContent("Vertex attributes contain non-finite values.") }
        return values
    }

    static func readFloat32(_ accessor: GLTFAccessor, dimension: GLTFValueDimension, componentCount: Int, maximumCount: Int) throws -> [Float]
    {
        guard accessor.componentType == .float, !accessor.isNormalized
        else { throw GLBImportError.invalidContent("A GLB float accessor has an invalid layout.") }
        return try readFloats(accessor: accessor, dimension: dimension, componentCount: componentCount, maximumCount: maximumCount)
    }

    static func readInverseBinds(_ accessor: GLTFAccessor?, jointCount: Int, maximumCount: Int) throws -> [simd_double4x4]
    {
        guard let accessor else { return Array(repeating: matrix_identity_double4x4, count: jointCount) }
        guard accessor.count >= jointCount else { throw GLBImportError.invalidContent("GLB inverse bind accessor is too short.") }
        let values = try readFloat32(accessor, dimension: .matrix4, componentCount: 16, maximumCount: maximumCount)
        var matrices: [simd_double4x4] = []
        matrices.reserveCapacity(jointCount)
        for index in 0 ..< jointCount
        {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let offset = index * 16
            guard values[offset + 3] == 0, values[offset + 7] == 0,
                  values[offset + 11] == 0, values[offset + 15] == 1
            else { throw GLBImportError.invalidContent("GLB inverse bind matrix is not affine.") }
            let matrix = simd_double4x4(
                SIMD4<Double>(Double(values[offset]), Double(values[offset + 1]), Double(values[offset + 2]), 0),
                SIMD4<Double>(Double(values[offset + 4]), Double(values[offset + 5]), Double(values[offset + 6]), 0),
                SIMD4<Double>(Double(values[offset + 8]), Double(values[offset + 9]), Double(values[offset + 10]), 0),
                SIMD4<Double>(Double(values[offset + 12]), Double(values[offset + 13]), Double(values[offset + 14]), 1)
            )
            matrices.append(matrix)
        }
        return matrices
    }

    static func readIndices(
        accessor: GLTFAccessor,
        vertexCount: Int,
        maximumCount: Int
    ) throws -> [UInt32]
    {
        guard accessor.dimension == .scalar, !accessor.isNormalized,
              accessor.count > 0, accessor.count <= maximumCount
        else { throw GLBImportError.invalidContent("Triangle index accessor is invalid.") }
        try validateBuffer(accessor: accessor, componentCount: 1)
        let packed = GLTFPackedDataForAccessor(accessor)
        guard packed.count == accessor.count * Int(GLTFBytesPerComponentForComponentType(accessor.componentType))
        else { throw GLBImportError.invalidContent("Triangle index payload is truncated.") }
        let indices: [UInt32] = try packed.withUnsafeBytes
        { bytes in
            switch accessor.componentType
            {
                case .unsignedByte: (0 ..< accessor.count).map { UInt32(bytes[$0]) }
                case .unsignedShort: (0 ..< accessor.count).map { UInt32(bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self).littleEndian) }
                case .unsignedInt: (0 ..< accessor.count).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
                default: throw GLBImportError.invalidContent("Indices must use an unsigned integer component type.")
            }
        }
        guard indices.allSatisfy({ $0 < vertexCount })
        else { throw GLBImportError.invalidContent("Triangle index is outside the vertex array.") }
        return indices
    }

    private static func validateBuffer(
        accessor: GLTFAccessor,
        componentCount: Int
    ) throws
    {
        guard accessor.sparse == nil
        else { throw GLBImportError.unsupportedContent("Sparse accessors are not supported by the initial adapter.") }
        guard let view = accessor.bufferView, let data = view.buffer.data,
              accessor.offset >= 0, view.offset >= 0, view.length >= 0,
              view.offset <= data.count, view.length <= data.count - view.offset
        else { throw GLBImportError.invalidContent("Accessor buffer range is invalid.") }
        let componentSize: Int
        switch accessor.componentType
        {
            case .byte, .unsignedByte: componentSize = 1
            case .short, .unsignedShort: componentSize = 2
            case .unsignedInt, .float: componentSize = 4
            default: throw GLBImportError.invalidContent("Unknown accessor component type.")
        }
        let elementSize = componentCount * componentSize
        let stride = view.stride == 0 ? elementSize : view.stride
        guard stride >= elementSize, accessor.offset <= view.length,
              elementSize <= view.length - accessor.offset,
              accessor.count - 1 <= (view.length - accessor.offset - elementSize) / stride
        else { throw GLBImportError.invalidContent("Accessor exceeds its buffer view.") }
    }
}
