/// kernel_dart — Main executable entry point.
///
/// Delegates directly to the CLI implementation so the `kernel_dart`
/// pub-global executable is a thin wrapper.
library;

import 'cli.dart' as cli;

Future<void> main(List<String> args) => cli.main(args);
