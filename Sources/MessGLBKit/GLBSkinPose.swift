import GLTFKit2
import simd

/// Evaluates default joint transforms once on the import worker.
struct GLBSkinPose
{
    private let jointTransforms: [ObjectIdentifier: [GLBTransform]]

    init(skins: [GLTFSkin], scene: GLTFScene, limits: GLBImportLimits) throws
    {
        var nodeTransforms: [ObjectIdentifier: simd_double4x4] = [:]
        var usedSkins: Set<ObjectIdentifier> = []
        for node in scene.nodes
        {
            try Self.collectTransforms(node, parent: matrix_identity_double4x4, depth: 0, maximumNodes: limits.maximumNodes, transforms: &nodeTransforms, usedSkins: &usedSkins)
        }
        var jointTransforms: [ObjectIdentifier: [GLBTransform]] = [:]
        for skin in skins where usedSkins.contains(ObjectIdentifier(skin))
        {
            try Task.checkCancellation()
            let joints = skin.joints
            guard !joints.isEmpty else { throw GLBImportError.invalidContent("GLB skin has no joints.") }
            let inverseBinds = try GLBAccessor.readInverseBinds(skin.inverseBindMatrices, jointCount: joints.count, maximumCount: limits.maximumNodes)
            var transforms: [GLBTransform] = []
            transforms.reserveCapacity(joints.count)
            var visitedJoints: Set<ObjectIdentifier> = []
            for (index, joint) in joints.enumerated()
            {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                let identity = ObjectIdentifier(joint)
                guard let jointTransform = nodeTransforms[identity], visitedJoints.insert(identity).inserted
                else { throw GLBImportError.invalidContent("GLB skin has a repeated joint or a joint outside the selected scene.") }
                transforms.append(try GLBTransform(jointTransform * inverseBinds[index]))
            }
            jointTransforms[ObjectIdentifier(skin)] = transforms
        }
        self.jointTransforms = jointTransforms
    }

    /// A primitive with no joint or weight attributes uses its ordinary node transform.
    func bake(_ primitive: GLTFPrimitive, skin: GLTFSkin, positions: inout [Float], normals: inout [Float]?) throws -> Bool
    {
        let vertexCount = positions.count / 3
        guard let sets = try GLBSkinAttributes.read(primitive, vertexCount: vertexCount) else { return false }
        guard let transforms = jointTransforms[ObjectIdentifier(skin)]
        else { throw GLBImportError.invalidContent("GLB skin is missing from the scene.") }
        for vertex in 0 ..< vertexCount
        {
            if vertex.isMultiple(of: 4096) { try Task.checkCancellation() }
            let offset = vertex * 3
            let sourcePosition = SIMD4(Double(positions[offset]), Double(positions[offset + 1]), Double(positions[offset + 2]), 1)
            var sourceNormal: SIMD3<Double>?
            if let x = normals?[offset], let y = normals?[offset + 1], let z = normals?[offset + 2]
            { sourceNormal = SIMD3(Double(x), Double(y), Double(z)) }
            var position = SIMD4<Double>.zero
            var normal = SIMD3<Double>.zero
            let totalWeight = try GLBSkinAttributes.forEachInfluence(sets, vertex: vertex, jointCount: transforms.count)
            { joint, value in
                let transform = transforms[joint]
                let weight = Double(value)
                position += (transform.position * sourcePosition) * weight
                if let sourceNormal { normal += (transform.normal * sourceNormal) * weight }
            }
            position /= totalWeight
            positions[offset] = Float(position.x)
            positions[offset + 1] = Float(position.y)
            positions[offset + 2] = Float(position.z)
            if sourceNormal != nil
            {
                let direction = normal / totalWeight
                let lengthSquared = simd_length_squared(direction)
                guard lengthSquared.isFinite, lengthSquared > 1e-20
                else { throw GLBImportError.invalidContent("GLB skin produced an invalid normal.") }
                let normalized = simd_normalize(direction)
                normals?[offset] = Float(normalized.x)
                normals?[offset + 1] = Float(normalized.y)
                normals?[offset + 2] = Float(normalized.z)
            }
        }
        return true
    }

    private static func collectTransforms(
        _ node: GLTFNode,
        parent: simd_double4x4,
        depth: Int,
        maximumNodes: Int,
        transforms: inout [ObjectIdentifier: simd_double4x4],
        usedSkins: inout Set<ObjectIdentifier>
    ) throws
    {
        try Task.checkCancellation()
        let identity = ObjectIdentifier(node)
        guard depth < 64, transforms.count < maximumNodes, transforms[identity] == nil
        else { throw GLBImportError.invalidContent("GLB skin hierarchy has repeated nodes or exceeds the node/depth budget.") }
        let transform = parent * GLBDecoder.nodeTransform(node)
        transforms[identity] = transform
        if let skin = node.skin, node.mesh != nil { usedSkins.insert(ObjectIdentifier(skin)) }
        for child in node.childNodes
        {
            try collectTransforms(child, parent: transform, depth: depth + 1, maximumNodes: maximumNodes, transforms: &transforms, usedSkins: &usedSkins)
        }
    }
}
