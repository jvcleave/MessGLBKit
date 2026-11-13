import GLTFKit2
import ImageIO
import simd
import UniformTypeIdentifiers

enum GLBMeshDecoder
{
    static func mesh(
        _ primitive: GLTFPrimitive,
        name: String,
        jointCount: Int,
        material: GLBMaterial,
        maximumVertices: Int
    ) throws -> SkinnedModel.Mesh
    {
        guard primitive.primitiveType == .triangles, primitive.targets.isEmpty,
              let positions = primitive.attribute(forName: "POSITION")?.accessor,
              let normals = primitive.attribute(forName: "NORMAL")?.accessor,
              let uv = primitive.attribute(forName: "TEXCOORD_0")?.accessor,
              let indices = primitive.indices
        else { throw SkinnedModelError.unsupported("A skinned playback mesh needs indexed triangles, normals, and UVs.") }
        guard positions.count == normals.count, positions.count == uv.count
        else { throw SkinnedModelError.invalidFile("A mesh has inconsistent vertex counts.") }
        let vertexCount = positions.count
        guard vertexCount <= maximumVertices else { throw GLBImportError.limitExceeded("Skinned mesh vertex count.") }
        let points = try GLBAccessor.readFloat32(positions, dimension: .vector3, componentCount: 3, maximumCount: vertexCount)
        let directions = try GLBAccessor.readFloat32(normals, dimension: .vector3, componentCount: 3, maximumCount: vertexCount)
        let coordinates = try GLBAccessor.readFloat32(uv, dimension: .vector2, componentCount: 2, maximumCount: vertexCount)
        let triangles = try GLBAccessor.readIndices(accessor: indices, vertexCount: vertexCount, maximumCount: maximumVertices * 3)
        guard triangles.count.isMultiple(of: 3)
        else { throw SkinnedModelError.invalidFile("A mesh has an incomplete triangle.") }
        var attributeNames: Set<String> = []
        for attribute in primitive.attributes
        {
            guard let name = attribute.name, attributeNames.insert(name).inserted
            else { throw SkinnedModelError.invalidFile("A mesh has duplicate or unnamed attributes.") }
            guard ["POSITION", "NORMAL", "TEXCOORD_0"].contains(name) || name.hasPrefix("JOINTS_") || name.hasPrefix("WEIGHTS_")
            else { throw SkinnedModelError.unsupported("A skinned playback mesh has an unsupported vertex attribute.") }
        }
        guard let sets = try GLBSkinAttributes.read(primitive, vertexCount: vertexCount)
        else { throw SkinnedModelError.invalidFile("A skinned playback mesh needs joint and weight attributes.") }

        var vertices: [SkinnedModel.Vertex] = []
        var influences: [SkinnedModel.Influence] = []
        vertices.reserveCapacity(vertexCount)
        for vertex in 0 ..< vertexCount
        {
            if vertex.isMultiple(of: 512) { try Task.checkCancellation() }
            let start = influences.count
            let total = try GLBSkinAttributes.forEachInfluence(sets, vertex: vertex, jointCount: jointCount)
            { joint, weight in
                influences.append(SkinnedModel.Influence(joint: joint, weight: weight))
            }
            let offset = vertex * 3
            let normal = SIMD3(directions[offset], directions[offset + 1], directions[offset + 2])
            let length = simd_length_squared(normal)
            guard abs(total - 1) < 0.0001, length.isFinite, length > Float.leastNormalMagnitude
            else { throw SkinnedModelError.invalidFile("A mesh vertex has invalid weights or a zero normal.") }
            vertices.append(SkinnedModel.Vertex(
                position: SIMD3(points[offset], points[offset + 1], points[offset + 2]),
                normal: simd_normalize(normal),
                uv: SIMD2(coordinates[vertex * 2], coordinates[vertex * 2 + 1]),
                influences: start ..< influences.count
            ))
        }
        return SkinnedModel.Mesh(
            name: name,
            vertices: vertices,
            influences: influences,
            indices: triangles,
            material: try playbackMaterial(material, binding: primitive.material?.metallicRoughness?.baseColorTexture)
        )
    }

    private static func playbackMaterial(_ material: GLBMaterial, binding: GLTFTextureParams?) throws -> SkinnedModel.Material
    {
        guard material.isDoubleSided, material.metallic == 0, material.roughness == 1, material.baseColor.w == 1
        else { throw SkinnedModelError.unsupported("A surface uses material settings outside the skinned playback profile.") }
        let cutoff: Float?
        switch material.alphaMode
        {
            case .opaque: cutoff = nil
            case .mask:
                guard (0 ... 1).contains(material.alphaCutoff)
                else { throw SkinnedModelError.invalidFile("A surface alpha cutoff is out of range.") }
                cutoff = material.alphaCutoff
            case .blend: throw SkinnedModelError.unsupported("Blended material transparency.")
        }
        if let binding
        {
            guard binding.texCoord == 0, binding.transform == nil, binding.texture.sampler == nil
            else { throw SkinnedModelError.unsupported("A skinned playback surface needs an embedded image using TEXCOORD_0.") }
        }
        let albedo = material.baseColorTexture?.encodedImage
        if let albedo
        {
            guard let source = CGImageSourceCreateWithData(albedo as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  type == UTType.png.identifier || type == UTType.jpeg.identifier
            else { throw SkinnedModelError.invalidFile("An embedded image needs PNG or JPEG data.") }
        }
        guard cutoff == nil || albedo != nil else { throw SkinnedModelError.invalidFile("A cutout surface has no image.") }
        return SkinnedModel.Material(
            color: SIMD3(material.baseColor.x, material.baseColor.y, material.baseColor.z),
            albedo: albedo,
            alphaCutoff: cutoff
        )
    }
}
