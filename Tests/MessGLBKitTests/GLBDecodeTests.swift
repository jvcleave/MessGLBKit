import Foundation
import MessGLBKit
import simd
import Testing

@Test func stillAndClipDecodeWithAllInfluencesAndEmbeddedCutout() throws
{
    let still = try skinnedTriangle(animated: false)
    let reference = try GLBDecoder(skinning: .bakeReferencePose).decode(data: still)
    let baked = try #require(reference.meshes.first).vertices
    let model = try GLBReader.read(still)
    let posed = try #require(model.pose().first)
    #expect(model.duration == nil)
    #expect(baked.count == posed.count)
    #expect(zip(baked, posed).allSatisfy { simd_distance($0.position, $1.position) < 0.00001 })
    #expect(simd_distance(posed[0].position, SIMD3(2, 0, 1.5)) < 0.00001)
    let expectedNormal = simd_normalize(SIMD3<Float>(0, -1, 1))
    #expect(simd_distance(posed[0].normal, expectedNormal) < 0.00001)
    let texture = try #require(reference.materials.first?.baseColorTexture)
    #expect(texture.mimeType == "image/png")
    #expect(model.meshes.first?.material.albedo == texture.encodedImage)
    #expect(model.meshes.first?.material.alphaCutoff == 0.5)
    let clip = try skinnedTriangle(animated: true)
    let animation = try GLBReader.read(clip)
    #expect(animation.duration == 1)
    let middle = try #require(animation.pose(at: 0.5).first)
    #expect(simd_distance(middle[0].position, SIMD3(3, 0, 1.5)) < 0.00001)
    #expect(throws: GLBImportError.self) { try GLBDecoder(skinning: .bakeReferencePose).decode(data: clip) }
}

/// An authored triangle and five joints with analytic positions and normals.
private func skinnedTriangle(animated: Bool) throws -> Data
{
    var binary = Data()
    var views: [[String: Int]] = []
    var accessors: [[String: Any]] = []
    func appendView(_ bytes: Data) -> Int
    {
        while !binary.count.isMultiple(of: 4) { binary.append(0) }
        let index = views.count
        views.append(["buffer": 0, "byteOffset": binary.count, "byteLength": bytes.count])
        binary.append(bytes)
        return index
    }
    func accessor(_ bytes: Data, _ type: String, _ componentType: Int, _ count: Int, _ bounds: [String: [Float]] = [:]) -> Int
    {
        let index = accessors.count
        var entry: [String: Any] = ["bufferView": appendView(bytes), "type": type, "componentType": componentType, "count": count]
        for (key, value) in bounds { entry[key] = value }
        accessors.append(entry)
        return index
    }
    func floats(_ values: [Float]) -> Data
    { values.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) } }

    let positions = accessor(floats([0, 0, 0, 1, 0, 0, 0, 1, 0]), "VEC3", 5126, 3, ["min": [0, 0, 0], "max": [1, 1, 0]])
    let normals = accessor(floats([0, 0, 1, 0, 0, 1, 0, 0, 1]), "VEC3", 5126, 3)
    let uv = accessor(floats([0, 0, 1, 0, 0, 1]), "VEC2", 5126, 3)
    let joints0 = accessor(Data([0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0]), "VEC4", 5121, 3)
    let weights0 = accessor(floats([0.125, 0.125, 0.125, 0.125, 1, 0, 0, 0, 1, 0, 0, 0]), "VEC4", 5126, 3)
    let joints1 = accessor(Data([4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), "VEC4", 5121, 3)
    let weights1 = accessor(floats([0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), "VEC4", 5126, 3)
    let indices = accessor(Data([0, 1, 2]), "SCALAR", 5121, 3)
    let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    var fifthBind = identity
    fifthBind[13] = -1
    let binds = accessor(floats(Array(repeating: identity, count: 4).flatMap { $0 } + fifthBind), "MAT4", 5126, 5)
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lF8AAAAASUVORK5CYII="))
    let image = appendView(png)
    let halfSqrt = sqrt(0.5)
    var json: [String: Any] = [
        "asset": ["version": "2.0"],
        "scene": 0,
        "scenes": [["nodes": [0, 6]]],
        "nodes": [
            ["children": [1, 2, 3, 4, 5], "translation": [2, 0, 0]],
            [:], [:], [:], [:],
            ["translation": [0, 0, 4], "rotation": [halfSqrt, 0, 0, halfSqrt]],
            ["mesh": 0, "skin": 0],
        ],
        "skins": [["joints": [1, 2, 3, 4, 5], "skeleton": 0, "inverseBindMatrices": binds]],
        "meshes": [["primitives": [[
            "attributes": ["POSITION": positions, "NORMAL": normals, "TEXCOORD_0": uv, "JOINTS_0": joints0, "WEIGHTS_0": weights0, "JOINTS_1": joints1, "WEIGHTS_1": weights1],
            "indices": indices,
            "material": 0,
        ]]]],
        "images": [["bufferView": image, "mimeType": "image/png"]],
        "textures": [["source": 0]],
        "materials": [["doubleSided": true, "alphaMode": "MASK", "alphaCutoff": 0.5,
                       "pbrMetallicRoughness": ["metallicFactor": 0, "roughnessFactor": 1, "baseColorTexture": ["index": 0]]]],
    ]
    if animated
    {
        let times = accessor(floats([0, 1]), "SCALAR", 5126, 2, ["min": [0], "max": [1]])
        let positions = accessor(floats([2, 0, 0, 4, 0, 0]), "VEC3", 5126, 2)
        json["animations"] = [[
            "samplers": [["input": times, "output": positions, "interpolation": "LINEAR"]],
            "channels": [["sampler": 0, "target": ["node": 0, "path": "translation"]]],
        ]]
    }
    json["accessors"] = accessors
    json["bufferViews"] = views
    while !binary.count.isMultiple(of: 4) { binary.append(0) }
    json["buffers"] = [["byteLength": binary.count]]
    var encoded = try JSONSerialization.data(withJSONObject: json)
    try #require(encoded.range(of: Data(#"image\/png"#.utf8)) != nil)
    while !encoded.count.isMultiple(of: 4) { encoded.append(32) }
    var glb = Data()
    for var word in [UInt32(0x46546C67), 2, UInt32(28 + encoded.count + binary.count), UInt32(encoded.count), 0x4E4F534A].map(\.littleEndian)
    { withUnsafeBytes(of: &word) { glb.append(contentsOf: $0) } }
    glb.append(encoded)
    for var word in [UInt32(binary.count), 0x004E4942].map(\.littleEndian)
    { withUnsafeBytes(of: &word) { glb.append(contentsOf: $0) } }
    glb.append(binary)
    return glb
}
