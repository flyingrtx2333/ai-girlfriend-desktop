import Foundation

struct AgentSSHConfigurationSource: Sendable {
    struct Origin: Decodable, Sendable {
        let root: String
        let configurationRoot, project: Bool
    }

    let origin: Origin
    let files: [String: Result<Data, PetError>]
    let resources: [String: (data: Data, executable: Bool)]
    let resourceIssues: [String: PetError]

    static func validPath(_ path: String) -> Bool {
        AgentArchive.validPath(path) && !path.hasSuffix("/") && !AgentFiles.sensitive(path) &&
            path.rangeOfCharacter(from: .controlCharacters) == nil
    }

    // This script never sends whole settings files or the contents of instruction references.
    static let script = #"""
    for python in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        [ -x "$python" ] || continue
        if [ "$1" = codex ]; then
            "$python" -I -B -S -c 'import tomllib' >/dev/null 2>&1 || continue
        else
            "$python" -I -B -S -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1 || continue
        fi
        exec "$python" -I -B -S -X utf8 - "$@" <<'BFF_CONFIGURATION'
    import hashlib
    import json
    import os
    import re
    import stat
    import sys
    from contextlib import contextmanager
    from urllib.parse import urlsplit

    source, anchor, wanted, references, protected, extensions, missing, suffixes = sys.argv[1:9]
    protected, extensions, suffixes = map(json.loads, (protected, extensions, suffixes))
    if source == "codex":
        import tomllib

    def restricted(part):
        name, dot, suffix = part.lower().rpartition(".")
        return part.lower() in protected or part.lower().startswith(".env.") or bool(dot and name and suffix in extensions)

    base = os.getcwd()
    if base == "/" or any(restricted(part) for part in base.split("/")):
        sys.exit(42)
    configuration = os.path.basename(base) == anchor
    parent = os.path.dirname(base)
    project = not configuration or (base != os.path.realpath(os.path.join(os.path.expanduser("~"), anchor))
        and any(os.path.exists(os.path.join(parent, name)) for name in
                [".git", ".bluefatfish", "AGENTS.md", "AGENTS.local.md", "AGENTS.override.md"]))
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK

    def valid(path):
        try:
            if len(path.encode("utf-8")) > 1000 or path.startswith("-") or re.search(r"[\\*?\[\]\x00-\x1f\x7f-\x9f]", path):
                return False
        except UnicodeError:
            return False
        for part in path.split("/"):
            if part in {"", ".", ".."} or restricted(part):
                return False
        return True

    @contextmanager
    def opened(path, directory=False):
        fd = os.open(".", flags | os.O_DIRECTORY)
        try:
            parts = path.split("/") if path else []
            for index, part in enumerate(parts):
                child = os.open(part, flags | (os.O_DIRECTORY if directory or index < len(parts) - 1 else 0), dir_fd=fd)
                os.close(fd)
                fd = child
            yield fd
        finally:
            os.close(fd)

    def signature(info):
        return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    def read(path, limit):
        with opened(path) as fd:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode):
                raise ValueError()
            if before.st_size > limit:
                raise OverflowError()
            with os.fdopen(os.dup(fd), "rb") as stream:
                data = stream.read(limit + 1)
            if len(data) != before.st_size or signature(os.fstat(fd)) != signature(before):
                raise ValueError()
            return data, bool(before.st_mode & 0o111)

    out = sys.stdout.buffer
    total = 0
    def emit(name, data):
        global total
        if isinstance(data, bytes):
            total += len(data)
            if total > 24_000_000:
                sys.exit(49)
            out.write(name.encode() + b"\0" + str(len(data)).encode() + b"\0" + data)
        else:
            out.write(name.encode() + b"\0" + data.encode() + b"\0")

    def encode(value):
        return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False, separators=(",", ":")).encode()

    out.write(b"BFF-SESSIONS-1\0")
    if references:
        results = {}
        paths = json.loads(references)
        if len(paths) > 64 or not all(valid(path) for path in paths):
            sys.exit(52)
        for path in paths:
            try:
                results[path] = hashlib.sha256(read(path, 65_536)[0]).hexdigest()
            except (OSError, ValueError, OverflowError):
                continue
        emit("R", encode(results))
        out.write(b"\0")
        sys.exit(0)

    def join(folder, name):
        return folder + "/" + name if folder else name

    def sensitive_key(value, keys):
        return re.sub(r"[^a-z]", "", value.lower()).endswith(tuple(keys))

    def credential_address(value):
        if not re.match(r"https?://", value, re.I):
            return False
        try:
            url = urlsplit(value)
            return url.username is not None or url.password is not None or bool(url.query or url.fragment)
        except ValueError:
            return True

    def credential_input(value):
        if isinstance(value, list):
            return any(credential_input(item) for item in value)
        if not isinstance(value, dict):
            return False
        return any((sensitive_key(key, ["authorization", "token", "password", "secret", "apikey", "credential"])
                    and item is not None and item != "" and not (isinstance(item, str) and re.fullmatch(r"\$\{[^{}]+\}", item)))
                   or credential_input(item) for key, item in value.items())

    def clean_handler(handler):
        if not isinstance(handler, dict):
            return None
        # Export only recognized fields. Unsupported declarations are skipped by the native preview.
        fields = {"name", "type", "command", "timeout", "shell", "args", "env", "network", "if", "allowedEnvVars",
                  "url", "headers", "prompt", "model", "tools", "maxTurns", "async", "asyncRewake", "rewakeMessage",
                  "rewakeSummary", "statusMessage", "once", "additionalContextLimit", "server", "tool", "input",
                  "commandWindows", "command_windows"}
        kind = handler.get("type", "command")
        if not isinstance(kind, str) or len(kind) > 120:
            return {"unsupported": True}
        if handler.keys() - fields or source != "codex" and handler.keys() & {"commandWindows", "command_windows"}:
            return {"type": kind, "unsupported": True}
        clean = {key: value for key, value in handler.items() if key not in {"commandWindows", "command_windows"}}
        for key in ("headers", "env"):
            if key in clean:
                value = clean[key]
                clean[key] = {name: missing for name in value} if isinstance(value, dict) else False
        command = clean.get("command", "")
        args = clean.get("args", [])
        program = os.path.basename(command) if isinstance(command, str) else ""
        if (isinstance(command, str) and re.search(
                r"(?i)\b[a-z_]*(?:token|password|secret|api[_-]?key)\s*=|--(?:token|password|secret|api-key)(?:=|\s)|\bauthorization\s*:|https?://[^\s'\"]*[?#@]", command)
            or isinstance(clean.get("url"), str) and credential_address(clean["url"])
            or isinstance(args, list) and any(isinstance(arg, str) and (
                (arg.startswith("-") or "=" in arg) and sensitive_key(arg.split("=", 1)[0], suffixes)
                or re.match(r"(?i)authorization\s*:|bearer\s+", arg)
                or credential_address(arg) or "=" in arg and credential_address(arg.split("=", 1)[1])
                or arg == "-c" and (program in {"sh","bash","zsh","dash","fish","ksh"} or program.startswith("python"))
                or arg in {"-e", "--eval"} and program.startswith(("python","node","perl","ruby","deno"))) for arg in args)
            or credential_input(clean.get("input"))):
            return {"type": kind, "credentials": True}
        return clean

    def projection(data, name):
        parsed = tomllib.loads(data.decode("utf-8")) if name == "config.toml" else json.loads(data)
        if not isinstance(parsed, dict):
            raise ValueError()
        events = parsed.get("hooks")
        if events is None:
            return None, False
        if not isinstance(events, dict):
            raise ValueError()
        if name == "config.toml":
            events.pop("state", None)
        clean = {}
        for key, groups in events.items():
            if not isinstance(groups, list):
                clean[key] = None
                continue
            clean[key] = []
            for group in groups:
                if not isinstance(group, dict) or group.keys() - {"matcher", "hooks", "timeout", "async"}:
                    clean[key].append({})
                    continue
                handlers = group.get("hooks")
                if not isinstance(handlers, list):
                    clean[key].append({})
                    continue
                clean[key].append(dict(group, hooks=[clean_handler(hook) for hook in handlers]))
        assets = any(handler and handler.get("type") != "mcp_tool"
                     for groups in clean.values() if groups
                     for group in groups for handler in group.get("hooks", []))
        return (encode({"hooks": clean}) if clean else None), assets

    seen_resources = set()
    def hook_resources(folder):
        if folder in seen_resources:
            return
        seen_resources.add(folder)
        entries, count, size = [], 0, 0
        def visit(path):
            nonlocal count, size
            with opened(path, True) as fd, os.scandir(fd) as children:
                for item in children:
                    name = join(path, item.name)
                    count += 1
                    if count > 500 or not valid(name):
                        raise ValueError()
                    if item.is_dir(follow_symlinks=False):
                        visit(name)
                    else:
                        data, executable = read(name, 1_000_000)
                        size += len(data)
                        if size > 5_000_000:
                            raise OverflowError()
                        entries.append(("X:" if executable else "A:", name, data))
        try:
            visit(folder)
        except FileNotFoundError:
            if not os.path.lexists(folder):
                return
            emit("H:" + folder, "?")
            return
        except (ValueError, OSError, OverflowError):
            emit("H:" + folder, "?")
            return
        for prefix, name, data in entries:
            emit(prefix + name, data)

    candidates = set()
    visited = 0
    instruction_names = ["AGENTS.md", "AGENTS.override.md"] if source == "codex" else ["AGENTS.md", "AGENTS.local.md"]

    def add(path):
        if valid(path):
            candidates.add(path)
            if len(candidates) > 256:
                sys.exit(45)

    def walk(folder, tree, suffix=None, recursive=False):
        global visited
        try:
            with opened(folder, True) as fd, os.scandir(fd) as children:
                for item in children:
                    visited += 1
                    if visited > 5000:
                        sys.exit(45)
                    path = join(folder, item.name)
                    if item.name.startswith(".") or not valid(path):
                        continue
                    if (tree and item.name in instruction_names) or (suffix and item.name.endswith(suffix)):
                        add(path)
                    elif (tree or recursive) and item.name not in {"node_modules", "__pycache__"} and item.is_dir(follow_symlinks=False):
                        walk(path, tree, suffix, recursive)
        except FileNotFoundError:
            if os.path.lexists(folder):
                sys.exit(43)
            return
        if tree:
            config(join(folder, anchor), bool(folder))

    def config(folder, nested):
        hooks = ["hooks.json", "config.toml"] if source == "codex" else (["settings.json", "settings.local.json"] if project else ["settings.json"])
        if not nested or source == "codex":
            for name in hooks:
                path = join(folder, name)
                if os.path.lexists(path):
                    add(path)
        if source == "qoder":
            walk(join(folder, "rules"), False, ".md", True)
            if not nested:
                walk(join(folder, "commands"), False, ".md", True)
        elif not nested:
            walk(join(folder, "rules"), False, ".rules")
            if configuration and not project:
                walk(join(folder, "prompts"), False, ".md")
        if not nested:
            walk(join(folder, "agents"), False, ".md" if source == "qoder" else ".toml")

    def include_selected(path):
        parts = path.split("/")
        if not valid(path):
            sys.exit(52)
        # A new Codex override can change the plan during resume.
        if parts[-1] in instruction_names:
            names = [join(os.path.dirname(path), name) for name in instruction_names]
            if (configuration and not project and len(parts) == 1
                or not configuration and not any(part.startswith(".") for part in parts[:-1])):
                for name in names:
                    if os.path.lexists(name):
                        add(name)
            return
        offset = 0 if configuration else parts.index(anchor) + 1 if anchor in parts else -1
        if offset < 0 or any(part.startswith(".") for part in parts[:max(0, offset - 1)]):
            return
        children = parts[offset:]
        nested = not configuration and offset > 1
        if len(children) == 1:
            names = {"hooks.json", "config.toml"} if source == "codex" else {"settings.json", "settings.local.json"} if project and not nested else {"settings.json"}
            if children[0] in names and (not nested or source == "codex"):
                add(path)
        elif len(children) > 1 and not any(part.startswith(".") for part in children[1:]):
            folder, name = children[0], children[-1]
            if source == "qoder":
                if name.endswith(".md") and (folder == "rules" or not nested and
                        (folder == "commands" or folder == "agents" and len(children) == 2)):
                    add(path)
            elif not nested and len(children) == 2 and (
                    folder == "agents" and name.endswith(".toml")
                    or folder == "rules" and name.endswith(".rules")
                    or configuration and not project and folder == "prompts" and name.endswith(".md")):
                add(path)

    try:
        if wanted:
            include_selected(wanted)
        elif configuration:
            if not project:
                for name in instruction_names:
                    if os.path.lexists(name):
                        add(name)
            config("", False)
        else:
            walk("", True)
    except OSError:
        sys.exit(43)
    emit("M", encode({"root": base, "configurationRoot": configuration, "project": project}))
    for path in sorted(candidates):
        name = os.path.basename(path)
        folder = os.path.dirname(path)
        hooks = name in ({"hooks.json", "config.toml"} if source == "codex" else {"settings.json", "settings.local.json"})
        try:
            if path.endswith(".rules"):
                emit("F:" + path, "?")
                continue
            limit = (512_000 if name == "config.toml" else 128_000) if hooks else 65_536
            data, _ = read(path, limit)
            assets = False
            if hooks:
                data, assets = projection(data, name)
                if data is None:
                    continue
                if len(data) > 512_000:
                    raise OverflowError()
            emit("F:" + path, data)
            if assets and (configuration or folder == anchor):
                hook_resources(join(folder, "hooks"))
        except (ValueError, OSError, TypeError, RecursionError):
            emit("F:" + path, "?")
        except OverflowError:
            emit("F:" + path, "-")
    out.write(b"\0")
    BFF_CONFIGURATION
    done
    exit 47
    """#
}
