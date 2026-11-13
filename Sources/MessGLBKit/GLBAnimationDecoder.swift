import GLTFKit2
import simd

enum GLBAnimationDecoder
{
    static func animation(
        _ animations: [GLTFAnimation],
        nodeIndices: [ObjectIdentifier: Int],
        maximumKeys: Int
    ) throws -> SkinnedModel.Animation?
    {
        guard let animation = animations.first else { return nil }
        guard animations.count == 1, let timeAccessor = animation.channels.first?.sampler.input
        else { throw SkinnedModelError.unsupported("A skinned playback model carries one clip with animation channels.") }
        let times = try GLBAccessor.readFloat32(
            timeAccessor,
            dimension: .scalar,
            componentCount: 1,
            maximumCount: maximumKeys
        ).map(Double.init)
        guard times.count >= 2, times[0] == 0,
              zip(times, times.dropFirst()).allSatisfy({ $0 < $1 })
        else { throw SkinnedModelError.invalidFile("Animation times must start at zero and increase.") }

        var tracks = [SkinnedModel.Animation.Track](repeating: .init(), count: nodeIndices.count)
        for channel in animation.channels
        {
            try Task.checkCancellation()
            guard let node = channel.target.node, let index = nodeIndices[ObjectIdentifier(node)],
                  channel.sampler.interpolationMode == .linear,
                  channel.sampler.input === timeAccessor, channel.sampler.output.count == times.count
            else { throw SkinnedModelError.unsupported("Animation channels need the shared time keys, linear interpolation, and a rig target.") }
            switch channel.target.path
            {
                case "translation":
                    guard tracks[index].translations == nil
                    else { throw SkinnedModelError.invalidFile("A node has duplicate translation channels.") }
                    let values = try GLBAccessor.readFloat32(channel.sampler.output, dimension: .vector3, componentCount: 3, maximumCount: times.count)
                    tracks[index].translations = stride(from: 0, to: values.count, by: 3).map
                    { offset in SIMD3(values[offset], values[offset + 1], values[offset + 2]) }
                case "rotation":
                    guard tracks[index].rotations == nil
                    else { throw SkinnedModelError.invalidFile("A node has duplicate rotation channels.") }
                    let values = try GLBAccessor.readFloat32(
                        channel.sampler.output,
                        dimension: .vector4,
                        componentCount: 4,
                        maximumCount: times.count
                    )
                    tracks[index].rotations = try stride(from: 0, to: values.count, by: 4).map
                    { offset in
                        let vector = SIMD4(values[offset], values[offset + 1], values[offset + 2], values[offset + 3])
                        guard abs(simd_length_squared(vector) - 1) < 0.0001
                        else { throw SkinnedModelError.invalidFile("An animation rotation is not a unit quaternion.") }
                        return simd_normalize(simd_quatf(vector: vector))
                    }
                default:
                    throw SkinnedModelError.unsupported("Animation channel \(channel.target.path).")
            }
        }
        return SkinnedModel.Animation(
            times: times,
            tracks: tracks
        )
    }
}
