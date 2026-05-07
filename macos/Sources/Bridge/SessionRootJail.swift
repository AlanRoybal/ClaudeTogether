import Foundation

/// Constrains shells spawned during a shared session to a chosen root
/// directory. Activation writes a temporary ZDOTDIR with a wrapper .zshrc
/// that sources the user's real rc files, then installs a `chpwd` hook that
/// snaps `$PWD` back into the root any time it escapes.
///
/// The jail is best-effort. It blocks casual `cd` navigation and shell
/// builtins that change cwd; it does not prevent absolute-path file reads or
/// subprocesses spawned outside zsh's control. True isolation would require
/// `sandbox-exec` or App Sandbox entitlements.
enum SessionRootJail {
    private static var zdotdir: URL?
    private(set) static var activeRoot: String?

    /// Activate the jail for `rootPath`. Subsequent shells spawned by
    /// `PTYSession.spawn` will inherit ZDOTDIR/CT_SESSION_ROOT and run the
    /// wrapper rc. Idempotent: re-activating with a new root replaces the
    /// previous tempdir and env.
    static func activate(rootPath: String) {
        deactivate()
        let normalized = URL(fileURLWithPath: rootPath)
            .standardizedFileURL.path
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoTTY-jail-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: tmp, withIntermediateDirectories: true)
        } catch {
            NSLog("SessionRootJail: tmp create failed: \(error)")
            return
        }
        let zshrc = tmp.appendingPathComponent(".zshrc")
        let body = wrapperZshrc(rootPath: normalized)
        do {
            try body.write(to: zshrc, atomically: true, encoding: .utf8)
        } catch {
            NSLog("SessionRootJail: rc write failed: \(error)")
            return
        }
        setenv("ZDOTDIR", tmp.path, 1)
        setenv("CT_SESSION_ROOT", normalized, 1)
        zdotdir = tmp
        activeRoot = normalized
    }

    static func deactivate() {
        unsetenv("ZDOTDIR")
        unsetenv("CT_SESSION_ROOT")
        if let z = zdotdir {
            try? FileManager.default.removeItem(at: z)
        }
        zdotdir = nil
        activeRoot = nil
    }

    /// True if `path` is the session root or a descendant. When no jail is
    /// active, every path is considered in-root.
    static func isInsideRoot(_ path: String) -> Bool {
        guard let root = activeRoot else { return true }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return p == root || p.hasPrefix(root + "/")
    }

    private static func wrapperZshrc(rootPath: String) -> String {
        // Single-quoted shell literal: escape embedded single quotes.
        let quoted = "'" + rootPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        # CoTTY session-root jail (auto-generated)
        # Re-source user's normal startup files so their environment is intact.
        # We deliberately keep ZDOTDIR pointed at our tempdir so subshells
        # spawned from this session also inherit the jail.
        [[ -f /etc/zshenv ]] && source /etc/zshenv
        [[ -f "$HOME/.zshenv" ]] && source "$HOME/.zshenv"
        [[ -o login ]] && [[ -f /etc/zprofile ]] && source /etc/zprofile
        [[ -o login ]] && [[ -f "$HOME/.zprofile" ]] && source "$HOME/.zprofile"
        [[ -f /etc/zshrc ]] && source /etc/zshrc
        [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc"
        [[ -o login ]] && [[ -f /etc/zlogin ]] && source /etc/zlogin
        [[ -o login ]] && [[ -f "$HOME/.zlogin" ]] && source "$HOME/.zlogin"

        export CT_SESSION_ROOT=\(quoted)

        __ct_jail_check() {
          emulate -L zsh
          case "$PWD/" in
            "$CT_SESSION_ROOT/"*) ;;
            *)
              print -P "%F{red}[CoTTY]%f path outside session root — returning to $CT_SESSION_ROOT" >&2
              builtin cd -- "$CT_SESSION_ROOT" 2>/dev/null
              ;;
          esac
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook chpwd __ct_jail_check

        builtin cd -- "$CT_SESSION_ROOT" 2>/dev/null
        """
    }
}
