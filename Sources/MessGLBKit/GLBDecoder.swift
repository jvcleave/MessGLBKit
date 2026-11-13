import Foundation
import GLBDracoBridge
import GLTFKit2
import ImageIO
import simd

/// All native objects are created, traversed, and released within the import worker.
public struct GLBDecoder: Sendable
{
    let limits: GLBImportLimits
    private let skinning: GLBSkinning

    public init(limits: GLBImportLimits = GLBImportLimits(), skinning: GLBSkinning = .reject)
    {
        self.limits = limits
        self.skinning = skinning
    }

    /// Returns triangle geometry in the caller's coordinate frame. Pass an
    /// external transform for tile placements or keep the GLB scene frame.
    public func decode(
        data: Data,
        transform: simd_double4x4 = matrix_identity_double4x4,
        allowsDegenerateOnlyScene: Bool = false
    ) throws -> GLBGeometry
    {
        let json = try preflight(data: data)
        let asset = try Self.nativeAsset(data: data, json: json)
        guard let scene = asset.defaultScene ?? (asset.scenes.count == 1 ? asset.scenes.first : nil)
        else { throw GLBImportError.unsupportedContent("A default scene or one unambiguous scene is required.") }
        var part = GLBGeometry()
        if let extras = json["extras"]
        { part.extras = try JSONSerialization.data(withJSONObject: extras, options: [.fragmentsAllowed]) }
        if let copyright = asset.copyright, !copyright.isEmpty { part.attributions.append(copyright) }
        let materials = try decodeMaterials(asset: asset, json: json)
        part.materials = materials.materials
        var visitedNodes = 0
        var activeNodes: Set<ObjectIdentifier> = []
        var skinPose: GLBSkinPose?
        if !asset.skins.isEmpty
        {
            guard skinning == .bakeReferencePose
            else { throw GLBImportError.unsupportedContent("Skinned GLB meshes require reference-pose import.") }
            skinPose = try GLBSkinPose(skins: asset.skins, scene: scene, limits: limits)
        }
        for node in scene.nodes
        {
            try appendNode(node: node, parentTransform: transform, transform: transform, skinPose: skinPose, depth: 0, visitedNodes: &visitedNodes, activeNodes: &activeNodes, materialIndices: materials.indices, part: &part)
        }
        // A tileset validates usable geometry across all of its payloads. Only
        // triangles actually omitted here can justify an empty tile; saved
        // omission metadata alone must not admit an empty or malformed scene.
        guard !part.meshes.isEmpty || (allowsDegenerateOnlyScene && part.omittedDegenerateTriangleCount > 0)
        else { throw GLBImportError.invalidContent("The selected scene has no usable triangle geometry.") }
        return part
    }

    /// Reads bounded JSON metadata without invoking the native reader.
    public func preflight(data: Data, enforcesVertexBudget: Bool = true) throws -> [String: Any]
    {
        try readMetadata(data: data, enforcesVertexBudget: enforcesVertexBudget, acceptsAnimation: false)
    }

    func readMetadata(data: Data, enforcesVertexBudget: Bool, acceptsAnimation: Bool) throws -> [String: Any]
    {
        try Task.checkCancellation()
        guard limits.maximumSourceBytes > 0, limits.maximumVertices > 0,
              limits.maximumVertices <= Int(UInt32.max) / 3, limits.maximumNodes > 0,
              limits.maximumNodes <= 1000000, limits.maximumTextureDimension > 0, limits.maximumDecodedTextureBytes > 0
        else { throw GLBImportError.invalidContent("Positive bounded GLB import limits are required.") }
        guard data.count >= 20, data.count <= limits.maximumSourceBytes
        else { throw GLBImportError.invalidContent("GLB header or file size is invalid.") }
        let header = data.withUnsafeBytes
        { bytes in
            (0 ..< 5).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        guard header[0] == 0x46546C67, header[1] == 2, header[2] == data.count,
              header[4] == 0x4E4F534A, header[3] <= 16 * 1024 * 1024,
              Int(header[3]) <= data.count - 20
        else { throw GLBImportError.invalidContent("Expected a complete glTF 2.0 binary with a JSON chunk.") }
        guard let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20 ..< 20 + Int(header[3]))) as? [String: Any],
              let asset = json["asset"] as? [String: Any], asset["version"] as? String == "2.0"
        else { throw GLBImportError.invalidContent("GLB asset metadata is invalid.") }
        let supportedExtensions: Set<String> = ["KHR_materials_unlit", "KHR_texture_transform", "KHR_mesh_quantization", "KHR_draco_mesh_compression"]
        let extensions = Set((json["extensionsUsed"] as? [String] ?? []) + (json["extensionsRequired"] as? [String] ?? []))
        if let unsupported = extensions.subtracting(supportedExtensions).sorted().first
        {
            throw GLBImportError.unsupportedContent("glTF extension \(unsupported).")
        }
        if !acceptsAnimation, let animations = json["animations"] as? [Any], !animations.isEmpty
        {
            throw GLBImportError.unsupportedContent("GLB animation clips are not supported.")
        }
        if skinning == .reject, let skins = json["skins"] as? [Any], !skins.isEmpty
        {
            throw GLBImportError.unsupportedContent("Skinned GLB meshes require reference-pose import.")
        }
        for buffer in json["buffers"] as? [[String: Any]] ?? []
        {
            guard buffer["uri"] == nil
            else { throw GLBImportError.unsupportedContent("GLBs must contain their binary buffers.") }
        }
        for image in json["images"] as? [[String: Any]] ?? []
        {
            if let uri = image["uri"]
            {
                guard let uri = uri as? String, uri.hasPrefix("data:")
                else { throw GLBImportError.unsupportedContent("GLB textures must be embedded; external resource URLs are not read.") }
            }
            else
            {
                guard let view = image["bufferView"] as? Int, view >= 0,
                      view < (json["bufferViews"] as? [Any] ?? []).count
                else { throw GLBImportError.invalidContent("An image needs a valid embedded buffer view.") }
            }
        }
        for sampler in json["samplers"] as? [[String: Any]] ?? []
        {
            guard sampler["magFilter"] == nil || [9728, 9729].contains(sampler["magFilter"] as? Int ?? 0),
                  sampler["minFilter"] == nil || [9728, 9729, 9984, 9985, 9986, 9987].contains(sampler["minFilter"] as? Int ?? 0)
            else { throw GLBImportError.unsupportedContent("Unknown texture filter.") }
        }
        for field in ["nodes", "meshes", "materials", "images", "accessors", "skins", "animations"]
        {
            guard (json[field] as? [Any] ?? []).count <= limits.maximumNodes
            else { throw GLBImportError.limitExceeded("GLB \(field) count.") }
        }
        let primitiveCount = (json["meshes"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["primitives"] as? [Any] ?? []).count }
        guard primitiveCount <= limits.maximumNodes else { throw GLBImportError.limitExceeded("GLB primitive count.") }
        let skins = json["skins"] as? [[String: Any]] ?? []
        var jointCount = 0
        for skin in skins
        {
            guard let joints = skin["joints"] as? [Int], !joints.isEmpty
            else { throw GLBImportError.invalidContent("GLB skin has no joints.") }
            guard joints.count <= limits.maximumNodes - jointCount
            else { throw GLBImportError.limitExceeded("GLB skin joint count.") }
            jointCount += joints.count
        }
        let inverseBindAccessors = Set(skins.compactMap { $0["inverseBindMatrices"] as? Int })
        for (index, accessor) in (json["accessors"] as? [[String: Any]] ?? []).enumerated()
        {
            let maximumCount = inverseBindAccessors.contains(index)
                ? limits.maximumNodes
                : (enforcesVertexBudget ? limits.maximumVertices * 3 : Int(UInt32.max))
            guard let count = accessor["count"] as? Int, count > 0,
                  count <= maximumCount
            else { throw GLBImportError.limitExceeded("GLB accessor element count.") }
        }
        return json
    }

    static func nativeAsset(data: Data, json: [String: Any]) throws -> GLTFAsset
    {
        try GLBDracoAdmission.validate(data: data, json: json)
        GLBInstallDracoDecoder()
        do { return try GLTFAsset(data: data, options: [:]) }
        catch { throw GLBImportError.invalidContent("The native GLB decoder rejected this payload.") }
    }

    private func appendNode(
        node: GLTFNode,
        parentTransform: simd_double4x4,
        transform: simd_double4x4,
        skinPose: GLBSkinPose?,
        depth: Int,
        visitedNodes: inout Int,
        activeNodes: inout Set<ObjectIdentifier>,
        materialIndices: [ObjectIdentifier: Int],
        part: inout GLBGeometry
    ) throws
    {
        try Task.checkCancellation()
        visitedNodes += 1
        let identity = ObjectIdentifier(node)
        guard depth < 64, visitedNodes <= limits.maximumNodes, activeNodes.insert(identity).inserted
        else { throw GLBImportError.invalidContent("GLB hierarchy is cyclic or exceeds the node/depth budget.") }
        defer { activeNodes.remove(identity) }
        guard node.meshInstances == nil, node.weights == nil
        else { throw GLBImportError.unsupportedContent("GLB instancing and morph weights are not supported.") }
        let nodeTransform = parentTransform * Self.nodeTransform(node)
        let placement = try GLBTransform(nodeTransform)
        if let mesh = node.mesh
        {
            for primitive in mesh.primitives
            {
                guard primitive.primitiveType == .triangles, primitive.targets.isEmpty,
                      let positionAccessor = primitive.attribute(forName: "POSITION")?.accessor
                else { throw GLBImportError.unsupportedContent("Only static triangle primitives are supported.") }
                var positions = try GLBAccessor.readFloats(accessor: positionAccessor, dimension: .vector3, componentCount: 3, maximumCount: limits.maximumVertices)
                let count = positionAccessor.count
                let indices: [UInt32]
                if let indexAccessor = primitive.indices
                {
                    indices = try GLBAccessor.readIndices(accessor: indexAccessor, vertexCount: count, maximumCount: limits.maximumVertices * 3)
                }
                else
                {
                    indices = (0 ..< count).map { UInt32($0) }
                }
                guard indices.count.isMultiple(of: 3)
                else { throw GLBImportError.invalidContent("Triangle index count must be a multiple of three.") }
                var normals: [Float]?
                if let accessor = primitive.attribute(forName: "NORMAL")?.accessor
                {
                    guard accessor.count == count else { throw GLBImportError.invalidContent("Normal count differs from positions.") }
                    normals = try GLBAccessor.readFloats(accessor: accessor, dimension: .vector3, componentCount: 3, maximumCount: limits.maximumVertices)
                }
                else { normals = nil }
                let textureParams = primitive.material?.metallicRoughness?.baseColorTexture
                let coordinateSet = textureParams?.transform?.hasTexCoord == true ? Int(textureParams?.transform?.texCoord ?? 0) : textureParams?.texCoord ?? 0
                var coordinates = [Float](repeating: 0, count: count * 2)
                if let accessor = primitive.attribute(forName: "TEXCOORD_\(coordinateSet)")?.accessor
                {
                    guard accessor.count == count else { throw GLBImportError.invalidContent("UV count differs from positions.") }
                    coordinates = try GLBAccessor.readFloats(accessor: accessor, dimension: .vector2, componentCount: 2, maximumCount: limits.maximumVertices)
                }
                else if textureParams != nil
                {
                    throw GLBImportError.invalidContent("Material UV set is missing.")
                }
                var colors = [Float](repeating: 1, count: count * 4)
                if let accessor = primitive.attribute(forName: "COLOR_0")?.accessor
                {
                    let dimension = accessor.dimension == .vector3 ? 3 : 4
                    guard accessor.count == count else { throw GLBImportError.invalidContent("Color count differs from positions.") }
                    let values = try GLBAccessor.readFloats(accessor: accessor, dimension: dimension == 3 ? .vector3 : .vector4, componentCount: dimension, maximumCount: limits.maximumVertices)
                    for index in 0 ..< count
                    {
                        for component in 0 ..< dimension { colors[index * 4 + component] = values[index * dimension + component] }
                    }
                }
                // Skinned vertices use the joint hierarchy's scene space. A
                // regular primitive or child still uses its node transform.
                var geometryTransform = placement
                if let skin = node.skin
                {
                    guard let skinPose
                    else { throw GLBImportError.invalidContent("GLB skin is missing from the scene.") }
                    if try skinPose.bake(primitive, skin: skin, positions: &positions, normals: &normals)
                    {
                        geometryTransform = try GLBTransform(transform)
                    }
                }
                let uvTransform = textureParams?.transform?.matrix ?? matrix_identity_float4x4
                var vertices: [GLBVertex] = []
                vertices.reserveCapacity(count)
                for index in 0 ..< count
                {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let position = geometryTransform.position * SIMD4<Double>(Double(positions[index * 3]), Double(positions[index * 3 + 1]), Double(positions[index * 3 + 2]), 1)
                    let localPosition = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
                    guard localPosition.x.isFinite, localPosition.y.isFinite, localPosition.z.isFinite
                    else { throw GLBImportError.invalidContent("Transformed geometry contains non-finite positions.") }
                    var normal = SIMD3<Float>(0, 1, 0)
                    if let normals
                    {
                        let transformed = geometryTransform.normal * SIMD3<Double>(Double(normals[index * 3]), Double(normals[index * 3 + 1]), Double(normals[index * 3 + 2]))
                        guard simd_length_squared(transformed) > 1e-20
                        else { throw GLBImportError.invalidContent("Geometry contains a zero normal.") }
                        normal = SIMD3<Float>(simd_normalize(transformed))
                    }
                    let uv = uvTransform * SIMD4(coordinates[index * 2], coordinates[index * 2 + 1], 0, 1)
                    guard uv.x.isFinite, uv.y.isFinite
                    else { throw GLBImportError.invalidContent("Transformed texture coordinates are non-finite.") }
                    vertices.append(GLBVertex(position: localPosition, normal: normal, textureCoordinate: SIMD2(uv.x, uv.y), color: SIMD4(colors[index * 4], colors[index * 4 + 1], colors[index * 4 + 2], colors[index * 4 + 3])))
                }
                var triangleIndices = indices
                if geometryTransform.reversesWinding
                {
                    for index in stride(from: 0, to: triangleIndices.count, by: 3) { triangleIndices.swapAt(index + 1, index + 2) }
                }
                if normals == nil
                {
                    var flatVertices: [GLBVertex] = []
                    flatVertices.reserveCapacity(min(indices.count, limits.maximumVertices))
                    func sourcePosition(_ index: Int) -> SIMD3<Double>
                    {
                        SIMD3(Double(positions[index * 3]), Double(positions[index * 3 + 1]), Double(positions[index * 3 + 2]))
                    }
                    for index in stride(from: 0, to: triangleIndices.count, by: 3)
                    {
                        if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                        let first = Int(triangleIndices[index])
                        let second = Int(triangleIndices[index + 1])
                        let third = Int(triangleIndices[index + 2])
                        // Subtract before transforming, in Double, so translation
                        // and Float output rounding cannot collapse source edges.
                        let origin = sourcePosition(first)
                        let cross = simd_cross(sourcePosition(second) - origin, sourcePosition(third) - origin)
                        if cross == .zero
                        {
                            part.omittedDegenerateTriangleCount += 1
                            continue
                        }
                        // Winding was reversed above for reflected transforms.
                        let transformed = geometryTransform.normal * (geometryTransform.reversesWinding ? -cross : cross)
                        guard transformed.x.isFinite, transformed.y.isFinite, transformed.z.isFinite
                        else { throw GLBImportError.invalidContent("Generated geometry normal is non-finite.") }
                        let scale = max(abs(transformed.x), abs(transformed.y), abs(transformed.z))
                        guard scale > 0 else { throw GLBImportError.invalidContent("Cannot transform a nonzero triangle normal.") }
                        let normal = SIMD3<Float>(simd_normalize(transformed / scale))
                        guard flatVertices.count <= limits.maximumVertices - 3
                        else { throw GLBImportError.limitExceeded("Flat-normal vertex expansion.") }
                        for source in [first, second, third]
                        {
                            let vertex = vertices[source]
                            flatVertices.append(GLBVertex(position: vertex.position, normal: normal, textureCoordinate: vertex.textureCoordinate, color: vertex.color))
                        }
                    }
                    vertices = flatVertices
                    triangleIndices = (0 ..< vertices.count).map { UInt32($0) }
                    if triangleIndices.isEmpty { continue }
                }
                let materialIndex: Int
                if let material = primitive.material
                {
                    guard let index = materialIndices[ObjectIdentifier(material)]
                    else { throw GLBImportError.invalidContent("Primitive material is not part of the asset.") }
                    materialIndex = index
                }
                else
                {
                    materialIndex = part.materials.count
                    part.materials.append(GLBMaterial(name: "Default", baseColor: SIMD4(repeating: 1), baseColorTexture: nil, metallic: 1, roughness: 1, isUnlit: false, isDoubleSided: false, alphaMode: .opaque, alphaCutoff: 0.5))
                }
                guard vertices.count <= limits.maximumVertices - part.vertexCount
                else { throw GLBImportError.limitExceeded("Prepared vertex count.") }
                part.meshes.append(GLBMesh(id: part.meshes.count, name: node.name ?? mesh.name ?? "Mesh \(part.meshes.count + 1)", vertices: vertices, triangleIndices: triangleIndices, materialIndex: materialIndex))
                part.vertexCount += vertices.count
            }
        }
        for child in node.childNodes
        {
            try appendNode(node: child, parentTransform: nodeTransform, transform: transform, skinPose: skinPose, depth: depth + 1, visitedNodes: &visitedNodes, activeNodes: &activeNodes, materialIndices: materialIndices, part: &part)
        }
    }

    static func nodeTransform(_ node: GLTFNode) -> simd_double4x4
    {
        let matrix = node.matrix
        return simd_double4x4(columns: (
            SIMD4<Double>(matrix.columns.0),
            SIMD4<Double>(matrix.columns.1),
            SIMD4<Double>(matrix.columns.2),
            SIMD4<Double>(matrix.columns.3)
        ))
    }

    func decodeMaterials(asset: GLTFAsset, json: [String: Any]) throws -> (materials: [GLBMaterial], indices: [ObjectIdentifier: Int])
    {
        // The native reader leaves JSON escapes in embedded image MIME types.
        // Use the already-decoded declarations in native image order.
        let imageDeclarations = json["images"] as? [[String: Any]] ?? []
        guard imageDeclarations.count == asset.images.count
        else { throw GLBImportError.invalidContent("GLB image declarations do not match the decoded images.") }
        var imageMIMETypes: [ObjectIdentifier: String] = [:]
        for (image, declaration) in zip(asset.images, imageDeclarations)
        {
            if let mime = declaration["mimeType"] as? String { imageMIMETypes[ObjectIdentifier(image)] = mime }
        }
        var materials: [GLBMaterial] = []
        var indices: [ObjectIdentifier: Int] = [:]
        var textureBytes = 0
        for material in asset.materials
        {
            try Task.checkCancellation()
            let value = try makeMaterial(material: material, imageMIMETypes: imageMIMETypes)
            if let texture = value.baseColorTexture
            {
                let bytes = texture.width * texture.height * 4
                guard bytes <= limits.maximumDecodedTextureBytes - textureBytes
                else { throw GLBImportError.limitExceeded("GLB decoded texture bytes.") }
                textureBytes += bytes
            }
            indices[ObjectIdentifier(material)] = materials.count
            materials.append(value)
        }
        return (materials, indices)
    }

    private func makeMaterial(material: GLTFMaterial, imageMIMETypes: [ObjectIdentifier: String]) throws -> GLBMaterial
    {
        guard material.specularGlossiness == nil, material.normalTexture == nil,
              material.occlusionTexture == nil, material.metallicRoughness?.metallicRoughnessTexture == nil,
              material.specular == nil, material.transmission == nil, material.diffuseTransmission == nil,
              material.volume == nil, material.clearcoat == nil, material.sheen == nil,
              material.iridescence == nil, material.anisotropy == nil,
              material.indexOfRefraction == nil, material.dispersion == nil,
              material.emissive?.emissiveTexture == nil,
              (material.emissive?.emissiveFactor ?? .zero) == .zero
        else { throw GLBImportError.unsupportedContent("The initial material adapter supports base-color textures and factors; additional material maps require a verified mapping.") }
        let texture: GLBTexture?
        if let params = material.metallicRoughness?.baseColorTexture
        {
            guard let image = params.texture.source
            else { throw GLBImportError.invalidContent("Base-color texture has no source image.") }
            let dataURIMime = image.uri?.absoluteString.split(separator: ";", maxSplits: 1).first.map { String($0.dropFirst(5)) }
            guard let mime = imageMIMETypes[ObjectIdentifier(image)] ?? image.mimeType ?? dataURIMime,
                  ["image/png", "image/jpeg"].contains(mime)
            else { throw GLBImportError.unsupportedContent("Base-color textures must be embedded PNG or JPEG images.") }
            let encoded: Data
            if let view = image.bufferView, let buffer = view.buffer.data,
               view.offset >= 0, view.length > 0, view.offset <= buffer.count, view.length <= buffer.count - view.offset
            {
                encoded = buffer.subdata(in: view.offset ..< view.offset + view.length)
            }
            else if let uri = image.uri?.absoluteString,
                    let separator = uri.range(of: ";base64,"),
                    let data = Data(base64Encoded: String(uri[separator.upperBound...]))
            {
                encoded = data
            }
            else { throw GLBImportError.invalidContent("Embedded image payload is missing.") }
            guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= limits.maximumTextureDimension, height <= limits.maximumTextureDimension,
                  width <= limits.maximumDecodedTextureBytes / 4 / height
            else { throw GLBImportError.limitExceeded("Invalid image or texture dimensions exceed the budget.") }
            let sampler = params.texture.sampler
            let nearestMinification: Bool
            let mipmapFilter: GLBMipmapFilter
            // glTF permits omitted filters. GLTFKit2 represents an omitted
            // minFilter as zero; explicit invalid values were rejected above.
            let minification = sampler?.minMipFilter ?? .linearLinear
            switch minification.rawValue == 0 ? GLTFMinMipFilter.linearLinear : minification
            {
                case .nearest: nearestMinification = true; mipmapFilter = .none
                case .linear: nearestMinification = false; mipmapFilter = .none
                case .nearestNearest: nearestMinification = true; mipmapFilter = .nearest
                case .linearNearest: nearestMinification = false; mipmapFilter = .nearest
                case .nearestLinear: nearestMinification = true; mipmapFilter = .linear
                case .linearLinear: nearestMinification = false; mipmapFilter = .linear
                default: throw GLBImportError.unsupportedContent("Unknown texture minification filter.")
            }
            texture = GLBTexture(
                encodedImage: encoded,
                mimeType: mime,
                width: width,
                height: height,
                wrapS: try wrapMode(mode: sampler?.wrapS ?? .repeat),
                wrapT: try wrapMode(mode: sampler?.wrapT ?? .repeat),
                usesNearestMagnification: sampler?.magFilter == .nearest,
                usesNearestMinification: nearestMinification,
                mipmapFilter: mipmapFilter
            )
        }
        else { texture = nil }
        let mode: GLBAlphaMode
        switch material.alphaMode
        {
            case .opaque: mode = .opaque
            case .mask: mode = .mask
            case .blend: mode = .blend
            default: throw GLBImportError.unsupportedContent("Unknown material alpha mode.")
        }
        let color = material.metallicRoughness?.baseColorFactor ?? SIMD4<Float>(repeating: 1)
        let metallic = material.metallicRoughness?.metallicFactor ?? 1
        let roughness = material.metallicRoughness?.roughnessFactor ?? 1
        guard color.x.isFinite, color.y.isFinite, color.z.isFinite, color.w.isFinite,
              [color.x, color.y, color.z, color.w].allSatisfy({ (0 ... 1).contains($0) }),
              (0 ... 1).contains(metallic), (0 ... 1).contains(roughness),
              material.alphaCutoff.isFinite, material.alphaCutoff >= 0
        else { throw GLBImportError.invalidContent("Material factors are invalid.") }
        return GLBMaterial(name: material.name ?? "Material", baseColor: color, baseColorTexture: texture, metallic: metallic, roughness: roughness, isUnlit: material.isUnlit, isDoubleSided: material.isDoubleSided, alphaMode: mode, alphaCutoff: material.alphaCutoff)
    }

    private func wrapMode(mode: GLTFAddressMode) throws -> GLBTextureWrap
    {
        switch mode
        {
            case .repeat: .repeatTexture
            case .mirroredRepeat: .mirroredRepeat
            case .clampToEdge: .clampToEdge
            default: throw GLBImportError.unsupportedContent("Unknown texture wrap mode.")
        }
    }
}
