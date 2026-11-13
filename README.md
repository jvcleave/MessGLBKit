# MessGLBKit

Decode self-contained glTF 2.0 binary files into Swift values on macOS 15.6 or later. The package uses Swift 6.2 and includes universal macOS builds of GLTFKit2 and Draco.

## Decode geometry

```swift
import MessGLBKit

let geometry = try GLBDecoder(skinning: .bakeReferencePose).decode(data: glbBytes)
```

The geometry reader returns triangles with normals, top-left UVs, vertex colors, and base-color materials. It supports embedded PNG and JPEG images, texture transforms, and Draco-compressed triangles. Missing normals are generated per face. The reference-pose option evaluates authored joint transforms and all paired weight sets for stills. The geometry reader rejects animation clips.

## Sample skinned playback

```swift
let model = try GLBReader.read(glbBytes)
let pose = try model.pose(at: seconds)
```

The playback reader supports one scene with a shared rigid skeleton, indexed textured triangles, and an optional clip of linear translation and rotation channels on shared keys. A nil sample time returns the authored reference pose. Clip times are seconds in the file's coordinate frame. Use `GLBImportLimits` to set caller budgets. Call either reader on your worker.

## Build and test

```sh
swift test --scratch-path "${MESS_BUILD_CACHE_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds}/MessGLBKit/swiftpm"
```

Both native frameworks come with the checkout. See [native dependency provenance](ThirdParty/README.md) for pinned versions, notices, and rebuild sources.
