import GLTFKit2

struct GLBSkinAttributes
{
    let joints: [Float]
    let weights: [Float]

    static func read(_ primitive: GLTFPrimitive, vertexCount: Int) throws -> [Self]?
    {
        var jointsBySet: [Int: GLTFAccessor] = [:]
        var weightsBySet: [Int: GLTFAccessor] = [:]
        for attribute in primitive.attributes
        {
            guard let name = attribute.name else { continue }
            if name.hasPrefix("JOINTS_")
            {
                guard let set = Int(name.dropFirst(7)), set >= 0, name == "JOINTS_\(set)",
                      jointsBySet.updateValue(attribute.accessor, forKey: set) == nil
                else { throw GLBImportError.invalidContent("GLB joint attribute set is invalid.") }
            }
            else if name.hasPrefix("WEIGHTS_")
            {
                guard let set = Int(name.dropFirst(8)), set >= 0, name == "WEIGHTS_\(set)",
                      weightsBySet.updateValue(attribute.accessor, forKey: set) == nil
                else { throw GLBImportError.invalidContent("GLB weight attribute set is invalid.") }
            }
        }
        if jointsBySet.isEmpty, weightsBySet.isEmpty { return nil }
        guard jointsBySet.count == weightsBySet.count
        else { throw GLBImportError.invalidContent("GLB joint and weight sets must be paired.") }
        var sets: [Self] = []
        for index in 0 ..< jointsBySet.count
        {
            try Task.checkCancellation()
            guard let joints = jointsBySet[index], let weights = weightsBySet[index],
                  joints.count == vertexCount, weights.count == vertexCount,
                  !joints.isNormalized, joints.componentType == .unsignedByte || joints.componentType == .unsignedShort,
                  (weights.componentType == .float && !weights.isNormalized) ||
                  ((weights.componentType == .unsignedByte || weights.componentType == .unsignedShort) && weights.isNormalized)
            else { throw GLBImportError.invalidContent("GLB joint and weight accessor layouts are invalid.") }
            sets.append(Self(
                joints: try GLBAccessor.readFloats(accessor: joints, dimension: .vector4, componentCount: 4, maximumCount: vertexCount),
                weights: try GLBAccessor.readFloats(accessor: weights, dimension: .vector4, componentCount: 4, maximumCount: vertexCount)
            ))
        }
        return sets
    }

    /// The unsigned byte and short joint indices are exact in Float.
    static func forEachInfluence(
        _ sets: [Self],
        vertex: Int,
        jointCount: Int,
        _ visit: (Int, Float) -> Void
    ) throws -> Double
    {
        var totalWeight = 0.0
        let first = vertex * 4
        for set in sets
        {
            for index in first ..< first + 4
            {
                let joint = Int(set.joints[index])
                let weight = set.weights[index]
                guard joint >= 0, joint < jointCount, (0 ... 1).contains(weight)
                else { throw GLBImportError.invalidContent("GLB joint index or skin weight is out of range.") }
                if weight == 0 { continue }
                visit(joint, weight)
                totalWeight += Double(weight)
            }
        }
        guard totalWeight > 0
        else { throw GLBImportError.invalidContent("GLB skinned vertex has zero total weight.") }
        return totalWeight
    }
}
