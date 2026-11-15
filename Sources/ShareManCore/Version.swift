/// Version shown by `shareman --version`.
///
/// The release workflow rewrites `current` with the tag being built, so that
/// the command-line tool and `ShareMan.app` always report the same version.
public enum ShareManVersion {
    public static let current = "1.0.0"
}
