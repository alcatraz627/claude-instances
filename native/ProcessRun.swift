import Foundation

/// Runs a program to completion and returns everything it printed.
///
/// Both pipes are read on background threads while the program runs. Waiting
/// for exit first and reading afterwards hangs forever once the output passes
/// the 64 KB pipe buffer: the program blocks writing and never exits.
func runCollecting(_ executable: String, _ arguments: [String],
                   environment: [String: String]? = nil) throws -> (out: Data, err: Data, status: Int32) {
    final class Box { var data = Data() }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    if let environment { task.environment = environment }
    let outPipe = Pipe(), errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    try task.run()

    let out = Box(), err = Box()
    let group = DispatchGroup()
    for (pipe, box) in [(outPipe, out), (errPipe, err)] {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
    }
    task.waitUntilExit()
    group.wait()
    return (out.data, err.data, task.terminationStatus)
}
