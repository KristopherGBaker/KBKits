import Synchronization

/// The gate every test that ASSERTS on the process-global Open JTalk dictionary
/// configuration takes, and every test outside its own suite that WRITES it.
///
/// Swift Testing runs suites in parallel. That global is one variable for the whole process,
/// so a suite reading it while another restores it is flaky for reasons that have nothing to
/// do with the code under test, and this repo has already paid once for exactly that (see the
/// save-and-restore comment in `RetainedPerSurfaceTests`). A suite's own tests can be ordered
/// with `.serialized`; this is the part `.serialized` cannot do.
///
/// It lives in its own file, with no platform guard, because the suites that need it are
/// split across an Apple-only one (the download path) and a portable one.
let openJTalkConfigurationGate = Mutex<Void>(())
