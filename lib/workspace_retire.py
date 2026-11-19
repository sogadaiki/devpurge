"""Retire one verified, integrated Git checkout while retaining its branch."""
import datetime
import hashlib
import os
from pathlib import Path
import pwd
import re
import shlex
import stat
import subprocess
import time

from studio import Studio
from workspace_folders import _directory
from workspace_git import _private


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def git(repo, *args, optional=False):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", GIT_NO_LAZY_FETCH="1", LC_ALL="C")
    result = subprocess.run(
        ["/usr/bin/git", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", str(repo), *args],
        capture_output=True, timeout=60, env=env)
    if optional and result.returncode == 1:
        return None
    require(result.returncode == 0, "Gitの状態を確かめられないか、Gitが操作を拒否しました")
    return result.stdout


def refs(repo):
    entries = []
    for block in git(repo, "worktree", "list", "--porcelain", "-z").split(b"\0\0"):
        if block:
            attrs = dict(field.partition(b" ")[::2] for field in block.split(b"\0") if field)
            entries.append(attrs)
    return entries


def user_home():
    uid = os.geteuid()
    require(uid != 0 and uid == os.getuid(), "通常のログインユーザーで実行してください")
    home = Path(pwd.getpwuid(uid).pw_dir)
    require(home == Path.home() and home == home.resolve(), "ログインユーザーのホームを照合できません")
    return home


def check_paths(home, repo, target):
    for path in (repo, target):
        require(path.is_absolute() and path == path.resolve(strict=True) and home in path.parents
                and not _private(path) and path.is_dir() and path.stat().st_uid == os.geteuid()
                and "\\" not in str(path) and not any(ord(c) < 32 for c in str(path)),
                "本人のホーム内の絶対物理パスを指定してください")
        require(path.relative_to(home).parts[0] not in ("Library", ".Trash", "Applications"), "管理領域は保持します")
        # Same physical-ancestor, offline-placeholder and .devpurge-keep policy as discovery.
        with _directory(path):
            pass
    require(repo != target and target not in repo.parents, "本体または本体を含む作業コピーは保持します")


def idle_days(home):
    value = os.environ.get("DEVPURGE_WORKTREE_AGE_DAYS", "7")
    config = home / ".devpurgerc"
    require(not config.is_symlink(), "除外設定のリンク先を検証できません")
    if config.exists():
        for line in config.read_text().splitlines():
            if line.startswith("worktree_age_days="):
                value = line.partition("=")[2]
    require(value.isascii() and value.isdigit() and len(value) <= 6, "作業コピーの保持日数を検証できません")
    return max(1, int(value))


def integrated(repo, target):
    entries = refs(repo)
    require(entries and entries[0].get(b"worktree") == os.fsencode(repo) and b"bare" not in entries[0],
            "指定リポジトリは登録された本体ではありません")
    linked = [entry for entry in entries[1:] if entry.get(b"worktree") == os.fsencode(target)]
    require(len(linked) == 1 and not ({b"locked", b"prunable", b"detached"} & linked[0].keys()),
            "別リポジトリ、ロック、所在不明、またはdetachedの作業コピーは保持します")
    common = repo / ".git"
    admin = Path(os.fsdecode(git(target, "rev-parse", "--absolute-git-dir").rstrip(b"\n")))
    require(common == common.resolve(strict=True) and admin == admin.resolve(strict=True)
            and admin.parent == common / "worktrees"
            and git(target, "rev-parse", "--path-format=absolute", "--git-common-dir").rstrip(b"\n") == os.fsencode(common)
            and git(target, "rev-parse", "--show-toplevel").rstrip(b"\n") == os.fsencode(target)
            and stat.S_ISREG((target / ".git").lstat().st_mode), "Git本体と作業コピーの登録を照合できません")
    admin_names = {p.name for p in admin.iterdir()}
    require(admin_names <= {"HEAD", "index", "gitdir", "commondir", "logs", "refs", "ORIG_HEAD",
                            "COMMIT_EDITMSG", "FETCH_HEAD"},
            "進行中のGit操作・ロック・個別の設定があるため保持します")
    require(not (admin / "refs").exists() or not any(p.is_file() for p in (admin / "refs").rglob("*")),
            "作業コピー固有のGit参照があるため保持します")
    branch = os.fsdecode(git(target, "symbolic-ref", "HEAD").rstrip(b"\n"))
    require(branch.startswith("refs/heads/") and linked[0].get(b"branch") == os.fsencode(branch),
            "復元できるローカルブランチを確認できません")
    short = branch[len("refs/heads/"):]
    git(repo, "check-ref-format", "--branch", short)
    head = os.fsdecode(git(repo, "rev-parse", "--verify", branch).strip())
    require(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head) and linked[0].get(b"HEAD") == head.encode()
            and git(target, "rev-parse", "HEAD").strip() == head.encode(), "ブランチ先端が変わったため保持します")
    remote_default = git(repo, "symbolic-ref", "-q", "refs/remotes/origin/HEAD", optional=True)
    remote = os.fsdecode(remote_default.strip()) if remote_default else None
    require(not remote or remote.startswith("refs/remotes/origin/"), "既定ブランチを判定できません")
    local_default = "refs/heads/" + remote[len("refs/remotes/origin/"):] if remote else None
    default = next((ref for ref in (local_default, "refs/heads/main", "refs/heads/master")
                    if ref and git(repo, "show-ref", "--verify", "--quiet", ref, optional=True) is not None), None)
    require(default is not None, "ローカルの既定ブランチを判定できません")
    require(branch not in (default, local_default) and short not in ("main", "master", "develop"), "既定・共有ブランチは保持します")
    require(git(repo, "merge-base", "--is-ancestor", head, default, optional=True) is not None,
            "既定ブランチへ統合された履歴を確認できません")
    if remote:
        require(git(repo, "merge-base", "--is-ancestor", head, remote, optional=True) is not None,
                "手元に記録されたoriginの既定ブランチに統合された履歴を確認できません")
    # A previous detached commit could exist only in this checkout's private HEAD reflog.
    prior = set(git(target, "reflog", "show", "--format=%H", "HEAD").splitlines())
    require(len(prior) <= 1024, "個別の復元履歴が検証上限を超えています")
    if prior:
        lost = git(repo, "rev-list", "--max-count=1", *[oid.decode("ascii") for oid in prior],
                   "--not", "--branches", "--remotes", "--tags")
        require(not lost, "作業コピー固有の復元履歴があるため保持します")
    return admin, short, head, default


def tree_evidence(repo, target, admin, head, policy, cutoff, hash_files):
    for path in (repo, target):
        policy.physical(path)
    tracked = {}
    directories = {target}
    for field in git(repo, "ls-tree", "-r", "-z", head).split(b"\0"):
        if not field:
            continue
        metadata, raw = field.split(b"\t", 1)
        mode, kind, oid = metadata.split()
        require(kind == b"blob" and mode in (b"100644", b"100755", b"120000"), "サブモジュール・未対応の項目を保持します")
        name = Path(os.fsdecode(raw))
        path = target / name
        protected_name = re.search(r"(^|[._-])(secrets?|credentials?|tokens?|private[-_]key|service[-_]account)([._-]|$)",
                                   path.name, flags=re.IGNORECASE)
        require(not name.is_absolute() and ".." not in name.parts and not policy.blocked(path)
                and not protected_name and path.name not in ("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")
                and path.suffix.lower() not in (".key", ".pem", ".p8", ".p12", ".pfx", ".keychain-db"),
                "保護ファイルまたは除外設定に該当するため保持します")
        require(len(tracked) < 120000, "Gitファイル数が検証上限を超えています")
        tracked[path] = (mode, oid)
        for parent in path.parents:
            if parent == target:
                break
            directories.add(parent)
    flags = git(target, "ls-files", "-v", "-z").split(b"\0")
    require(all(not entry or entry.startswith(b"H ") for entry in flags), "変更検知省略・未マージの項目を保持します")
    # Intentionally omit --exclude-standard here. Ignored files must also hold the tree,
    # before any working file is opened for content verification.
    require(not git(target, "ls-files", "--others", "--directory", "-z"), "未追跡・ignoredの項目があるため保持します")
    git(target, "diff", "--cached", "--quiet", "--no-ext-diff", head, "--")
    epoch = int(git(repo, "log", "-1", "--format=%ct", head).strip())
    require(epoch <= cutoff, "ブランチのコミットが保持期間内です")
    seen = set()
    stack = [target]
    signature = {}
    total = 0
    start = time.monotonic()
    device = target.stat().st_dev
    while stack:
        path = stack.pop()
        info = path.lstat()
        require(info.st_dev == device and info.st_uid == os.geteuid(), "他の所有者・ボリュームの項目があります")
        require(info.st_mtime <= cutoff, "保持期間内に作成・更新された作業ファイルがあります")
        require(len(signature) < 120000 and total <= 2 * 1024**3 and time.monotonic() - start < 60,
                "作業コピーの検証上限を超えたため保持します")
        signature[path] = (info.st_dev, info.st_ino, info.st_size, info.st_mode, info.st_mtime_ns, info.st_ctime_ns)
        if path == target / ".git":
            require(stat.S_ISREG(info.st_mode), "Git登録ファイルが変化しました")
        elif path in directories:
            require(stat.S_ISDIR(info.st_mode), "ディレクトリがリンクまたは別形式に変化しました")
            for child in path.iterdir():
                require(len(stack) + len(signature) < 120000, "作業コピーの検証項目数が上限を超えています")
                stack.append(child)
        else:
            require(path in tracked, "Gitで復元できない未追跡・ignored項目を保持します")
            mode, oid = tracked[path]
            seen.add(path)
            total += info.st_size
            require(total <= 2 * 1024**3, "ファイルの照合容量が上限を超えています")
            digest = hashlib.new("sha1" if len(oid) == 40 else "sha256")
            digest.update(b"blob " + str(info.st_size).encode() + b"\0")
            if mode == b"120000":
                require(stat.S_ISLNK(info.st_mode), "Gitリンクの形式が変化しました")
                if hash_files:
                    digest.update(os.fsencode(os.readlink(path)))
            else:
                require(stat.S_ISREG(info.st_mode) and (mode == b"100755") == bool(info.st_mode & stat.S_IXUSR),
                        "作業ファイルの形式または実行属性が変化しました")
                if hash_files:
                    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, "rb") as stream:
                        opened = os.fstat(stream.fileno())
                        require((opened.st_dev, opened.st_ino) == (info.st_dev, info.st_ino), "検証中にファイルが変化しました")
                        for chunk in iter(lambda: stream.read(1024**2), b""):
                            digest.update(chunk)
            require(not hash_files or digest.hexdigest().encode() == oid, "Gitに保存されていない変更を保持します")
    require(seen == tracked.keys(), "Git管理ファイルの欠落または変更を保持します")
    for key in ("HEAD", "index", "logs/HEAD"):
        path = admin / key
        if path.exists():
            s = path.lstat()
            require(stat.S_ISREG(s.st_mode) and path == path.resolve() and s.st_mtime <= cutoff,
                    "作業コピーのGit操作が最近か未確認です")
            signature[path] = (s.st_ino, s.st_mtime_ns, s.st_ctime_ns)
    return signature


def idle(target):
    proc = subprocess.run(["/usr/sbin/lsof", "-nP", "-Fpn", "+D", str(target)], capture_output=True, timeout=30)
    require(proc.returncode == 1 and not proc.stdout and not proc.stderr, "作業コピーが使用中か、使用状態を確認できません")
    ps = subprocess.run(["/bin/ps", "-ww", "-axo", "pid=,ppid=,args="], capture_output=True, check=True, timeout=10)
    processes = {}
    for line in ps.stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3:
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    # The selected path is necessarily present in this invocation's own argument list.
    parent, callers = os.getpid(), set()
    require(parent in processes, "プロセス一覧の取得を確認できません")
    while parent in processes and parent not in callers:
        callers.add(parent)
        parent = processes[parent][0]
    require(not any(os.fsencode(target) in arguments for pid, (_, arguments) in processes.items() if pid not in callers),
            "別のプロセスがこの作業コピーを参照しています")


def append_record(folder, name, line):
    require(folder == folder.resolve(), "復元記録の保存先にリンクがあります")
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(folder.stat().st_uid == os.geteuid(), "復元記録の保存先を確認できません")
    fd = os.open(folder / name, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, "ab", buffering=0) as stream:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid(), "復元記録を安全に追記できません")
        data = os.fsencode(line + "\n")
        require(stream.write(data) == len(data), "復元記録の保存に失敗しました")
        os.fsync(fd)


def retire(repo: Path, target: Path, *, check_only=False) -> dict:
    """Verify twice, then ask Git to remove exactly one registered worktree."""
    repo, target = Path(repo), Path(target)
    receipt = {"repo": str(repo), "path": str(target), "status": "held"}
    try:
        home = user_home()
        check_paths(home, repo, target)
        policy = Studio(home)
        policy.physical(repo)
        policy.physical(target)
        state = integrated(repo, target)
        admin, branch, head, default = state
        cutoff = time.time() - idle_days(home) * 86400
        proof = tree_evidence(repo, target, admin, head, policy, cutoff, True)
        idle(target)
        if check_only:
            return dict(receipt, status="eligible", verified=True, branch=branch, head=head,
                        integration_ref=default, reason="統合、保存内容、保持期間、現在の利用状況を照合しました。")
        canonical_logs = home / "Library/Application Support/devpurge/logs"
        log_root = Path(os.environ.get("DEVPURGE_LOG_DIR") or canonical_logs)
        logs = list(dict.fromkeys([canonical_logs, log_root]))
        for folder in logs:
            require(folder.is_absolute() and home in folder.parents and target not in (folder, *folder.parents),
                    "復元記録の保存先を確認できません")
        stamp = datetime.datetime.now().strftime("%Y%m%d")
        line = "\t".join((str(int(time.time())), str(repo), str(target), branch, head))
        note = "removed-worktrees-" + stamp + ".tsv"
        receipt.update(branch=branch, head=head, restore_command=shlex.join(["git", "-C", str(repo), "worktree", "add", "--", str(target), branch]))
        for folder in logs:
            append_record(folder, note, line)
        check_paths(home, repo, target)
        idle(target)
        require(integrated(repo, target) == state, "Git登録・ブランチが検証中に変化しました")
        policy = Studio(home)
        latest = tree_evidence(repo, target, admin, head, policy, time.time() - idle_days(home) * 86400, False)
        require(proof == latest, "検証中に作業コピーが変化しました")
        receipt.update(status="unverified")
        git(repo, "worktree", "remove", "--", str(target))
        require(not os.path.lexists(target) and all(entry.get(b"worktree") != os.fsencode(target) for entry in refs(repo))
                and git(repo, "rev-parse", "--verify", "refs/heads/" + branch).strip() == head.encode(),
                "Gitは完了を返しましたが、ブランチと作業コピーの事後照合に失敗しました")
        for folder in logs:
            append_record(folder, "worktree-removal-results-" + stamp + ".tsv", line + "\tremoved")
        receipt.update(status="retired", reason="統合済みの作業コピーを閉じました。ブランチを保持しています",
                       verified=True, integration_ref=default, record=str(log_root / note))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        # Process arguments and Git diagnostics may include private input. Keep the UI
        # limited to our explanations and never print subprocess command or output.
        reason = str(exc) if isinstance(exc, ValueError) else "検証または復元記録の保存を完了できませんでした"
        receipt.update(reason=reason, verified=False)
    return receipt
