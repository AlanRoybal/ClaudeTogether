import Foundation

/// Token classes the renderer knows about. The colour each one resolves
/// to is decided by `SyntaxPalette` -- `.identifier` and `.plain` map to
/// "no override" so the default foreground keeps showing through.
enum TokenKind: Equatable {
    case keyword
    case type
    case string
    case comment
    case number
    case `operator`
    case identifier
    case plain
}

/// A coloured run inside a single source line. `startColumn` and
/// `length` are measured in Unicode scalars -- same coordinate system
/// the editor grid model uses, so the renderer can plug spans in
/// without any translation step.
struct HighlightSpan: Equatable {
    let line: Int
    let startColumn: Int
    let length: Int
    let kind: TokenKind
}

/// All languages the highlighter can detect. `.plain` is the fallback
/// when the document extension is unrecognized -- it produces zero
/// spans and the renderer just uses the default foreground colour.
enum Language: String, CaseIterable {
    case swift
    case zig
    case python
    case javascript
    case typescript
    case rust
    case c
    case cpp
    case objc
    case go
    case java
    case ruby
    case markdown
    case json
    case yaml
    case html
    case shell
    case plain
}

/// Per-language token data. The tokenizer walks Unicode scalars and
/// matches against this struct, so sets and delimiter strings stay
/// pure-Swift (no NSRegularExpression).
struct LanguageRules {
    let keywords: Set<String>
    let types: Set<String>
    let lineComment: String?
    let blockComment: (open: String, close: String)?
    /// Quote characters that open a string. Each delimiter is closed
    /// by the same scalar (we don't model raw-string variants).
    let stringDelimiters: [Character]
    /// Whether an unterminated string can wrap onto the next line.
    /// JS/TS template literals would say true, but we keep it conservative.
    let allowNewlineInString: Bool
    /// If true, identifiers may include the `$` scalar. Set for JS/TS/Shell.
    let identifierAllowsDollar: Bool
}

/// Fixed RGB colours per token class. Only the dark palette is used at
/// the moment -- a light theme is provided so future code can pick.
/// Identifier / plain return nil so the renderer keeps whatever default
/// foreground the cell came in with.
enum SyntaxPalette {
    enum Theme { case dark, light }

    static func color(for kind: TokenKind, theme: Theme = .dark) -> UInt32? {
        switch theme {
        case .dark:
            switch kind {
            case .keyword: return 0xCF8FFF
            case .type: return 0x4FC1FF
            case .string: return 0xC3E88D
            case .comment: return 0x676E95
            case .number: return 0xF78C6C
            case .operator: return 0x89DDFF
            case .identifier, .plain: return nil
            }
        case .light:
            switch kind {
            case .keyword: return 0x6F42C1
            case .type: return 0x005CC5
            case .string: return 0x22863A
            case .comment: return 0x6A737D
            case .number: return 0xB45F06
            case .operator: return 0x005CC5
            case .identifier, .plain: return nil
            }
        }
    }
}

// MARK: - Public API

enum SyntaxHighlighter {
    /// Skip syntax work entirely above this size to keep big paste buffers
    /// or accidental log files from blocking the main actor.
    static let maxBytesForFullTokenize: Int = 500 * 1024

    /// Map a session-relative or absolute path to a `Language` based on
    /// the file extension and (for ambiguous cases) the file name.
    static func detectLanguage(forPath path: String) -> Language {
        let lower = (path as NSString).lastPathComponent.lowercased()
        // Special-case dotfiles / well-known names.
        switch lower {
        case "makefile", "gnumakefile":
            return .shell
        case "dockerfile":
            return .shell
        case ".bashrc", ".zshrc", ".profile", ".bash_profile":
            return .shell
        default:
            break
        }

        let ext: String
        if let dot = lower.lastIndex(of: ".") {
            ext = String(lower[lower.index(after: dot)...])
        } else {
            return .plain
        }

        switch ext {
        case "swift": return .swift
        case "zig": return .zig
        case "py", "pyi": return .python
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "tsx": return .typescript
        case "rs": return .rust
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hpp", "hxx", "h++": return .cpp
        case "m", "mm": return .objc
        case "go": return .go
        case "java": return .java
        case "rb", "rbi", "gemspec": return .ruby
        case "md", "markdown": return .markdown
        case "json", "json5": return .json
        case "yaml", "yml": return .yaml
        case "html", "htm", "xhtml": return .html
        case "sh", "bash", "zsh", "fish": return .shell
        default: return .plain
        }
    }

    /// Tokenize an entire document. Spans are emitted in scan order so
    /// `EditorGridModel` can group by line and do an O(line-spans)
    /// scan per glyph. Cached by content hash + language; subsequent
    /// calls with identical input return the same array reference.
    static func tokenize(_ text: String, language: Language) -> [HighlightSpan] {
        if language == .plain { return [] }
        if text.utf8.count > maxBytesForFullTokenize { return [] }

        let cacheKey = CacheKey(hash: hashText(text), language: language)
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let spans: [HighlightSpan]
        switch language {
        case .markdown:
            spans = MarkdownTokenizer.tokenize(text)
        case .html:
            spans = HtmlTokenizer.tokenize(text)
        case .json:
            spans = StructuredTokenizer.tokenizeJson(text)
        case .yaml:
            spans = StructuredTokenizer.tokenizeYaml(text)
        default:
            spans = GenericTokenizer.tokenize(text, rules: rules(for: language))
        }

        cacheLock.lock()
        if cache.count >= maxCacheEntries {
            cache.removeAll(keepingCapacity: true)
        }
        cache[cacheKey] = spans
        cacheLock.unlock()
        return spans
    }

    // MARK: Cache

    private struct CacheKey: Hashable {
        let hash: UInt64
        let language: Language
    }

    /// `[CacheKey: [HighlightSpan]]` is a coarse cache -- when the user
    /// types we discard the whole entry on the next call. For typical
    /// editing this stays at a single live entry.
    private static var cache: [CacheKey: [HighlightSpan]] = [:]
    private static let cacheLock = NSLock()
    private static let maxCacheEntries = 8

    /// FNV-1a 64-bit over the UTF-8 bytes. Good enough for cache
    /// keying -- collisions don't cause correctness issues, just a
    /// stale recompute.
    private static func hashText(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return h
    }
}

// MARK: - Built-in rules

extension SyntaxHighlighter {
    static func rules(for language: Language) -> LanguageRules {
        switch language {
        case .swift: return Self.swiftRules
        case .zig: return Self.zigRules
        case .python: return Self.pythonRules
        case .javascript: return Self.javascriptRules
        case .typescript: return Self.typescriptRules
        case .rust: return Self.rustRules
        case .c: return Self.cRules
        case .cpp: return Self.cppRules
        case .objc: return Self.objcRules
        case .go: return Self.goRules
        case .java: return Self.javaRules
        case .ruby: return Self.rubyRules
        case .shell: return Self.shellRules
        // The dedicated tokenizers don't consult LanguageRules, but
        // returning a sensible default keeps the type total.
        case .markdown, .json, .yaml, .html, .plain:
            return LanguageRules(
                keywords: [],
                types: [],
                lineComment: nil,
                blockComment: nil,
                stringDelimiters: [],
                allowNewlineInString: false,
                identifierAllowsDollar: false)
        }
    }

    private static let swiftRules = LanguageRules(
        keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
            "func", "import", "init", "inout", "internal", "let", "open", "operator",
            "private", "protocol", "public", "rethrows", "static", "struct", "subscript",
            "typealias", "var", "break", "case", "continue", "default", "defer", "do",
            "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
            "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil",
            "super", "self", "Self", "throw", "throws", "true", "try", "_", "async",
            "await", "actor", "some", "any", "willSet", "didSet", "get", "set"
        ],
        types: [
            "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16",
            "UInt32", "UInt64", "Float", "Double", "Bool", "String", "Character",
            "Optional", "Array", "Dictionary", "Set", "Result", "Error", "Void",
            "Data", "URL", "Date", "Range", "ClosedRange", "AnyObject", "AnyClass"
        ],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let zigRules = LanguageRules(
        keywords: [
            "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm",
            "async", "await", "break", "callconv", "catch", "comptime", "const",
            "continue", "defer", "else", "enum", "errdefer", "error", "export",
            "extern", "fn", "for", "if", "inline", "linksection", "noalias",
            "noinline", "nosuspend", "or", "orelse", "packed", "pub", "resume",
            "return", "struct", "suspend", "switch", "test", "threadlocal", "try",
            "union", "unreachable", "usingnamespace", "var", "volatile", "while",
            "false", "true", "null", "undefined"
        ],
        types: [
            "bool", "void", "noreturn", "type", "anyerror", "comptime_int",
            "comptime_float", "f16", "f32", "f64", "f80", "f128",
            "u8", "u16", "u32", "u64", "u128", "usize",
            "i8", "i16", "i32", "i64", "i128", "isize",
            "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong",
            "c_longlong", "c_ulonglong", "c_longdouble"
        ],
        lineComment: "//",
        blockComment: nil,
        stringDelimiters: ["\""],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let pythonRules = LanguageRules(
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await",
            "break", "class", "continue", "def", "del", "elif", "else", "except",
            "finally", "for", "from", "global", "if", "import", "in", "is",
            "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
            "while", "with", "yield", "match", "case", "self", "cls"
        ],
        types: [
            "int", "float", "complex", "bool", "str", "bytes", "bytearray",
            "list", "tuple", "dict", "set", "frozenset", "object", "type",
            "Any", "Optional", "Union", "List", "Dict", "Tuple", "Set",
            "Callable", "Iterator", "Iterable", "Generator"
        ],
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let javascriptRules = LanguageRules(
        keywords: [
            "break", "case", "catch", "class", "const", "continue", "debugger",
            "default", "delete", "do", "else", "export", "extends", "finally",
            "for", "function", "if", "import", "in", "instanceof", "new",
            "return", "super", "switch", "this", "throw", "try", "typeof",
            "var", "void", "while", "with", "yield", "let", "static", "async",
            "await", "of", "from", "as", "true", "false", "null", "undefined"
        ],
        types: [
            "Array", "Boolean", "Date", "Error", "Function", "JSON", "Math",
            "Number", "Object", "Promise", "RegExp", "String", "Symbol", "Map",
            "Set", "WeakMap", "WeakSet", "Int8Array", "Uint8Array", "Int16Array",
            "Uint16Array", "Int32Array", "Uint32Array", "Float32Array", "Float64Array"
        ],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'", "`"],
        allowNewlineInString: true,
        identifierAllowsDollar: true)

    private static let typescriptRules = LanguageRules(
        keywords: javascriptRules.keywords.union([
            "abstract", "any", "as", "asserts", "boolean", "constructor", "declare",
            "enum", "from", "get", "implements", "infer", "interface", "is",
            "keyof", "module", "namespace", "never", "package", "private",
            "protected", "public", "readonly", "require", "set", "type", "unknown"
        ]),
        types: javascriptRules.types.union([
            "string", "number", "boolean", "any", "void", "never", "unknown",
            "object", "bigint", "Record", "Partial", "Required", "Readonly",
            "Pick", "Omit", "Awaited"
        ]),
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'", "`"],
        allowNewlineInString: true,
        identifierAllowsDollar: true)

    private static let rustRules = LanguageRules(
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
            "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "true", "type",
            "unsafe", "use", "where", "while", "abstract", "become", "box", "do",
            "final", "macro", "override", "priv", "typeof", "unsized", "virtual",
            "yield", "try", "union"
        ],
        types: [
            "bool", "char", "i8", "i16", "i32", "i64", "i128", "isize",
            "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64",
            "str", "String", "Vec", "Box", "Option", "Result", "Rc", "Arc",
            "RefCell", "Cell", "Mutex", "RwLock", "HashMap", "HashSet", "BTreeMap",
            "BTreeSet", "VecDeque", "LinkedList"
        ],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let cRules = LanguageRules(
        keywords: [
            "auto", "break", "case", "const", "continue", "default", "do",
            "else", "enum", "extern", "for", "goto", "if", "register", "restrict",
            "return", "sizeof", "static", "struct", "switch", "typedef", "union",
            "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool",
            "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert",
            "_Thread_local", "inline", "true", "false", "NULL"
        ],
        types: [
            "void", "char", "short", "int", "long", "float", "double", "signed",
            "unsigned", "size_t", "ssize_t", "ptrdiff_t", "uintptr_t", "intptr_t",
            "int8_t", "int16_t", "int32_t", "int64_t",
            "uint8_t", "uint16_t", "uint32_t", "uint64_t",
            "FILE", "bool"
        ],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let cppRules = LanguageRules(
        keywords: cRules.keywords.union([
            "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor",
            "catch", "class", "compl", "concept", "constexpr", "constinit",
            "consteval", "const_cast", "decltype", "delete", "dynamic_cast",
            "explicit", "export", "false", "friend", "final", "module",
            "mutable", "namespace", "new", "noexcept", "not", "not_eq",
            "nullptr", "operator", "or", "or_eq", "override", "private",
            "protected", "public", "reflexpr", "reinterpret_cast", "requires",
            "static_assert", "static_cast", "synchronized", "template",
            "this", "thread_local", "throw", "true", "try", "typeid",
            "typename", "using", "virtual", "wchar_t", "xor", "xor_eq",
            "co_await", "co_return", "co_yield"
        ]),
        types: cRules.types.union([
            "string", "wstring", "vector", "map", "unordered_map", "set",
            "unordered_set", "list", "deque", "array", "tuple", "pair",
            "shared_ptr", "unique_ptr", "weak_ptr", "function", "atomic",
            "auto"
        ]),
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let objcRules = LanguageRules(
        keywords: cRules.keywords.union([
            "@interface", "@implementation", "@protocol", "@end", "@property",
            "@synthesize", "@dynamic", "@class", "@selector", "@encode",
            "@synchronized", "@autoreleasepool", "@try", "@catch", "@finally",
            "@throw", "@public", "@protected", "@private", "@package",
            "self", "super", "nil", "Nil", "YES", "NO", "BOOL",
            "id", "Class", "SEL", "IMP", "in", "out", "inout", "bycopy",
            "byref", "oneway", "instancetype", "weak", "strong", "atomic",
            "nonatomic", "readwrite", "readonly", "copy", "assign", "retain",
            "nullable", "nonnull"
        ]),
        types: cRules.types.union([
            "NSObject", "NSString", "NSArray", "NSDictionary", "NSSet",
            "NSNumber", "NSData", "NSDate", "NSURL", "NSError", "NSInteger",
            "NSUInteger", "CGFloat", "CGRect", "CGPoint", "CGSize"
        ]),
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let goRules = LanguageRules(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
            "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var", "true", "false", "iota", "nil"
        ],
        types: [
            "bool", "byte", "complex64", "complex128", "error", "float32",
            "float64", "int", "int8", "int16", "int32", "int64", "rune",
            "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
            "any"
        ],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "`"],
        allowNewlineInString: true,
        identifierAllowsDollar: false)

    private static let javaRules = LanguageRules(
        keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch",
            "char", "class", "const", "continue", "default", "do", "double",
            "else", "enum", "extends", "final", "finally", "float", "for",
            "goto", "if", "implements", "import", "instanceof", "int",
            "interface", "long", "native", "new", "package", "private",
            "protected", "public", "return", "short", "static", "strictfp",
            "super", "switch", "synchronized", "this", "throw", "throws",
            "transient", "try", "void", "volatile", "while", "true", "false",
            "null", "var", "yield", "record", "sealed", "permits"
        ],
        types: [
            "String", "Object", "Integer", "Double", "Float", "Long", "Short",
            "Byte", "Character", "Boolean", "Number", "Class", "Throwable",
            "Exception", "RuntimeException", "Error", "List", "ArrayList",
            "Map", "HashMap", "Set", "HashSet", "Collection", "Iterable",
            "Iterator", "Optional", "Stream"
        ],
        lineComment: "//",
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let rubyRules = LanguageRules(
        keywords: [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
            "def", "do", "else", "elsif", "end", "ensure", "false",
            "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
            "rescue", "retry", "return", "self", "super", "then", "true",
            "undef", "unless", "until", "when", "while", "yield", "require",
            "require_relative", "include", "extend", "attr_accessor", "attr_reader",
            "attr_writer", "lambda", "proc", "puts", "print"
        ],
        types: [
            "Integer", "Float", "Numeric", "String", "Symbol", "Array",
            "Hash", "Range", "Regexp", "Class", "Module", "Object", "Kernel",
            "Comparable", "Enumerable", "Exception", "StandardError",
            "TrueClass", "FalseClass", "NilClass"
        ],
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        allowNewlineInString: false,
        identifierAllowsDollar: false)

    private static let shellRules = LanguageRules(
        keywords: [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "select",
            "while", "until", "do", "done", "in", "function", "time", "coproc",
            "return", "exit", "break", "continue", "shift", "set", "unset",
            "export", "readonly", "local", "declare", "typeset", "trap", "echo",
            "printf", "read", "test", "true", "false", "alias", "unalias",
            "source", "eval", "exec"
        ],
        types: [],
        lineComment: "#",
        blockComment: nil,
        stringDelimiters: ["\"", "'"],
        allowNewlineInString: true,
        identifierAllowsDollar: true)
}

// MARK: - Generic C-family / brace tokenizer

private enum GenericTokenizer {
    static func tokenize(_ text: String, rules: LanguageRules) -> [HighlightSpan] {
        let scalars = Array(text.unicodeScalars)
        let lineLengths = computeLineLengths(scalars: scalars)

        var spans: [HighlightSpan] = []
        spans.reserveCapacity(scalars.count / 8)

        var i = 0
        var line = 0
        var col = 0

        let openBlock = rules.blockComment.map { Array($0.open.unicodeScalars) }
        let closeBlock = rules.blockComment.map { Array($0.close.unicodeScalars) }
        let lineCommentScalars = rules.lineComment.map { Array($0.unicodeScalars) }
        let stringDelimSet: Set<UInt32> = Set(rules.stringDelimiters.flatMap {
            $0.unicodeScalars.map { $0.value }
        })

        @inline(__always) func advance() {
            if scalars[i].value == 0x0A {
                line += 1
                col = 0
            } else {
                col += 1
            }
            i += 1
        }

        @inline(__always) func matches(_ pattern: [UnicodeScalar]) -> Bool {
            if pattern.isEmpty { return false }
            if i + pattern.count > scalars.count { return false }
            for k in 0..<pattern.count {
                if scalars[i + k] != pattern[k] { return false }
            }
            return true
        }

        while i < scalars.count {
            let c = scalars[i]

            // Whitespace and newlines just advance.
            if c.value == 0x0A || c.value == 0x20 || c.value == 0x09 {
                advance()
                continue
            }

            // Block comment first -- opening sequence may overlap with
            // line-comment ("/*" vs "//"), so check this side first.
            if let open = openBlock, let close = closeBlock,
               matches(open)
            {
                let startLine = line
                let startCol = col
                for _ in 0..<open.count { advance() }
                while i < scalars.count, !matches(close) {
                    advance()
                }
                if i < scalars.count {
                    for _ in 0..<close.count { advance() }
                }
                emitMultiline(into: &spans,
                              lineLengths: lineLengths,
                              startLine: startLine,
                              startCol: startCol,
                              endLine: line,
                              endCol: col,
                              kind: .comment)
                continue
            }

            if let lc = lineCommentScalars, matches(lc) {
                let startCol = col
                let startLine = line
                while i < scalars.count, scalars[i].value != 0x0A {
                    advance()
                }
                spans.append(HighlightSpan(
                    line: startLine,
                    startColumn: startCol,
                    length: col - startCol,
                    kind: .comment))
                continue
            }

            // String literals.
            if stringDelimSet.contains(c.value) {
                let delim = c
                let startLine = line
                let startCol = col
                advance() // opening quote
                while i < scalars.count {
                    let s = scalars[i]
                    if s.value == 0x5C, i + 1 < scalars.count {
                        advance()
                        advance()
                        continue
                    }
                    if s == delim {
                        advance()
                        break
                    }
                    if s.value == 0x0A, !rules.allowNewlineInString {
                        break
                    }
                    advance()
                }
                emitMultiline(into: &spans,
                              lineLengths: lineLengths,
                              startLine: startLine,
                              startCol: startCol,
                              endLine: line,
                              endCol: col,
                              kind: .string)
                continue
            }

            // Numbers (must run before "operator" check so 0x.. and 1.5 work).
            if isAsciiDigit(c) ||
                (c.value == 0x2E && i + 1 < scalars.count && isAsciiDigit(scalars[i + 1]))
            {
                let startCol = col
                let startLine = line
                var sawDot = false
                while i < scalars.count {
                    let s = scalars[i]
                    if isAsciiDigit(s) || isAsciiLetter(s) || s.value == 0x5F {
                        advance()
                    } else if s.value == 0x2E, !sawDot,
                              i + 1 < scalars.count, isAsciiDigit(scalars[i + 1])
                    {
                        sawDot = true
                        advance()
                    } else {
                        break
                    }
                }
                spans.append(HighlightSpan(
                    line: startLine,
                    startColumn: startCol,
                    length: col - startCol,
                    kind: .number))
                continue
            }

            // Identifiers / keywords / types.
            if isIdentStart(c, dollar: rules.identifierAllowsDollar) ||
                (c.value == 0x40 /* @ */)
            {
                let startCol = col
                let startLine = line
                var ident = ""
                if c.value == 0x40 {
                    ident.append("@")
                    advance()
                }
                while i < scalars.count,
                      isIdentContinue(scalars[i], dollar: rules.identifierAllowsDollar)
                {
                    ident.append(Character(scalars[i]))
                    advance()
                }
                if ident.isEmpty {
                    advance()
                    continue
                }
                let kind: TokenKind
                if rules.keywords.contains(ident) {
                    kind = .keyword
                } else if rules.types.contains(ident) {
                    kind = .type
                } else if Self.looksLikeTypeName(ident) {
                    kind = .type
                } else {
                    kind = .identifier
                }
                if kind != .identifier {
                    spans.append(HighlightSpan(
                        line: startLine,
                        startColumn: startCol,
                        length: col - startCol,
                        kind: kind))
                }
                continue
            }

            if isOperatorScalar(c) {
                spans.append(HighlightSpan(
                    line: line,
                    startColumn: col,
                    length: 1,
                    kind: .operator))
                advance()
                continue
            }

            // Anything else (punctuation outside our operator set, control
            // characters, etc.) -- leave with default colour.
            advance()
        }

        return spans
    }

    private static func computeLineLengths(scalars: [UnicodeScalar]) -> [Int] {
        var out: [Int] = []
        var current = 0
        for s in scalars {
            if s.value == 0x0A {
                out.append(current)
                current = 0
            } else {
                current += 1
            }
        }
        out.append(current)
        return out
    }

    /// Identifiers starting with an uppercase ASCII letter are flagged
    /// as types. This is the cheap heuristic used by most hand-written
    /// editor tokenizers -- accurate enough for syntax colouring.
    private static func looksLikeTypeName(_ ident: String) -> Bool {
        guard let first = ident.unicodeScalars.first else { return false }
        guard first.value >= 0x41, first.value <= 0x5A else { return false }
        // Reject ALL_CAPS -- those are usually constants.
        var hasLower = false
        for s in ident.unicodeScalars where s.value >= 0x61 && s.value <= 0x7A {
            hasLower = true
            break
        }
        return hasLower
    }

    @inline(__always)
    private static func isAsciiDigit(_ s: UnicodeScalar) -> Bool {
        s.value >= 0x30 && s.value <= 0x39
    }

    @inline(__always)
    private static func isAsciiLetter(_ s: UnicodeScalar) -> Bool {
        (s.value >= 0x41 && s.value <= 0x5A) ||
        (s.value >= 0x61 && s.value <= 0x7A)
    }

    @inline(__always)
    private static func isIdentStart(_ s: UnicodeScalar, dollar: Bool) -> Bool {
        if isAsciiLetter(s) || s.value == 0x5F { return true }
        if dollar && s.value == 0x24 { return true }
        return false
    }

    @inline(__always)
    private static func isIdentContinue(_ s: UnicodeScalar, dollar: Bool) -> Bool {
        if isAsciiLetter(s) || isAsciiDigit(s) || s.value == 0x5F { return true }
        if dollar && s.value == 0x24 { return true }
        return false
    }

    @inline(__always)
    private static func isOperatorScalar(_ s: UnicodeScalar) -> Bool {
        switch s.value {
        case 0x2B, 0x2D, 0x2A, 0x2F, 0x25,                  // + - * / %
             0x3C, 0x3E, 0x3D, 0x21, 0x26, 0x7C, 0x5E, 0x7E, // < > = ! & | ^ ~
             0x3F, 0x3A, 0x2E, 0x2C, 0x3B,                   // ? : . , ;
             0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D:             // ( ) [ ] { }
            return true
        default:
            return false
        }
    }
}

// MARK: - Multi-line span helper (shared by all tokenizers)

private func emitMultiline(into spans: inout [HighlightSpan],
                           lineLengths: [Int],
                           startLine: Int,
                           startCol: Int,
                           endLine: Int,
                           endCol: Int,
                           kind: TokenKind)
{
    if startLine == endLine {
        let len = endCol - startCol
        if len > 0 {
            spans.append(HighlightSpan(
                line: startLine,
                startColumn: startCol,
                length: len,
                kind: kind))
        }
        return
    }
    // First line: from startCol to that line's length.
    if startLine < lineLengths.count {
        let firstLen = max(0, lineLengths[startLine] - startCol)
        if firstLen > 0 {
            spans.append(HighlightSpan(
                line: startLine,
                startColumn: startCol,
                length: firstLen,
                kind: kind))
        }
    }
    // Whole intermediate lines.
    var ln = startLine + 1
    while ln < endLine, ln < lineLengths.count {
        let len = lineLengths[ln]
        if len > 0 {
            spans.append(HighlightSpan(
                line: ln,
                startColumn: 0,
                length: len,
                kind: kind))
        }
        ln += 1
    }
    // Final line: 0..endCol.
    if endLine < lineLengths.count, endCol > 0 {
        spans.append(HighlightSpan(
            line: endLine,
            startColumn: 0,
            length: endCol,
            kind: kind))
    }
}

// MARK: - Markdown tokenizer

private enum MarkdownTokenizer {
    /// Markdown's grammar is wildly different from C-family code so it
    /// gets its own scanner. Headings, fenced code blocks, inline code,
    /// list bullets, and link/image syntax all map onto our existing
    /// token classes.
    static func tokenize(_ text: String) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        var inFence = false

        for (lineIndex, lineSub) in lines.enumerated() {
            let lineString = String(lineSub)
            let scalars = Array(lineString.unicodeScalars)
            let count = scalars.count

            // Fenced code block toggle (``` or ~~~ at start of line, possibly
            // after whitespace).
            var firstNonWs = 0
            while firstNonWs < count,
                  scalars[firstNonWs].value == 0x20 ||
                  scalars[firstNonWs].value == 0x09
            {
                firstNonWs += 1
            }
            if firstNonWs + 2 < count {
                let f0 = scalars[firstNonWs]
                let f1 = scalars[firstNonWs + 1]
                let f2 = scalars[firstNonWs + 2]
                if (f0.value == 0x60 && f1.value == 0x60 && f2.value == 0x60) ||
                   (f0.value == 0x7E && f1.value == 0x7E && f2.value == 0x7E)
                {
                    inFence.toggle()
                    spans.append(HighlightSpan(
                        line: lineIndex,
                        startColumn: 0,
                        length: count,
                        kind: .string))
                    continue
                }
            }

            if inFence {
                if count > 0 {
                    spans.append(HighlightSpan(
                        line: lineIndex,
                        startColumn: 0,
                        length: count,
                        kind: .string))
                }
                continue
            }

            // Heading lines (#, ##, ...).
            if firstNonWs < count, scalars[firstNonWs].value == 0x23 {
                spans.append(HighlightSpan(
                    line: lineIndex,
                    startColumn: 0,
                    length: count,
                    kind: .keyword))
                continue
            }

            // Block quote prefix.
            if firstNonWs < count, scalars[firstNonWs].value == 0x3E {
                spans.append(HighlightSpan(
                    line: lineIndex,
                    startColumn: firstNonWs,
                    length: 1,
                    kind: .operator))
            }

            // Inline scan for `code`, **bold**, *em*, [link], horizontal rules.
            var i = 0
            while i < count {
                let s = scalars[i]
                // Inline code.
                if s.value == 0x60 {
                    let start = i
                    i += 1
                    while i < count, scalars[i].value != 0x60 { i += 1 }
                    if i < count { i += 1 }
                    spans.append(HighlightSpan(
                        line: lineIndex,
                        startColumn: start,
                        length: i - start,
                        kind: .string))
                    continue
                }
                // **bold** / __bold__
                if i + 1 < count,
                   (s.value == 0x2A || s.value == 0x5F),
                   scalars[i + 1] == s
                {
                    let start = i
                    let mark = s
                    i += 2
                    while i + 1 < count, !(scalars[i] == mark && scalars[i + 1] == mark) {
                        i += 1
                    }
                    if i + 1 < count { i += 2 }
                    spans.append(HighlightSpan(
                        line: lineIndex,
                        startColumn: start,
                        length: i - start,
                        kind: .type))
                    continue
                }
                // *em* / _em_
                if s.value == 0x2A || s.value == 0x5F {
                    let mark = s
                    let start = i
                    i += 1
                    while i < count, scalars[i] != mark { i += 1 }
                    if i < count { i += 1 }
                    if i - start >= 2 {
                        spans.append(HighlightSpan(
                            line: lineIndex,
                            startColumn: start,
                            length: i - start,
                            kind: .number))
                    }
                    continue
                }
                // [link text](url)
                if s.value == 0x5B {
                    let start = i
                    var depth = 1
                    i += 1
                    while i < count, depth > 0 {
                        if scalars[i].value == 0x5B { depth += 1 }
                        else if scalars[i].value == 0x5D { depth -= 1 }
                        i += 1
                    }
                    // Optional (url)
                    if i < count, scalars[i].value == 0x28 {
                        while i < count, scalars[i].value != 0x29 { i += 1 }
                        if i < count { i += 1 }
                    }
                    spans.append(HighlightSpan(
                        line: lineIndex,
                        startColumn: start,
                        length: i - start,
                        kind: .operator))
                    continue
                }
                i += 1
            }
        }
        return spans
    }
}

// MARK: - HTML tokenizer

private enum HtmlTokenizer {
    static func tokenize(_ text: String) -> [HighlightSpan] {
        let scalars = Array(text.unicodeScalars)
        let lineLengths = computeLineLengths(scalars: scalars)
        var spans: [HighlightSpan] = []
        var i = 0
        var line = 0
        var col = 0

        @inline(__always) func advance() {
            if scalars[i].value == 0x0A { line += 1; col = 0 } else { col += 1 }
            i += 1
        }

        @inline(__always) func matches(_ s: String) -> Bool {
            let p = Array(s.unicodeScalars)
            if i + p.count > scalars.count { return false }
            for k in 0..<p.count {
                if scalars[i + k] != p[k] { return false }
            }
            return true
        }

        while i < scalars.count {
            // <!-- comments --> (multi-line).
            if matches("<!--") {
                let sl = line, sc = col
                for _ in 0..<4 { advance() }
                while i < scalars.count, !matches("-->") { advance() }
                if i < scalars.count {
                    for _ in 0..<3 { advance() }
                }
                emitMultiline(into: &spans,
                              lineLengths: lineLengths,
                              startLine: sl,
                              startCol: sc,
                              endLine: line,
                              endCol: col,
                              kind: .comment)
                continue
            }

            // Tag region: '<' .. '>' -- keyword color, with attribute strings
            // ("..." / '...') still highlighted as strings.
            if scalars[i].value == 0x3C {
                let sl = line, sc = col
                advance()
                // Optional '/'
                if i < scalars.count, scalars[i].value == 0x2F { advance() }
                // Tag name
                while i < scalars.count {
                    let s = scalars[i]
                    let isLetter = (s.value >= 0x41 && s.value <= 0x5A) ||
                                   (s.value >= 0x61 && s.value <= 0x7A) ||
                                   (s.value >= 0x30 && s.value <= 0x39) ||
                                   s.value == 0x2D || s.value == 0x5F || s.value == 0x3A
                    if !isLetter { break }
                    advance()
                }
                // Tag-name run (open '<' through end of tag name).
                spans.append(HighlightSpan(
                    line: sl,
                    startColumn: sc,
                    length: col - sc,
                    kind: .keyword))

                // Attributes inside the tag.
                while i < scalars.count, scalars[i].value != 0x3E {
                    let s = scalars[i]
                    if s.value == 0x22 || s.value == 0x27 {
                        let strSL = line, strSC = col
                        let delim = s
                        advance()
                        while i < scalars.count, scalars[i] != delim,
                              scalars[i].value != 0x0A
                        {
                            advance()
                        }
                        if i < scalars.count, scalars[i] == delim { advance() }
                        emitMultiline(into: &spans,
                                      lineLengths: lineLengths,
                                      startLine: strSL,
                                      startCol: strSC,
                                      endLine: line,
                                      endCol: col,
                                      kind: .string)
                        continue
                    }
                    if s.value == 0x3D {
                        spans.append(HighlightSpan(
                            line: line,
                            startColumn: col,
                            length: 1,
                            kind: .operator))
                        advance()
                        continue
                    }
                    advance()
                }
                if i < scalars.count, scalars[i].value == 0x3E {
                    spans.append(HighlightSpan(
                        line: line,
                        startColumn: col,
                        length: 1,
                        kind: .keyword))
                    advance()
                }
                continue
            }

            advance()
        }
        return spans
    }

    private static func computeLineLengths(scalars: [UnicodeScalar]) -> [Int] {
        var out: [Int] = []
        var current = 0
        for s in scalars {
            if s.value == 0x0A {
                out.append(current)
                current = 0
            } else {
                current += 1
            }
        }
        out.append(current)
        return out
    }
}

// MARK: - JSON / YAML tokenizers

private enum StructuredTokenizer {
    static func tokenizeJson(_ text: String) -> [HighlightSpan] {
        let scalars = Array(text.unicodeScalars)
        let lineLengths = computeLineLengths(scalars: scalars)
        var spans: [HighlightSpan] = []
        var i = 0
        var line = 0
        var col = 0

        @inline(__always) func advance() {
            if scalars[i].value == 0x0A { line += 1; col = 0 } else { col += 1 }
            i += 1
        }

        while i < scalars.count {
            let c = scalars[i]
            // Strings
            if c.value == 0x22 {
                let sl = line, sc = col
                advance()
                while i < scalars.count {
                    if scalars[i].value == 0x5C, i + 1 < scalars.count {
                        advance(); advance(); continue
                    }
                    if scalars[i].value == 0x22 { advance(); break }
                    if scalars[i].value == 0x0A { break }
                    advance()
                }
                emitMultiline(into: &spans,
                              lineLengths: lineLengths,
                              startLine: sl,
                              startCol: sc,
                              endLine: line,
                              endCol: col,
                              kind: .string)
                continue
            }
            // Numbers (incl. negative + scientific).
            if c.value == 0x2D || (c.value >= 0x30 && c.value <= 0x39) {
                let sl = line, sc = col
                if c.value == 0x2D { advance() }
                while i < scalars.count {
                    let s = scalars[i]
                    if (s.value >= 0x30 && s.value <= 0x39) ||
                        s.value == 0x2E || s.value == 0x2B || s.value == 0x2D ||
                        s.value == 0x65 || s.value == 0x45
                    {
                        advance()
                    } else {
                        break
                    }
                }
                if col - sc > 0 {
                    spans.append(HighlightSpan(
                        line: sl,
                        startColumn: sc,
                        length: col - sc,
                        kind: .number))
                }
                continue
            }
            // Keywords: true, false, null.
            if (c.value >= 0x61 && c.value <= 0x7A) {
                let sl = line, sc = col
                var ident = ""
                while i < scalars.count {
                    let s = scalars[i]
                    if s.value >= 0x61, s.value <= 0x7A {
                        ident.append(Character(s))
                        advance()
                    } else {
                        break
                    }
                }
                if ident == "true" || ident == "false" || ident == "null" {
                    spans.append(HighlightSpan(
                        line: sl,
                        startColumn: sc,
                        length: col - sc,
                        kind: .keyword))
                }
                continue
            }
            advance()
        }
        return spans
    }

    static func tokenizeYaml(_ text: String) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        for (lineIndex, lineSub) in lines.enumerated() {
            let scalars = Array(lineSub.unicodeScalars)
            let count = scalars.count
            var i = 0
            // Leading whitespace.
            while i < count, scalars[i].value == 0x20 || scalars[i].value == 0x09 { i += 1 }

            // Line comments (#).
            if i < count, scalars[i].value == 0x23 {
                spans.append(HighlightSpan(
                    line: lineIndex,
                    startColumn: i,
                    length: count - i,
                    kind: .comment))
                continue
            }

            // List bullet '-'
            if i < count, scalars[i].value == 0x2D {
                spans.append(HighlightSpan(
                    line: lineIndex,
                    startColumn: i,
                    length: 1,
                    kind: .operator))
                i += 1
                while i < count, scalars[i].value == 0x20 { i += 1 }
            }

            // Key: value
            let keyStart = i
            var sawColon = false
            while i < count {
                let s = scalars[i]
                if s.value == 0x3A {
                    sawColon = true
                    break
                }
                if s.value == 0x23 { break }
                i += 1
            }
            if sawColon, i > keyStart {
                spans.append(HighlightSpan(
                    line: lineIndex,
                    startColumn: keyStart,
                    length: i - keyStart,
                    kind: .type))
                spans.append(HighlightSpan(
                    line: lineIndex,
                    startColumn: i,
                    length: 1,
                    kind: .operator))
                i += 1
            } else {
                // No colon -- rewind, scan the rest as a value.
                i = keyStart
            }

            // Inline comment that wasn't consumed yet.
            while i < count {
                let s = scalars[i]
                if s.value == 0x23 {
                    spans.append(HighlightSpan(
                        line: lineIndex,
                        startColumn: i,
                        length: count - i,
                        kind: .comment))
                    break
                }
                if s.value == 0x22 || s.value == 0x27 {
                    let delim = s
                    let start = i
                    i += 1
                    while i < count, scalars[i] != delim { i += 1 }
                    if i < count { i += 1 }
                    spans.append(HighlightSpan(
                        line: lineIndex,
                        startColumn: start,
                        length: i - start,
                        kind: .string))
                    continue
                }
                // numbers / true / false / null.
                if (s.value >= 0x30 && s.value <= 0x39) || s.value == 0x2D {
                    let start = i
                    if s.value == 0x2D { i += 1 }
                    while i < count {
                        let t = scalars[i]
                        if (t.value >= 0x30 && t.value <= 0x39) ||
                            t.value == 0x2E || t.value == 0x65 || t.value == 0x45
                        {
                            i += 1
                        } else { break }
                    }
                    if i - start > 1 || (i - start == 1 && scalars[start].value != 0x2D) {
                        spans.append(HighlightSpan(
                            line: lineIndex,
                            startColumn: start,
                            length: i - start,
                            kind: .number))
                    }
                    continue
                }
                if (s.value >= 0x61 && s.value <= 0x7A) {
                    let start = i
                    while i < count {
                        let t = scalars[i]
                        if (t.value >= 0x61 && t.value <= 0x7A) ||
                            (t.value >= 0x41 && t.value <= 0x5A)
                        {
                            i += 1
                        } else { break }
                    }
                    let token = String(String.UnicodeScalarView(scalars[start..<i]))
                    if token == "true" || token == "false" ||
                        token == "null" || token == "yes" ||
                        token == "no" || token == "on" || token == "off"
                    {
                        spans.append(HighlightSpan(
                            line: lineIndex,
                            startColumn: start,
                            length: i - start,
                            kind: .keyword))
                    }
                    continue
                }
                i += 1
            }
        }
        return spans
    }

    private static func computeLineLengths(scalars: [UnicodeScalar]) -> [Int] {
        var out: [Int] = []
        var current = 0
        for s in scalars {
            if s.value == 0x0A {
                out.append(current)
                current = 0
            } else {
                current += 1
            }
        }
        out.append(current)
        return out
    }
}
