@testable import MessGLBKit
import simd
import Testing

struct SkinnedModelTests
{
    @Test func samplesRootTravelAndEveryInfluenceInSceneSpace() throws
    {
        let identity = simd_quatf(real: 1, imag: .zero)
        var nodes = [SkinnedModel.Node(
            parent: nil,
            translation: .zero,
            rotation: identity
        )]
        for joint in 0 ..< 6
        {
            nodes.append(SkinnedModel.Node(
                parent: joint,
                translation: joint == 5 ? SIMD3(1, 0, 0) : .zero,
                rotation: identity
            ))
        }
        var lastBind = matrix_identity_float4x4
        lastBind.columns.3.x = -1
        let vertex = SkinnedModel.Vertex(
            position: SIMD3(2, 0, 0),
            normal: SIMD3(1, 0, 0),
            uv: SIMD2(0.25, 0.75),
            influences: 0 ..< 6
        )
        var influences: [SkinnedModel.Influence] = []
        for joint in 0 ..< 6
        {
            influences.append(SkinnedModel.Influence(
                joint: joint,
                weight: joint < 4 ? 0.125 : 0.25
            ))
        }
        let mesh = SkinnedModel.Mesh(
            name: "Surface",
            vertices: [vertex],
            influences: influences,
            indices: [0, 0, 0],
            material: .init(color: SIMD3(repeating: 1), albedo: nil, alphaCutoff: nil)
        )
        var tracks = [SkinnedModel.Animation.Track](repeating: .init(), count: nodes.count)
        tracks[0].translations = [.zero, SIMD3(2, 0, 0)]
        tracks[6].rotations = [identity, simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))]
        let model = SkinnedModel(
            meshes: [mesh],
            nodes: nodes,
            inverseBinds: Array(repeating: matrix_identity_float4x4, count: 5) + [lastBind],
            animation: .init(times: [0, 1], tracks: tracks)
        )

        let reference = try model.pose()[0][0]
        #expect(reference.position == vertex.position)
        #expect(reference.uv == vertex.uv)
        let middle = try model.pose(at: 0.5)[0][0]
        let diagonal = sqrt(Float(0.5))
        let middlePosition = SIMD3(2.75 + diagonal / 4, diagonal / 4, 0)
        let middleNormal = simd_normalize(SIMD3(0.75 + diagonal / 4, diagonal / 4, 0))
        #expect(simd_distance(middle.position, middlePosition) < 0.00001)
        #expect(simd_distance(middle.normal, middleNormal) < 0.00001)
        let end = try model.pose(at: 2)[0][0]
        #expect(simd_distance(end.position, SIMD3(3.75, 0.25, 0)) < 0.00001)
    }
}
