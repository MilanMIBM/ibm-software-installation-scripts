"""Prepare a dedicated Db2 content store through the pod's local Db2 administrator."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field

IDENTIFIER = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,127}\Z")
DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
OS_USER = re.compile(r"[a-z_][a-z0-9_-]{0,31}\Z")
POOLS = {"CMDB_08KBP": 8192, "CMDB_32KBP": 32768}
SPACES = {
    "TSN_SYS_CMDB": (32768, "T", "CMDB_32KBP", "SYSTEM TEMPORARY", "IBMTEMPGROUP"),
    "TSN_USR_CMDB": (8192, "U", "CMDB_08KBP", "USER TEMPORARY", "IBMDEFAULTGROUP"),
    "TSN_REG_CMDB": (8192, "A", "CMDB_08KBP", "REGULAR", "IBMDEFAULTGROUP"),
}


class PreparationError(Exception):
    pass


@dataclass(frozen=True)
class Settings:
    database: str
    user: str
    schema: str
    pool_pages: int = 1000
    default_pool_pages: int = 49800
    require_32k: bool = False

    def __post_init__(self):
        for name in ("database", "user", "schema"):
            value = getattr(self, name)
            if not IDENTIFIER.fullmatch(value):
                raise PreparationError(f"{name} must be an ordinary SQL identifier (letters, digits, underscores)")
            object.__setattr__(self, name, value.upper())
        if self.user == "PUBLIC":
            raise PreparationError("Connection user cannot be PUBLIC")
        if not 1000 <= self.pool_pages <= 2147483647:
            raise PreparationError("buffer-pool pages must be between 1000 and 2147483647")
        if not 49800 <= self.default_pool_pages <= 2147483647:
            raise PreparationError("default buffer-pool pages must be between 49800 and 2147483647")


@dataclass
class Snapshot:
    config: dict[str, tuple[str, str]] = field(default_factory=dict)
    pools: dict[str, tuple[int, int]] = field(default_factory=dict)
    spaces: dict[str, tuple[int, str, str]] = field(default_factory=dict)
    schemas: dict[str, tuple[str, str]] = field(default_factory=dict)
    auth: tuple[str, ...] = ()
    use: dict[str, str] = field(default_factory=dict)
    table_count: int | None = None


def snapshot_sql(s: Settings) -> str:
    # Marked rows avoid dependence on localized CLP headings and status messages.
    return f"""CONNECT TO {s.database};
SELECT 'COGNOS|CFG|' || RTRIM(NAME) || '|' || RTRIM(VARCHAR(VALUE, 128)) || '|' || RTRIM(VARCHAR(DEFERRED_VALUE, 128)) FROM SYSIBMADM.DBCFG WHERE NAME IN ('applheapsz', 'locktimeout', 'codepage', 'codeset');
SELECT 'COGNOS|BP|' || RTRIM(BPNAME) || '|' || TRIM(CHAR(PAGESIZE)) || '|' || TRIM(CHAR(NPAGES)) FROM SYSCAT.BUFFERPOOLS;
SELECT 'COGNOS|TS|' || RTRIM(T.TBSPACE) || '|' || TRIM(CHAR(T.PAGESIZE)) || '|' || T.DATATYPE || '|' || RTRIM(B.BPNAME) FROM SYSCAT.TABLESPACES T JOIN SYSCAT.BUFFERPOOLS B ON T.BUFFERPOOLID = B.BUFFERPOOLID;
SELECT 'COGNOS|SCHEMA|' || RTRIM(SCHEMANAME) || '|' || RTRIM(OWNER) || '|' || OWNERTYPE FROM SYSCAT.SCHEMATA WHERE SCHEMANAME = '{s.schema}';
SELECT 'COGNOS|AUTH|' || CONNECTAUTH || '|' || CREATETABAUTH || '|' || IMPLSCHEMAAUTH FROM SYSCAT.DBAUTH WHERE GRANTEE = '{s.user}' AND GRANTEETYPE = 'U';
SELECT 'COGNOS|USE|' || RTRIM(TBSPACE) || '|' || USEAUTH FROM SYSCAT.TBSPACEAUTH WHERE GRANTEE = '{s.user}' AND GRANTEETYPE = 'U';
SELECT 'COGNOS|TABLES|' || TRIM(CHAR(COUNT(*))) FROM SYSCAT.TABLES WHERE TABSCHEMA NOT LIKE 'SYS%';
CONNECT RESET;
"""


def parse_snapshot(output: str) -> Snapshot:
    snap = Snapshot()
    try:
        for line in output.splitlines():
            if not line.strip().startswith("COGNOS|"):
                continue
            _, kind, *v = (part.strip() for part in line.strip().split("|"))
            if kind == "CFG":
                key, current, deferred = v
                snap.config[key] = current, deferred
            elif kind == "BP":
                key, size, pages = v
                snap.pools[key] = int(size), int(pages)
            elif kind == "TS":
                key, size, datatype, pool = v
                snap.spaces[key] = int(size), datatype, pool
            elif kind == "SCHEMA":
                key, owner, owner_type = v
                snap.schemas[key] = owner, owner_type
            elif kind == "AUTH":
                if len(v) != 3:
                    raise ValueError("invalid authorization row")
                snap.auth = tuple(v)
            elif kind == "USE":
                key, use = v
                snap.use[key] = use
            elif kind == "TABLES":
                (count,) = v
                snap.table_count = int(count)
    except ValueError as exc:
        raise PreparationError("Db2 catalog response was malformed; no changes made") from exc
    if set(snap.config) != {"applheapsz", "locktimeout", "codepage", "codeset"} or snap.table_count is None:
        raise PreparationError("Db2 catalog response was incomplete; no changes made")
    return snap


@dataclass
class Plan:
    statements: list[str] = field(default_factory=list)
    pending: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def ready(self) -> bool:
        return not (self.statements or self.pending or self.errors)


def plan(snap: Snapshot, s: Settings) -> Plan:
    result = Plan()
    sql = result.statements
    if snap.config["codepage"][0] != "1208" or snap.config["codeset"][0] != "UTF-8":
        result.errors.append("Database must use UTF-8 (code page 1208)")
    for name, target in (("applheapsz", 1024), ("locktimeout", 240)):
        try:
            current, deferred = map(int, snap.config[name])
        except ValueError:
            result.errors.append(f"Cannot verify numeric configuration for {name}")
            continue
        # Keep larger application heaps; a lock timeout is an exact duration.
        desired = max(target, current) if name == "applheapsz" else target
        if deferred != desired:
            sql.append(f"UPDATE DATABASE CONFIGURATION USING {name.upper()} {desired} DEFERRED;")
        if current != desired:
            result.pending.append(f"{name.upper()} must become {desired}; database reactivation requires separate scheduling")

    for name, size in {**POOLS, "IBMDEFAULTBP": 32768 if s.require_32k else None}.items():
        minimum = s.default_pool_pages if name == "IBMDEFAULTBP" else s.pool_pages
        actual = snap.pools.get(name)
        if actual is None:
            if name == "IBMDEFAULTBP":
                result.errors.append("IBMDEFAULTBP was not found")
            else:
                sql.append(f"CREATE BUFFERPOOL {name} IMMEDIATE SIZE {minimum} PAGESIZE {size};")
        elif size is not None and actual[0] != size:
            result.errors.append(f"{name} has incompatible page size {actual[0]}")
        elif actual[1] < 0:
            result.errors.append(f"{name} uses automatic sizing; review its allocation manually")
        elif actual[1] < minimum:
            sql.append(f"ALTER BUFFERPOOL {name} IMMEDIATE SIZE {minimum};")

    for name, (size, datatype, pool, clause, group) in SPACES.items():
        actual = snap.spaces.get(name)
        if actual is None:
            sql.append(f"CREATE {clause} TABLESPACE {name} IN DATABASE PARTITION GROUP {group} PAGESIZE {size} BUFFERPOOL {pool};")
        elif actual != (size, datatype, pool):
            result.errors.append(f"{name} has incompatible page size, type or buffer pool")
    if "USERSPACE1" not in snap.spaces:
        result.errors.append("USERSPACE1 was not found; review the database's default tablespace")

    if s.require_32k:
        for name in ("SYSCATSPACE", "USERSPACE1", "TEMPSPACE1"):
            actual = snap.spaces.get(name)
            if actual is None or actual[0] != 32768:
                result.errors.append(f"{name} must have 32768-byte pages for the Cognos database profile; create a new dedicated database")

    owner = snap.schemas.get(s.schema)
    if owner is None:
        sql.append(f"CREATE SCHEMA {s.schema} AUTHORIZATION {s.user};")
    elif owner != (s.user, "U"):
        result.errors.append(f"Schema {s.schema} is owned by {owner}, expected {s.user}")
    if not snap.auth or any(value not in {"Y", "G"} for value in snap.auth):
        sql.append(f"GRANT CONNECT, CREATETAB, IMPLICIT_SCHEMA ON DATABASE TO USER {s.user};")
    for name in ("TSN_USR_CMDB", "TSN_REG_CMDB", "USERSPACE1"):
        if snap.use.get(name) not in {"Y", "G"}:
            sql.append(f"GRANT USE OF TABLESPACE {name} TO USER {s.user};")
    return result


class Db2:
    def __init__(self, namespace: str, instance: str, pod: str | None, os_user: str):
        for name, value in (("namespace", namespace), ("instance", instance)):
            if not DNS_LABEL.fullmatch(value):
                raise PreparationError(f"{name} must be a Kubernetes DNS label")
        if not OS_USER.fullmatch(os_user):
            raise PreparationError("Invalid Db2 operating-system username")
        self.namespace, self.instance, self.pod, self.os_user = namespace, instance, pod, os_user

    @staticmethod
    def run(args: list[str], stdin: str | None = None) -> str:
        try:
            response = subprocess.run(args, input=stdin, text=True, capture_output=True, timeout=180, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PreparationError(f"Could not complete {args[0]} operation: {exc}") from exc
        if response.returncode:
            # Db2 diagnostics are useful; authentication material and arbitrary pod output are not.
            codes = sorted(set(re.findall(r"\b(?:SQL\d{4}[A-Z]|SQLSTATE=[0-9A-Z]{5})\b", response.stdout + response.stderr)))
            raise PreparationError(f"{args[0]} failed (exit {response.returncode})" + (": " + ", ".join(codes) if codes else "; check cluster authentication, access and pod status"))
        return response.stdout

    def resolve_pod(self) -> None:
        output = self.run(["oc", "get", "pods", "-n", self.namespace, "-l", f"app={self.instance}", "-o", "json"])
        try:
            pods = json.loads(output)["items"]
            matches = [p for p in pods if (not self.pod or p["metadata"]["name"] == self.pod)
                       and not p["metadata"].get("deletionTimestamp")
                       and p["status"].get("phase") == "Running"
                       and any(c["name"] == "db2u" and c.get("ready") for c in p["status"].get("containerStatuses", []))]
        except (KeyError, TypeError, ValueError) as exc:
            raise PreparationError("Could not read Db2 pod readiness") from exc
        if len(matches) != 1:
            raise PreparationError("Select exactly one running, ready Db2 pod for this instance with --pod")
        self.pod = matches[0]["metadata"]["name"]

    def sql(self, text: str) -> str:
        # CLP needs a real file; /dev/stdin is not accepted by these Db2 images.
        script = """set -eu
sql_file=$(mktemp /tmp/cognos-store.XXXXXX.sql)
trap 'rm -f "$sql_file"' EXIT
cat > "$sql_file"
chmod 644 "$sql_file"
su - OS_USER -c "db2 -stxf $sql_file"
""".replace("OS_USER", shlex.quote(self.os_user))
        return self.run(["oc", "exec", "-i", "-n", self.namespace, self.pod, "-c", "db2u", "--", "bash", "-c", script], text)


def report(result: Plan) -> None:
    for error in result.errors:
        print(f"[ERROR] {error}")
    for statement in result.statements:
        print(f"[CHANGE] {statement}")
    for pending in result.pending:
        print(f"[PENDING] {pending}")
    if result.ready:
        print("[PASS] Content-store catalog, configuration and direct grants match the preparation requirements")


def prepare(db: Db2, s: Settings, apply: bool) -> int:
    db.resolve_pod()
    snap = parse_snapshot(db.sql(snapshot_sql(s)))
    result = plan(snap, s)
    report(result)
    if result.errors:
        return 1
    if apply and result.statements:
        if snap.table_count:
            raise PreparationError("Application tables already exist; preparation is limited to an unused dedicated database")
        db.sql(f"CONNECT TO {s.database};\n" + "\n".join(result.statements) + "\nCONNECT RESET;\n")
        print("[INFO] Preparation applied; checking actual catalog and configuration values")
        result = plan(parse_snapshot(db.sql(snapshot_sql(s))), s)
        report(result)
    return 0 if result.ready else 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog="Exit 0: ready; 1: unsafe/unverifiable or command failure; 2: changes or reactivation still needed. Uses the current oc login; reads no passwords.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="read-only verification and change plan (default)")
    mode.add_argument("--apply", action="store_true", help="apply missing preparation to an unused dedicated database")
    parser.add_argument("--namespace", default=os.environ.get("PROJECT_CPD_INST_OPERANDS"), help="Db2 namespace; defaults to exported PROJECT_CPD_INST_OPERANDS")
    parser.add_argument("--instance", required=True, help="Db2 deployment/formation name, used as the pod's app label")
    parser.add_argument("--pod", help="select one pod if the instance has multiple ready Db2 pods")
    parser.add_argument("--database", default="BLUDB")
    parser.add_argument("--user", required=True, help="existing database connection authorization ID (ordinary SQL identifier)")
    parser.add_argument("--schema", help="connection schema; defaults to the uppercase authorization ID")
    parser.add_argument("--db2-os-user", default="db2inst1", help="local Db2 instance administrator inside the pod")
    parser.add_argument("--bufferpool-pages", type=int, default=1000, help="minimum size of each Cognos buffer pool (default: 1000 pages)")
    parser.add_argument("--default-bufferpool-pages", type=int, default=49800, help="minimum IBMDEFAULTBP size (default: 49800 pages)")
    parser.add_argument("--require-32k", action="store_true", help="validate 32K IBMDEFAULTBP and initial catalog/default/temporary tablespaces; never convert an existing database")
    args = parser.parse_args(argv)
    if not args.namespace:
        parser.error("--namespace or exported PROJECT_CPD_INST_OPERANDS is required")
    try:
        settings = Settings(args.database, args.user, args.schema or args.user, args.bufferpool_pages, args.default_bufferpool_pages, args.require_32k)
        db = Db2(args.namespace, args.instance, args.pod, args.db2_os_user)
        return prepare(db, settings, args.apply)
    except PreparationError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
