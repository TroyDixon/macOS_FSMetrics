import Darwin
import Foundation

// Top-level code is async-capable, so call the CLI directly and exit with the
// status it reports (0 success, 1 runtime failure, 2 usage/config error).
let status = await FSMetricsCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
