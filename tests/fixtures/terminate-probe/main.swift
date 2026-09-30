import Foundation

// Compiled with native/Terminate.swift alone. Starts a real `sleep`, then:
// a stale start time (a reused pid) must not be signalled, no start time must
// not be signalled, and the right start time must end the process.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/bin/sleep")
task.arguments = ["60"]
try task.run()
let pid = task.processIdentifier
usleep(200_000)
guard let start = processStartTime(pid) else { print("no-start-time"); exit(1) }

let wrong = terminateSessions([(pid, start - 100)], grace: 0.3)
let unknown = terminateSessions([(pid, nil)], grace: 0.3)
usleep(600_000)
let aliveAfterRefusals = task.isRunning

let sem = DispatchSemaphore(value: 0)
let right = terminateSessions([(pid, start)], grace: 0.3) { sem.signal() }
_ = sem.wait(timeout: .now() + 5)
usleep(300_000)
print("wrong=\(wrong.count) unknown=\(unknown.count) alive=\(aliveAfterRefusals) right=\(right.count) ended=\(!task.isRunning)")
if task.isRunning { task.terminate() }
