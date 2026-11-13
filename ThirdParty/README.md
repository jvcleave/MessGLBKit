# Native dependencies

The Swift package uses the macOS XCFrameworks in `Artifacts/`. Both contain arm64 and x86_64 slices.

| Dependency | Artifact and source |
| --- | --- |
| GLTFKit2 | `GLTFKit2.xcframework` is the unmodified `0.5.15-mess.3` release from [the GLTFKit2 fork](https://github.com/jvcleave/GLTFKit2/releases/tag/0.5.15-mess.3), at `b311913e0e8293c83021f5bb9253a00ffd7fb6ac`. Its upstream GLTFKit2 and cgltf sources are preserved in `Sources/GLTFKit2-0.5.15.tar.gz` at `e69e354c4f31ea07b7816b8cbe2ddb28e897d073`. |
| KTX-Software | GLTFKit2 embeds KTX 4.2.1 from `170e75893e3d232a2c4f241afe199256f8abb6f9`. The implementation is preserved in `Sources/KTX-Software-4.2.1.tar.gz`. |
| Draco | `Draco.xcframework` carries the macOS slice used by DracoSwift 1.5.7 at `3f85e64b4e62b070871dfdc1e26c058aaa1de63e`. The Google Draco source revision `8786740086a9f4d83f44aa83badfbea4dce7a1b5` and the original wrapper files are in the two Draco archives under `Sources/`. |

GLTFKit2, cgltf, and KTX notices are inside the framework. Draco and DracoSwift notices are in `Licenses/` and the Swift package resource bundle. Test fixtures carry their own attribution.

Run `shasum -a 256 -c ThirdParty/SHA256SUMS` from the repository root. To rebuild GLTFKit2, follow the [pinned fork build instructions](https://github.com/jvcleave/GLTFKit2/blob/b311913e0e8293c83021f5bb9253a00ffd7fb6ac/BUILD_MACOS.md) and pass the local KTX archive as `GLTFKIT2_KTX_ARCHIVE`.

For Draco, extract `Sources/draco-1.5.7.tar.gz` into a scratch directory and configure CMake with `CMAKE_BUILD_TYPE=Release`, `CMAKE_OSX_ARCHITECTURES=arm64;x86_64`, `CMAKE_OSX_DEPLOYMENT_TARGET=15.6`, and `DRACO_TESTS`, `DRACO_TRANSCODER_SUPPORTED`, `DRACO_UNITY_PLUGIN`, and `DRACO_MAYA_PLUGIN` set to `OFF`. Build `draco_static`. Package `libdraco.a` with the source headers and generated `draco/draco_features.h` using `xcodebuild -create-xcframework`.
