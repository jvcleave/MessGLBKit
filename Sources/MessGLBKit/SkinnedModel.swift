import Foundation
import simd

public enum SkinnedModelError: LocalizedError, Sendable
{
    case invalidFile(String)
    case unsupported(String)
    case invalidTime

    public var errorDescription: String?
    {
        switch self
        {
            case let .invalidFile(detail): "The model file is invalid. \(detail)"
            case let .unsupported(detail): "This model cannot be previewed. \(detail)"
            case .invalidTime: "The animation sample time is invalid."
        }
    }
}

/// Geometry uses meters in right-handed Y-up coordinates. UVs use top-left image origin.
public struct SkinnedModel: Sendable
{
    public struct Material: Sendable
    {
        public let color: SIMD3<Float>
        public let albedo: Data?
        public let alphaCutoff: Float?
    }

    public struct Influence: Sendable
    {
        public let joint: Int
        public let weight: Float
    }

    public struct Vertex: Sendable
    {
        public let position: SIMD3<Float>
        public let normal: SIMD3<Float>
        public let uv: SIMD2<Float>
        public let influences: Range<Int>
    }

    public struct Mesh: Sendable
    {
        public let name: String
        public let vertices: [Vertex]
        public let influences: [Influence]
        public let indices: [UInt32]
        public let material: Material
    }

    public struct PosedVertex: Sendable
    {
        public let position: SIMD3<Float>
        public let normal: SIMD3<Float>
        public let uv: SIMD2<Float>
    }

    struct Node: Sendable
    {
        let parent: Int?
        let translation: SIMD3<Float>
        let rotation: simd_quatf
    }

    struct Animation: Sendable
    {
        struct Track: Sendable
        {
            var translations: [SIMD3<Float>]?
            var rotations: [simd_quatf]?
        }

        let times: [Double]
        let tracks: [Track]

        func interval(at seconds: Double) -> (lower: Int, upper: Int, fraction: Float)
        {
            let end = times.count - 1
            if seconds <= times[0] { return (0, 0, 0) }
            if seconds >= times[end] { return (end, end, 0) }
            var lower = 0
            var upper = end
            while upper - lower > 1
            {
                let middle = lower + (upper - lower) / 2
                if times[middle] <= seconds { lower = middle }
                else { upper = middle }
            }
            let fraction = Float((seconds - times[lower]) / (times[upper] - times[lower]))
            return (lower, upper, fraction)
        }
    }

    public let meshes: [Mesh]
    let nodes: [Node]
    let inverseBinds: [simd_float4x4]
    let animation: Animation?

    /// Nil for a rigged still. Animated times start at zero and use seconds.
    public var duration: Double? { animation?.times.last }
    public var rootTranslations: [SIMD3<Float>] { animation?.tracks.first?.translations ?? [] }

    /// Samples a joint palette in scene space. Nil samples the file's reference pose.
    /// CPU work runs on the caller's worker.
    public func jointMatrices(at seconds: Double? = nil) throws -> [simd_float4x4]
    {
        if let seconds, !seconds.isFinite { throw SkinnedModelError.invalidTime }
        let interval = seconds.flatMap { animation?.interval(at: $0) }
        var world: [simd_float4x4] = []
        world.reserveCapacity(nodes.count)
        for (index, node) in nodes.enumerated()
        {
            var translation = node.translation
            var rotation = node.rotation
            if let animation, let interval
            {
                let track = animation.tracks[index]
                if let translations = track.translations
                {
                    let first = translations[interval.lower]
                    let last = translations[interval.upper]
                    translation = first + (last - first) * interval.fraction
                }
                if let rotations = track.rotations
                {
                    rotation = simd_slerp(
                        rotations[interval.lower],
                        rotations[interval.upper],
                        interval.fraction
                    )
                }
            }
            var local = simd_float4x4(rotation)
            local.columns.3 = SIMD4(translation, 1)
            if let parent = node.parent { world.append(world[parent] * local) }
            else { world.append(local) }
        }
        return zip(world.dropFirst(), inverseBinds).map { $0 * $1 }
    }

    /// Applies the full palette on the caller's worker. The result follows mesh order.
    public func pose(at seconds: Double? = nil) throws -> [[PosedVertex]]
    {
        try Task.checkCancellation()
        let matrices = try jointMatrices(at: seconds)
        var posedMeshes: [[PosedVertex]] = []
        posedMeshes.reserveCapacity(meshes.count)
        for mesh in meshes
        {
            var vertices: [PosedVertex] = []
            vertices.reserveCapacity(mesh.vertices.count)
            for (index, vertex) in mesh.vertices.enumerated()
            {
                if index.isMultiple(of: 512) { try Task.checkCancellation() }
                let bindPosition = SIMD4(vertex.position, 1)
                let bindNormal = SIMD4(vertex.normal, 0)
                var position = SIMD4<Float>.zero
                var normal = SIMD4<Float>.zero
                for influence in mesh.influences[vertex.influences]
                {
                    let matrix = matrices[influence.joint]
                    position += (matrix * bindPosition) * influence.weight
                    normal += (matrix * bindNormal) * influence.weight
                }
                let direction = SIMD3(normal.x, normal.y, normal.z)
                let lengthSquared = simd_length_squared(direction)
                guard all(abs(position) .< SIMD4(repeating: .infinity)), lengthSquared.isFinite
                else { throw SkinnedModelError.invalidFile("A sampled vertex is non-finite.") }
                vertices.append(PosedVertex(
                    position: SIMD3(position.x, position.y, position.z),
                    normal: lengthSquared > Float.leastNormalMagnitude ? simd_normalize(direction) : vertex.normal,
                    uv: vertex.uv
                ))
            }
            posedMeshes.append(vertices)
        }
        return posedMeshes
    }
}
