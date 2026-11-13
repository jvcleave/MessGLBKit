import Foundation
import GLTFKit2
import simd

/// Reads a single skinned scene with an optional linear translation and rotation clip.
/// Call from a worker. Native decoder objects stay inside the call.
public enum GLBReader
{
    public static func read(
        _ data: Data,
        limits: GLBImportLimits = GLBImportLimits(
            maximumSourceBytes: Int(UInt32.max),
            maximumVertices: Int(UInt32.max) / 3,
            maximumTextureDimension: Int.max,
            maximumDecodedTextureBytes: Int.max,
            maximumNodes: 1000000
        )
    ) throws -> SkinnedModel
    {
        try Task.checkCancellation()
        let decoder = GLBDecoder(limits: limits, skinning: .bakeReferencePose)
        let json = try decoder.readMetadata(data: data, enforcesVertexBudget: true, acceptsAnimation: true)
        let binaryStart = 20 + Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
        guard binaryStart <= data.count - 8 else { throw SkinnedModelError.invalidFile("The GLB binary chunk is missing.") }
        let binaryHeader = data.withUnsafeBytes
        { bytes in
            (0 ..< 2).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: binaryStart + $0 * 4, as: UInt32.self)) }
        }
        let binaryLength = Int(binaryHeader[0])
        guard binaryHeader[1] == 0x004E4942, binaryLength > 0, binaryLength.isMultiple(of: 4),
              binaryStart.isMultiple(of: 4), binaryLength == data.count - binaryStart - 8,
              let buffers = json["buffers"] as? [[String: Any]], buffers.count == 1,
              let length = buffers[0]["byteLength"] as? Int, length > 0, length <= binaryLength, binaryLength - length <= 3
        else { throw SkinnedModelError.invalidFile("The GLB binary chunk is invalid.") }
        guard (json["extensionsUsed"] as? [String] ?? []).isEmpty,
              (json["extensionsRequired"] as? [String] ?? []).isEmpty,
              (json["nodes"] as? [[String: Any]] ?? []).allSatisfy({ $0["matrix"] == nil }),
              (json["images"] as? [[String: Any]] ?? []).allSatisfy({ $0["uri"] == nil })
        else { throw SkinnedModelError.unsupported("The skinned playback profile requires transform components and embedded images.") }
        let asset = try GLBDecoder.nativeAsset(data: data, json: json)
        let materials = try decoder.decodeMaterials(asset: asset, json: json)
        try Task.checkCancellation()

        guard asset.scenes.count == 1, let scene = asset.defaultScene,
              asset.skins.count == 1, let skin = asset.skins.first,
              let root = skin.skeleton, !skin.joints.isEmpty,
              let binds = skin.inverseBindMatrices, binds.count == skin.joints.count,
              scene.nodes.contains(where: { $0 === root })
        else { throw SkinnedModelError.unsupported("A skinned model needs one scene and a shared skin with inverse binds.") }
        let rigNodes = [root] + skin.joints
        var nodeIndices: [ObjectIdentifier: Int] = [:]
        for (index, node) in rigNodes.enumerated()
        {
            guard nodeIndices.updateValue(index, forKey: ObjectIdentifier(node)) == nil
            else { throw SkinnedModelError.invalidFile("The rig repeats a joint.") }
        }
        var parents = [Int?](repeating: nil, count: rigNodes.count)
        for (index, node) in rigNodes.enumerated()
        {
            for child in node.childNodes
            {
                guard let childIndex = nodeIndices[ObjectIdentifier(child)], childIndex > index,
                      parents[childIndex] == nil
                else { throw SkinnedModelError.invalidFile("A rig child has an invalid parent.") }
                parents[childIndex] = index
            }
        }
        guard parents.dropFirst().allSatisfy({ $0 != nil })
        else { throw SkinnedModelError.invalidFile("A joint is detached from the rig root.") }

        var nodes: [SkinnedModel.Node] = []
        for (index, node) in rigNodes.enumerated()
        {
            let rotation = node.rotation
            guard node.mesh == nil, node.scale == SIMD3(repeating: 1),
                  all(abs(node.translation) .< SIMD3(repeating: .infinity)),
                  abs(simd_length_squared(rotation.vector) - 1) < 0.0001
            else { throw SkinnedModelError.unsupported("A rig node needs a finite rigid transform.") }
            nodes.append(SkinnedModel.Node(
                parent: parents[index],
                translation: node.translation,
                rotation: simd_normalize(rotation)
            ))
        }

        let inverseBinds = try GLBAccessor.readInverseBinds(binds, jointCount: skin.joints.count, maximumCount: limits.maximumNodes)
        for bind in inverseBinds
        {
            let determinant = simd_determinant(bind)
            guard determinant.isFinite, abs(determinant) > Double(Float.leastNormalMagnitude)
            else { throw SkinnedModelError.invalidFile("An inverse bind matrix is singular.") }
        }
        let floatBinds = inverseBinds.map
        { matrix in
            simd_float4x4(SIMD4<Float>(matrix.columns.0), SIMD4<Float>(matrix.columns.1), SIMD4<Float>(matrix.columns.2), SIMD4<Float>(matrix.columns.3))
        }

        var meshes: [SkinnedModel.Mesh] = []
        var vertexCount = 0
        var sceneRoots: Set<ObjectIdentifier> = []
        for node in scene.nodes
        {
            try Task.checkCancellation()
            guard sceneRoots.insert(ObjectIdentifier(node)).inserted
            else { throw SkinnedModelError.invalidFile("The scene repeats a root node.") }
            if node === root { continue }
            guard let mesh = node.mesh, !mesh.primitives.isEmpty, node.skin === skin,
                  node.childNodes.isEmpty, node.meshInstances == nil, node.weights == nil,
                  node.translation == .zero, node.scale == SIMD3(repeating: 1),
                  node.rotation.vector == SIMD4(0, 0, 0, 1)
            else { throw SkinnedModelError.unsupported("A skinned playback mesh needs an untransformed scene root and the shared skin.") }
            for primitive in mesh.primitives
            {
                guard let sourceMaterial = primitive.material,
                      let index = materials.indices[ObjectIdentifier(sourceMaterial)]
                else { throw SkinnedModelError.invalidFile("A skinned playback mesh needs a material.") }
                let mesh = try GLBMeshDecoder.mesh(
                    primitive,
                    name: node.name ?? "Mesh",
                    jointCount: skin.joints.count,
                    material: materials.materials[index],
                    maximumVertices: limits.maximumVertices - vertexCount
                )
                vertexCount += mesh.vertices.count
                meshes.append(mesh)
            }
        }
        guard !meshes.isEmpty
        else { throw SkinnedModelError.invalidFile("The scene has no skinned meshes.") }
        let animation = try GLBAnimationDecoder.animation(
            asset.animations,
            nodeIndices: nodeIndices,
            maximumKeys: limits.maximumVertices
        )
        return SkinnedModel(
            meshes: meshes,
            nodes: nodes,
            inverseBinds: floatBinds,
            animation: animation
        )
    }
}
