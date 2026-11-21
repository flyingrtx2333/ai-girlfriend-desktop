import Foundation

struct AgentSSHPluginSource: Decodable, Sendable {
    let path: String
    let versionGroup: String?
}

struct AgentSSHPluginPayload: Sendable {
    enum Content: Sendable {
        case archive(Data)
        case directory([String: Data])
    }
    let project: Bool
    let content: Content
}

extension AgentSSHPluginSource {
    // Only paths inside the selected root are opened. ZIPs travel as bytes;
    // folders are streamed after a bounded, non-following inventory check.
    static let script = #"""
    for python in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        [ -x "$python" ] || continue
        "$python" -I -B -S -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1 || continue
        exec "$python" -I -B -S -X utf8 - "$@" <<'BFF_PLUGINS'
    import errno
    import json
    import os
    import re
    import stat
    import sys
    import unicodedata
    from contextlib import contextmanager

    source, anchor, explicit, selected = sys.argv[1:5]
    manifests, hidden, marker_paths, protected, extensions = map(json.loads, sys.argv[5:10])
    maximum_entries, maximum_file, maximum_total = map(int, sys.argv[10:13])
    root = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    base = os.getcwd()
    if base == "/" and not explicit:
        sys.exit(42)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK

    def components(path):
        if path == ".":
            return []
        parts = path.split("/")
        if not all(part not in {"", ".", ".."} for part in parts):
            sys.exit(52)
        return parts

    @contextmanager
    def opened(path, directory, root_fd=root):
        parts = components(path)
        fd = os.dup(root_fd) if parts else os.open(".", flags | os.O_DIRECTORY, dir_fd=root_fd)
        try:
            for index, part in enumerate(parts):
                kind = os.O_DIRECTORY if directory or index + 1 < len(parts) else 0
                child = os.open(part, flags | kind, dir_fd=fd)
                os.close(fd)
                fd = child
            yield fd
        finally:
            os.close(fd)

    def entry(path):
        if path == ".":
            return os.fstat(root)
        parent, name = os.path.split(path)
        try:
            with opened(parent or ".", True) as directory:
                return os.stat(name, dir_fd=directory, follow_symlinks=False)
        except (FileNotFoundError, NotADirectoryError):
            return None
        except OSError as error:
            if error.errno == errno.ELOOP:
                return None
            raise

    def is_folder(path):
        item = entry(path)
        return item is not None and stat.S_ISDIR(item.st_mode)

    def is_zip(path, item):
        return item is not None and stat.S_ISREG(item.st_mode) and path.lower().endswith(".zip")

    def at(path, member):
        return member if path == "." else path + "/" + member

    def package(path, conventional=False):
        item = entry(path)
        if is_zip(path, item):
            return True
        return item is not None and stat.S_ISDIR(item.st_mode) and any(
            entry(at(path, marker)) is not None for marker in manifests + (marker_paths if conventional else []))

    def listing():
        if explicit:
            if not is_zip(explicit, entry(explicit)):
                sys.exit(43)
            return [{"path": explicit}]
        if package("."):
            return [{"path": "."}]
        container = next((name for name in [anchor + "/plugins", "plugins"] if is_folder(name)), None)
        folder = container or "."
        folder_name = os.path.basename(base if folder == "." else folder)
        if container is None and folder_name not in {"plugins", "cache", "custom"} and package(folder, source == "qoder"):
            return [{"path": folder}]
        visited = 0
        def children(path):
            nonlocal visited
            if not is_folder(path):
                return []
            found = []
            with opened(path, True) as fd, os.scandir(fd) as names:
                for item in names:
                    if item.name.startswith("."):
                        continue
                    found.append(at(path, item.name))
                    visited += 1
                    if len(found) > 512 or visited > 4096:
                        sys.exit(45)
            return sorted(found)
        custom = at(folder, "custom")
        cache = folder if folder_name == "cache" else at(folder, "cache")
        rows = {}
        for path in children(folder) + children(custom):
            if os.path.basename(path) not in {"cache", "custom", "data", "marketplaces"} and package(path, source == "qoder"):
                rows[path] = {"path": path}
        for market in children(cache):
            for plugin in children(market):
                if not is_folder(plugin):
                    continue
                if package(plugin):
                    rows[plugin] = {"path": plugin}
                    continue
                for path in children(plugin):
                    if not is_folder(path) or not re.fullmatch(r"[A-Za-z0-9._+-]+", os.path.basename(path)):
                        continue
                    if source == "codex":
                        rows[path] = {"path": path, "versionGroup": plugin}
                    elif package(path, True):
                        rows[path] = {"path": path}
        return [rows[path] for path in sorted(rows)]

    def signature(item):
        return (item.st_dev, item.st_ino, item.st_mode, item.st_size, item.st_mtime_ns, item.st_ctime_ns)

    def read_member(fd, maximum, expected):
        start = os.fstat(fd)
        if not stat.S_ISREG(start.st_mode) or signature(start) != expected:
            sys.exit(53)
        if start.st_size > maximum:
            sys.exit(50)
        with os.fdopen(os.dup(fd), "rb") as file:
            data = file.read(maximum + 1)
        if len(data) > maximum or len(data) != start.st_size or signature(os.fstat(fd)) != expected:
            sys.exit(53)
        return data

    def directory_resources(fd):
        def inventory():
            paths = {".": signature(os.fstat(fd))}
            names, visited = set(), 0
            def walk(directory, prefix):
                nonlocal visited
                with os.scandir(directory) as children:
                    for item in children:
                        visited += 1
                        if visited > 5000:
                            sys.exit(49)
                        name = item.name
                        if name in {"__MACOSX", "node_modules", "__pycache__"} or name.startswith(".") and (prefix or name not in hidden):
                            continue
                        path = prefix + name
                        lower = name.lower()
                        if lower in protected or lower.startswith(".env.") or os.path.splitext(lower)[1][1:] in extensions:
                            sys.exit(48)
                        if path.startswith("-") or len(path.encode("utf-8")) > 1000 or any(ch in path for ch in "\\\r\n*?[]"):
                            sys.exit(52)
                        key = unicodedata.normalize("NFC", path).lower()
                        if key in names or len(names) >= maximum_entries:
                            sys.exit(49)
                        names.add(key)
                        info = item.stat(follow_symlinks=False)
                        paths[path] = signature(info)
                        if stat.S_ISDIR(info.st_mode):
                            with opened(name, True, directory) as child:
                                walk(child, path + "/")
                        elif not stat.S_ISREG(info.st_mode):
                            sys.exit(48)
            with opened(".", True, fd) as directory:
                walk(directory, "")
            return paths
        before = inventory()
        files, total = {}, 0
        for path, expected in before.items():
            if not stat.S_ISREG(expected[2]):
                continue
            with opened(path, False, fd) as member:
                data = read_member(member, maximum_file, expected)
            total += len(data)
            if total > maximum_total:
                sys.exit(51)
            files[path] = data
        if before != inventory():
            sys.exit(53)
        return files

    def emit(path, data):
        out.write(path.encode("utf-8") + b"\0" + str(len(data)).encode("ascii") + b"\0" + data)

    try:
        out = sys.stdout.buffer
        if not selected:
            index = json.dumps(listing(), ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            out.write(b"BFF-SESSIONS-1\0")
            emit(".source", index)
        else:
            if explicit and explicit != selected:
                sys.exit(43)
            item = entry(selected)
            archive = is_zip(selected, item)
            if item is None or not (archive or stat.S_ISDIR(item.st_mode)):
                sys.exit(43)
            with opened(selected, not archive) as fd:
                if signature(os.fstat(fd)) != signature(item):
                    sys.exit(53)
                files = {".archive": read_member(fd, maximum_total, signature(item))} if archive else directory_resources(fd)
            current = entry(selected)
            if current is None or signature(current) != signature(item):
                sys.exit(53)
            parts = (os.path.join(base, selected) if selected != "." else base).split("/")
            home = os.path.realpath(os.environ.get("HOME", "/"))
            ancestor = max((index for index, part in enumerate(parts) if part == anchor), default=-1)
            project = ancestor >= 0 and ("/".join(parts[:ancestor]) or "/") != home
            metadata = json.dumps({"archive": archive, "project": project}).encode("utf-8")
            out.write(b"BFF-SESSIONS-1\0")
            emit(".source", metadata)
            for path, data in files.items():
                emit(path, data)
        out.write(b"\0")
    except OSError:
        sys.exit(43)
    except UnicodeError:
        sys.exit(52)
    BFF_PLUGINS
    done
    exit 47
    """#
}
