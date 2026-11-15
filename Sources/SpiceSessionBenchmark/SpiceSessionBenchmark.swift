import AppKit
import Darwin

@main
struct SpiceSessionBenchmark {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--help") {
            print(BenchmarkConfiguration.help)
            return
        }
        do {
            let configuration = try BenchmarkConfiguration.parse(
                Array(CommandLine.arguments.dropFirst()))
            let delegate = BenchmarkApplicationDelegate(configuration: configuration)
            if configuration.headless {
                delegate.start()
                // A headless observation needs the async executor, not an
                // NSApplication or a WindowServer connection.
                withExtendedLifetime(delegate) { dispatchMain() }
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            SessionBenchmark.progress(String(describing: error))
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

@MainActor
private final class BenchmarkApplicationDelegate: NSObject, NSApplicationDelegate {
    private let configuration: BenchmarkConfiguration
    private var task: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []

    init(configuration: BenchmarkConfiguration) { self.configuration = configuration }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        // Dispatch sources own signal handling for this process. Their only job
        // is to cancel the run, whose async cleanup closes channels and views.
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.task?.cancel() }
            }
            source.resume()
            signalSources.append(source)
        }
        task = Task {
            let success: Bool
            if let fixture = configuration.fixtureURL {
                success = await transferFixture(fixture, configuration: configuration)
            } else {
                success = await SessionBenchmark(configuration: configuration).run()
            }
            signalSources.forEach { $0.cancel() }
            Darwin.exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        task?.cancel()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
