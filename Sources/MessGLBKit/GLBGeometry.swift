import Foundation

public struct GLBGeometry: Sendable
{
    public internal(set) var meshes: [GLBMesh] = []
    public internal(set) var materials: [GLBMaterial] = []
    public internal(set) var attributions: [String] = []
    public internal(set) var vertexCount = 0
    public internal(set) var omittedDegenerateTriangleCount = 0
    /// The asset's top-level extras encoded as JSON.
    public internal(set) var extras: Data?
}

public struct GLBVertex: Sendable
{
    public let position: SIMD3<Float>
    public let normal: SIMD3<Float>
    /// glTF coordinates: (0, 0) addresses the top-left of the image.
    public let textureCoordinate: SIMD2<Float>
    public let color: SIMD4<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, textureCoordinate: SIMD2<Float>, color: SIMD4<Float>)
    {
        self.position = position
        self.normal = normal
        self.textureCoordinate = textureCoordinate
        self.color = color
    }
}

public struct GLBMesh: Sendable, Identifiable
{
    public let id: Int
    public let name: String
    public let vertices: [GLBVertex]
    public let triangleIndices: [UInt32]
    public let materialIndex: Int

    public init(id: Int, name: String, vertices: [GLBVertex], triangleIndices: [UInt32], materialIndex: Int)
    {
        self.id = id
        self.name = name
        self.vertices = vertices
        self.triangleIndices = triangleIndices
        self.materialIndex = materialIndex
    }
}

public enum GLBTextureWrap: Sendable
{
    case repeatTexture, mirroredRepeat, clampToEdge
}

public enum GLBMipmapFilter: Sendable
{
    case none, nearest, linear
}

public struct GLBTexture: Sendable
{
    public let encodedImage: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let wrapS: GLBTextureWrap
    public let wrapT: GLBTextureWrap
    public let usesNearestMagnification: Bool
    public let usesNearestMinification: Bool
    public let mipmapFilter: GLBMipmapFilter
}

public enum GLBAlphaMode: Sendable
{
    case opaque, mask, blend
}

public enum GLBSkinning: Sendable
{
    case reject
    case bakeReferencePose
}

public struct GLBMaterial: Sendable
{
    public let name: String
    public let baseColor: SIMD4<Float>
    public let baseColorTexture: GLBTexture?
    public let metallic: Float
    public let roughness: Float
    public let isUnlit: Bool
    public let isDoubleSided: Bool
    public let alphaMode: GLBAlphaMode
    public let alphaCutoff: Float
}

public struct GLBImportLimits: Sendable
{
    public let maximumSourceBytes: Int
    public let maximumVertices: Int
    public let maximumTextureDimension: Int
    public let maximumDecodedTextureBytes: Int
    public let maximumNodes: Int

    public init(
        maximumSourceBytes: Int = 128 * 1024 * 1024,
        maximumVertices: Int = 2000000,
        maximumTextureDimension: Int = 8192,
        maximumDecodedTextureBytes: Int = 256 * 1024 * 1024,
        maximumNodes: Int = 4096
    )
    {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumVertices = maximumVertices
        self.maximumTextureDimension = maximumTextureDimension
        self.maximumDecodedTextureBytes = maximumDecodedTextureBytes
        self.maximumNodes = maximumNodes
    }
}

public enum GLBImportError: Error, LocalizedError, Sendable
{
    case invalidContent(String)
    case unsupportedContent(String)
    case limitExceeded(String)

    public var errorDescription: String?
    {
        switch self
        {
            case let .invalidContent(reason): "Invalid 3D content: \(reason)"
            case let .unsupportedContent(reason): "Unsupported 3D content: \(reason)"
            case let .limitExceeded(reason): "GLB limit exceeded: \(reason)"
        }
    }
}
