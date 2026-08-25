import Foundation

private final class SpiceMetalShaderBundleFinder {}

/// Relocatable lookup for Metal libraries emitted into SwiftPM resource bundles.
///
/// A resource bundle embedded in an application is a macOS bundle whose files
/// live below `Contents/Resources`; appending a filename to the outer `.bundle`
/// URL therefore only works in development layouts. `Bundle` owns that layout
/// distinction and keeps release applications independent of build-machine
/// paths.
package enum SpiceMetalShaderLibraryLocator {
    package static func libraryURL(
        resourceBundleName: String,
        searchRoots: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        for root in searchRoots {
            let resourceBundleURL = root.appending(path: resourceBundleName)
            guard let resourceBundle = Bundle(url: resourceBundleURL),
                  let libraryURL = resourceBundle.url(
                      forResource: "SpiceVideoCompositor",
                      withExtension: "metallib"
                  ),
                  fileManager.fileExists(atPath: libraryURL.path())
            else {
                continue
            }
            return libraryURL
        }
        return nil
    }

    package static func mainBundleSearchRoots(_ bundle: Bundle = .main) -> [URL] {
        var roots: [URL] = []
        for candidateBundle in [bundle, Bundle(for: SpiceMetalShaderBundleFinder.self)] {
            if let resourceURL = candidateBundle.resourceURL,
               !roots.contains(resourceURL)
            {
                roots.append(resourceURL)
            }
            if let executableURL = candidateBundle.executableURL {
                let executableDirectory = executableURL.deletingLastPathComponent()
                if !roots.contains(executableDirectory) {
                    roots.append(executableDirectory)
                }
            }
            let bundleURL = candidateBundle.bundleURL
            if !roots.contains(bundleURL) {
                roots.append(bundleURL)
            }
        }
        return roots
    }
}
