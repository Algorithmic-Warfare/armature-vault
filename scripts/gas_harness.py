#!/usr/bin/env python3
"""Measure the gas cost of every user-facing delivery-agreement feature.

Runs each feature as a real transaction on a disposable local Sui network and
records what the gas payer is charged:

  computation   gas units x gas price; scales with the reference gas price
  storage       new or grown objects, at the fixed storage price
  rebate        refund for objects the transaction deleted or shrank
  net           computation + storage - rebate: what the payer actually spends

When TriEx sponsors a transaction, the sponsor is the gas payer, so it pays the
computation and storage and also receives the rebate. Summing `net` over every
transaction of an agreement's life gives the sponsor's cost per agreement.

Covers `delivery_agreements` (open path, config admin) and the
`agreement_roles` claim gate (player, OU and large gates). Payments are SUI;
items are multicoin balances from a local collection. Warehouse-receipt
deposits and redemptions are game-side and are not measured here.

Usage (from anywhere):
  python3 scripts/gas_harness.py run      # fresh chain, publish, measure, report, stop
  python3 scripts/gas_harness.py run --keep   # same, but leave the chain running
  python3 scripts/gas_harness.py up       # start the chain only
  python3 scripts/gas_harness.py down     # stop it
  python3 scripts/gas_harness.py reset    # stop it and delete all state

Everything lives under .gas-harness/ (git-ignored): chain state, an isolated
HOME with throwaway keys, the generated Move workspace, and results/ with
gas-report.json and gas-report.md. Needs `sui` on PATH (1.72+).
"""

import argparse
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGES = ROOT / "packages"
STATE = ROOT / ".gas-harness"
HOME = STATE / "home"
NETWORK = STATE / "network"
MOVE = STATE / "move"
RESULTS = STATE / "results"
PID_FILE = STATE / "sui.pid"
LOG_FILE = STATE / "sui.log"
PUBFILE = STATE / "Pub.local.toml"

RPC_PORT = int(os.environ.get("GAS_HARNESS_RPC_PORT", "19100"))
FAUCET_PORT = int(os.environ.get("GAS_HARNESS_FAUCET_PORT", "19223"))
RPC_URL = f"http://127.0.0.1:{RPC_PORT}"
FAUCET_URL = f"http://127.0.0.1:{FAUCET_PORT}/v2/gas"

MULTICOIN_REV = "2772c26d24c02671726d39f167b8f772777875d9"
ARMATURE_REV = "ae60685f888ac5dd4d24413fb989002ef5315c74"

SUI = "0x2::sui::SUI"
CLOCK = "@0x6"
GAS_BUDGET = "2000000000"
MIST_PER_SUI = 1_000_000_000

# Agreement terms used throughout, in MIST of SUI.
REWARD = 100_000_000          # 0.1 SUI
COLLATERAL = 500_000_000      # 0.5 SUI
POST_FEE = 10_000_000         # 0.01 SUI
DELIVERY_FEE_BPS = 250        # 2.5%
CARGO_ASSET = 7
CARGO_QTY = 10
ACCEPT_WINDOW_MS = 10 * 60 * 1000
HAUL_MS = 10 * 60 * 1000
SHORT_HAUL_MS = 1_000         # for default: wait it out on the local chain

ACTORS = ("admin", "lister", "hauler", "member", "other")

# Generated manifests: each package depends on its siblings by local path, so
# every type resolves to the packages published on this chain.
MANIFESTS = {
    "multicoin": [],
    "armature": [],
    "agreements": ["multicoin"],
    "delivery_agreements": ["agreements", "multicoin"],
    "roles": ["armature"],
    "agreement_roles": ["agreements", "delivery_agreements", "roles", "armature", "multicoin"],
}
PUBLISH_ORDER = tuple(MANIFESTS)


def say(msg):
    print(msg, flush=True)


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


# === Chain ===

def sui(*args, check=True):
    env = dict(os.environ, HOME=str(HOME))
    out = subprocess.run(["sui", *args], capture_output=True, text=True, env=env)
    if check and out.returncode != 0:
        fail(f"sui {' '.join(args[:3])} failed:\n{out.stdout[-3000:]}\n{out.stderr[-3000:]}")
    return out


def sui_json(*args):
    out = sui(*args, "--json")
    text = out.stdout
    start = min(i for i in (text.find("{"), text.find("[")) if i >= 0)
    return json.loads(text[start:])


def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []})
    req = urllib.request.Request(RPC_URL, body.encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())["result"]


def rpc_ready():
    try:
        rpc("sui_getLatestCheckpointSequenceNumber")
        return True
    except Exception:
        return False


def running():
    if not PID_FILE.exists():
        return False
    try:
        os.kill(int(PID_FILE.read_text()), 0)
    except (OSError, ValueError):
        return False
    return rpc_ready()


def up():
    STATE.mkdir(exist_ok=True)
    HOME.mkdir(exist_ok=True)
    if running():
        say(f"local chain already running at {RPC_URL}")
        return
    if not (NETWORK / "network.yaml").exists():
        NETWORK.mkdir(exist_ok=True)
        say("creating genesis")
        sui("genesis", "--force", "--with-faucet", "--working-dir", str(NETWORK))
    say(f"starting local chain at {RPC_URL}")
    log = open(LOG_FILE, "w")
    proc = subprocess.Popen(
        ["sui", "start", "--network.config", str(NETWORK),
         f"--with-faucet=127.0.0.1:{FAUCET_PORT}", "--fullnode-rpc-port", str(RPC_PORT)],
        stdout=log, stderr=log, env=dict(os.environ, HOME=str(HOME)), start_new_session=True,
    )
    PID_FILE.write_text(str(proc.pid))
    for _ in range(90):
        if proc.poll() is not None:
            fail(f"local chain exited; see {LOG_FILE}")
        if rpc_ready():
            break
        time.sleep(1)
    else:
        fail("local chain did not become ready")
    init_client()


def down():
    if PID_FILE.exists():
        try:
            os.killpg(int(PID_FILE.read_text()), signal.SIGTERM)
        except (OSError, ValueError):
            pass
        PID_FILE.unlink()
    say("local chain stopped")


def init_client():
    config = HOME / ".sui" / "sui_config" / "client.yaml"
    if not config.exists():
        sui("client", "-y", "addresses", check=False)
    envs = sui("client", "envs", "--json", check=False).stdout
    if '"localnet"' not in envs:
        sui("client", "new-env", "--alias", "localnet", "--rpc", RPC_URL)
    sui("client", "switch", "--env", "localnet")


def addresses():
    data = sui_json("client", "addresses")
    return {alias: addr for alias, addr in data["addresses"]}


def create_actors():
    known = addresses()
    for actor in ACTORS:
        if actor not in known:
            sui("client", "new-address", "ed25519", actor)
    known = addresses()
    for actor in ACTORS:
        for _ in range(5):
            if sui("client", "faucet", "--address", known[actor], "--url", FAUCET_URL,
                   check=False).returncode == 0:
                break
            time.sleep(1)
        else:
            fail(f"could not fund {actor}")
    # The faucet sends asynchronously; wait until every actor has a coin.
    for actor in ACTORS:
        for _ in range(30):
            coins = rpc("suix_getCoins", [known[actor], SUI, None, 1])
            if coins["data"]:
                break
            time.sleep(1)
        else:
            fail(f"faucet coins never reached {actor}")
    return {actor: known[actor] for actor in ACTORS}


def use(actor):
    sui("client", "switch", "--address", actor)


def now_ms():
    clock = rpc("sui_getObject", ["0x6", {"showContent": True}])
    return int(clock["data"]["content"]["fields"]["timestamp_ms"])


# === Publishing ===

def cached_sources(repo, rev, subdir):
    base = HOME / ".move" / "git"
    for root in (base, pathlib.Path.home() / ".move" / "git"):
        for path in root.glob(f"*{repo}*{rev}*/{subdir}/sources"):
            return path
    return None


def prepare_workspace():
    # Fetch the pinned git dependencies into the cache by building a package
    # that uses them.
    sui("move", "build", "--path", str(PACKAGES / "extensions" / "agreement_roles"),
        "-e", "testnet_stillness")
    sources = {
        "multicoin": cached_sources("multicoin", MULTICOIN_REV, "packages/multicoin"),
        "armature": cached_sources("armature", ARMATURE_REV, "packages/armature_framework"),
        "agreements": PACKAGES / "primitives" / "agreements" / "sources",
        "delivery_agreements": PACKAGES / "composites" / "delivery_agreements" / "sources",
        "roles": PACKAGES / "primitives" / "roles" / "sources",
        "agreement_roles": PACKAGES / "extensions" / "agreement_roles" / "sources",
    }
    for name, src in sources.items():
        if src is None or not src.is_dir():
            fail(f"could not find sources for {name}")
    shutil.rmtree(MOVE, ignore_errors=True)
    for name, deps in MANIFESTS.items():
        pkg = MOVE / name
        shutil.copytree(sources[name], pkg / "sources")
        lines = ["[package]", f'name = "{name}"', 'edition = "2024"', 'version = "0.0.1"', "",
                 "[dependencies]"]
        lines += [f'{dep} = {{ local = "../{dep}" }}' for dep in deps]
        (pkg / "Move.toml").write_text("\n".join(lines) + "\n")
    PUBFILE.unlink(missing_ok=True)


def created(result, suffix):
    """IDs of objects the transaction created whose type ends with `suffix`."""
    return [c["objectId"] for c in result.get("objectChanges", [])
            if c.get("type") == "created" and c["objectType"].endswith(suffix)]


def created_containing(result, needle):
    return [c["objectId"] for c in result.get("objectChanges", [])
            if c.get("type") == "created" and needle in c["objectType"]]


def publish_all():
    prepare_workspace()
    use("admin")
    pkgs, publishes = {}, {}
    for name in PUBLISH_ORDER:
        say(f"publishing {name}")
        result = sui_json("client", "test-publish", str(MOVE / name), "--build-env", "testnet",
                          "--pubfile-path", str(PUBFILE), "--gas-budget", GAS_BUDGET)
        if result["effects"]["status"]["status"] != "success":
            fail(f"publishing {name} failed: {result['effects']['status']}")
        pkgs[name] = next(c["packageId"] for c in result["objectChanges"]
                          if c["type"] == "published")
        publishes[name] = gas_of(result)
        if name == "delivery_agreements":
            # `init` shares the config and gives the publisher the admin cap.
            config = created(result, "::config::Config")[0]
            admin_cap = created(result, "::config::AdminCap")[0]
    return pkgs, config, admin_cap, publishes


# === Gas ===

def gas_of(result):
    used = result["effects"]["gasUsed"]
    computation = int(used["computationCost"])
    storage = int(used["storageCost"])
    rebate = int(used["storageRebate"])
    return {
        "computation": computation,
        "storage": storage,
        "rebate": rebate,
        "non_refundable": int(used.get("nonRefundableStorageFee", 0)),
        "net": computation + storage - rebate,
    }


class Ptb:
    """A programmable transaction block for `sui client ptb`."""

    def __init__(self):
        self.args = []

    def call(self, target, *args, types=None, assign=None):
        self.args += ["--move-call", target]
        if types:
            self.args.append("<" + ",".join(types) + ">")
        self.args += [str(a) for a in args]
        if assign:
            self.args += ["--assign", assign]
        return self

    def split_gas(self, amounts, assign):
        self.args += ["--split-coins", "gas", "[" + ",".join(str(a) for a in amounts) + "]",
                      "--assign", assign]
        return self

    def vec(self, type_, items, assign):
        self.args += ["--make-move-vec", f"<{type_}>", "[" + ",".join(items) + "]",
                      "--assign", assign]
        return self

    def transfer(self, items, to):
        self.args += ["--transfer-objects", "[" + ",".join(items) + "]", to]
        return self

    def run(self, actor):
        use(actor)
        result = sui_json("client", "ptb", *self.args, "--gas-budget", GAS_BUDGET)
        status = result["effects"]["status"]
        if status["status"] != "success":
            fail(f"transaction failed: {status}\n{' '.join(self.args)}")
        return result


# === Harness ===

class Harness:
    def __init__(self, addrs, pkgs, config, admin_cap):
        self.a = addrs
        self.p = pkgs
        self.config = config
        self.admin_cap = admin_cap
        self.collection = None
        self.collection_cap = None
        self.ou = None
        self.rows = []          # one per measured transaction
        self.lifecycles = []    # one per agreement life

    # --- helpers ---

    def target(self, pkg, module, fun):
        return f"{self.p[pkg]}::{module}::{fun}"

    def at(self, actor):
        return "@" + self.a[actor]

    def measure(self, feature, actor, ptb, category, note=""):
        result = ptb.run(actor)
        row = {"feature": feature, "actor": actor, "category": category, "note": note,
               "digest": result["digest"], **gas_of(result)}
        self.rows.append(row)
        say(f"  {feature:<44} net {row['net']:>12,} MIST")
        return result, row

    def setup(self):
        # Items: a multicoin collection the admin mints from.
        res = Ptb().call(self.target("multicoin", "multicoin", "create_collection")).run("admin")
        self.collection = created(res, "::multicoin::Collection")[0]
        self.collection_cap = created(res, "::multicoin::CollectionCap")[0]
        # An OU whose board is `member`.
        res = (Ptb()
               .call(self.target("armature", "governance", "init_board"),
                     f"vector[{self.at('member')}]", assign="init")
               .call(self.target("armature", "ou", "create"), "init", '"haulers"', '""')
               .run("member"))
        self.ou = created(res, "::ou::OU")[0]

    def mint(self, qty, asset, to):
        res = (Ptb().call(self.target("multicoin", "multicoin", "mint_balance"),
                          "@" + self.collection_cap, "@" + self.collection, asset, qty,
                          assign="b")
               .transfer(["b"], self.at(to)).run("admin"))
        return created(res, "::multicoin::Balance")[0]

    def spec(self, ptb, assign):
        return ptb.call(self.target("agreements", "spec", "new"), "@" + self.collection,
                        CARGO_ASSET, CARGO_QTY, assign=assign)

    # --- config admin ---

    def admin_features(self):
        say("config admin")
        cfg, cap = "@" + self.config, "@" + self.admin_cap
        c = lambda fun: self.target("delivery_agreements", "config", fun)  # noqa: E731
        self.measure("admin: approve_currency<SUI>", "admin",
                     Ptb().call(c("approve_currency"), cap, cfg, types=[SUI]), "admin")
        self.measure("admin: set_post_fee<SUI>", "admin",
                     Ptb().call(c("set_post_fee"), cap, cfg, POST_FEE, types=[SUI]), "admin")
        self.measure("admin: set_delivery_fee_bps", "admin",
                     Ptb().call(c("set_delivery_fee_bps"), cap, cfg, DELIVERY_FEE_BPS), "admin")
        self.measure("admin: set_treasury", "admin",
                     Ptb().call(c("set_treasury"), cap, cfg, self.at("admin")), "admin")

    def admin_teardown_features(self):
        say("config admin (revoke / clear)")
        cfg, cap = "@" + self.config, "@" + self.admin_cap
        c = lambda fun: self.target("delivery_agreements", "config", fun)  # noqa: E731
        self.measure("admin: clear_post_fee", "admin",
                     Ptb().call(c("clear_post_fee"), cap, cfg), "admin")
        self.measure("admin: revoke_currency<SUI>", "admin",
                     Ptb().call(c("revoke_currency"), cap, cfg, types=[SUI]), "admin")

    # --- listing ---

    def post_open(self, haul_ms=HAUL_MS, label="post (open)"):
        cargo = self.mint(CARGO_QTY, CARGO_ASSET, "lister")
        ptb = Ptb().split_gas([REWARD, POST_FEE], "coins")
        self.spec(ptb, "want")
        ptb.call(self.target("delivery_agreements", "delivery", "post"),
                 "@" + cargo, "coins.0", "want", COLLATERAL, now_ms() + ACCEPT_WINDOW_MS,
                 haul_ms, self.at("lister"), "@" + self.config, "coins.1", CLOCK,
                 types=[SUI, SUI], assign="cap")
        ptb.transfer(["cap"], self.at("lister"))
        res, row = self.measure(label, "lister", ptb, "lister")
        return self.agreement_of(res), created(res, "::delivery::ListerCap")[0], row

    def principals(self, ptb, specs):
        names = []
        for i, (kind, value) in enumerate(specs):
            name = f"p{i}"
            ptb.call(self.target("roles", "acl", kind), value, assign=name)
            names.append(name)
        ptb.vec(f"{self.p['roles']}::acl::Principal", names, "principals")

    def post_for(self, specs, label):
        cargo = self.mint(CARGO_QTY, CARGO_ASSET, "lister")
        ptb = Ptb().split_gas([REWARD, POST_FEE], "coins")
        self.spec(ptb, "want")
        self.principals(ptb, specs)
        ptb.call(self.target("agreement_roles", "claim", "post_for"),
                 "@" + cargo, "coins.0", "want", COLLATERAL, now_ms() + ACCEPT_WINDOW_MS,
                 HAUL_MS, self.at("lister"), "principals", "@" + self.config, "coins.1",
                 CLOCK, types=[SUI, SUI], assign="cap")
        ptb.transfer(["cap"], self.at("lister"))
        res, row = self.measure(label, "lister", ptb, "lister (claim gate)")
        return self.agreement_of(res), created(res, "::delivery::ListerCap")[0], row

    def draft_gate_publish(self, specs, label):
        cargo = self.mint(CARGO_QTY, CARGO_ASSET, "lister")
        ptb = Ptb().split_gas([REWARD, POST_FEE], "coins")
        self.spec(ptb, "want")
        self.principals(ptb, specs)
        ptb.call(self.target("delivery_agreements", "delivery", "draft"),
                 "@" + cargo, "coins.0", "want", COLLATERAL, now_ms() + ACCEPT_WINDOW_MS,
                 HAUL_MS, self.at("lister"), "@" + self.config, "coins.1", CLOCK,
                 types=[SUI, SUI], assign="draft")
        ptb.call(self.target("agreement_roles", "claim", "require_to_claim"), "draft",
                 "principals", types=[SUI])
        ptb.call(self.target("delivery_agreements", "delivery", "publish"), "draft",
                 types=[SUI], assign="cap")
        ptb.transfer(["cap"], self.at("lister"))
        res, row = self.measure(label, "lister", ptb, "lister (claim gate)")
        return self.agreement_of(res), created(res, "::delivery::ListerCap")[0], row

    @staticmethod
    def agreement_of(res):
        return created_containing(res, "::delivery::DeliveryAgreement<")[0]

    def cancel(self, agreement, cap):
        ptb = (Ptb().call(self.target("delivery_agreements", "delivery", "cancel"),
                          "@" + agreement, "@" + cap, CLOCK, types=[SUI], assign="out")
               .transfer(["out.0", "out.1"], self.at("lister")))
        return self.measure("cancel", "lister", ptb, "lister")[1]

    # --- hauling ---

    def accept_open(self, agreement):
        ptb = (Ptb().split_gas([COLLATERAL], "c")
               .call(self.target("delivery_agreements", "delivery", "accept"),
                     "@" + agreement, "c.0", CLOCK, types=[SUI], assign="cargo")
               .transfer(["cargo"], self.at("hauler")))
        return self.measure("accept (open)", "hauler", ptb, "hauler")[1]

    def accept_gated(self, agreement, actor, via_ou, label):
        ptb = Ptb().split_gas([COLLATERAL], "c")
        ptb.call(self.target("delivery_agreements", "delivery", "begin_accept"),
                 "@" + agreement, CLOCK, types=[SUI], assign="req")
        if via_ou:
            ptb.call(self.target("agreement_roles", "claim", "satisfy"), "req", "@" + self.ou)
        else:
            ptb.call(self.target("agreement_roles", "claim", "satisfy_directly"), "req")
        ptb.call(self.target("delivery_agreements", "delivery", "finish_accept"),
                 "@" + agreement, "req", "c.0", CLOCK, types=[SUI], assign="cargo")
        ptb.transfer(["cargo"], self.at(actor))
        return self.measure(label, actor, ptb, "hauler (claim gate)")[1]

    def deliver(self, agreement, actor="hauler"):
        want = self.mint(CARGO_QTY, CARGO_ASSET, actor)
        ptb = Ptb().call(self.target("delivery_agreements", "delivery", "deliver"),
                         "@" + agreement, "@" + want, CLOCK, types=[SUI])
        return self.measure("deliver", actor, ptb, "anyone")[1]

    def forfeit(self, agreement):
        ptb = Ptb().call(self.target("delivery_agreements", "delivery", "forfeit"),
                         "@" + agreement, CLOCK, types=[SUI])
        return self.measure("forfeit", "hauler", ptb, "hauler")[1]

    def default(self, agreement):
        ptb = Ptb().call(self.target("delivery_agreements", "delivery", "default"),
                         "@" + agreement, CLOCK, types=[SUI])
        return self.measure("default", "other", ptb, "anyone")[1]

    def wait_past(self, ms):
        deadline = now_ms() + ms + 500
        while now_ms() < deadline:
            time.sleep(0.5)

    # --- lifecycles ---

    def life(self, name, rows):
        total = {k: sum(r[k] for r in rows)
                 for k in ("computation", "storage", "rebate", "net")}
        self.lifecycles.append({"lifecycle": name, "steps": [r["feature"] for r in rows],
                                **total})
        say(f"= {name:<46} net {total['net']:>12,} MIST")

    def run_all(self):
        self.admin_features()

        say("open path")
        ag, cap, post = self.post_open()
        self.life("open: post, accept, deliver",
                  [post, self.accept_open(ag), self.deliver(ag)])

        ag, cap, post = self.post_open(haul_ms=SHORT_HAUL_MS)
        acc = self.accept_open(ag)
        self.wait_past(SHORT_HAUL_MS)
        self.life("open: post, accept, default", [post, acc, self.default(ag)])

        ag, cap, post = self.post_open()
        self.life("open: post, accept, forfeit", [post, self.accept_open(ag), self.forfeit(ag)])

        ag, cap, post = self.post_open()
        self.life("open: post, cancel", [post, self.cancel(ag, cap)])

        say("claim gate (agreement_roles)")
        ag, cap, post = self.post_for([("player", self.at("hauler"))],
                                      "post_for (1 player)")
        acc = self.accept_gated(ag, "hauler", False, "accept as listed player")
        self.life("gated player: post_for, accept, deliver", [post, acc, self.deliver(ag)])

        ag, cap, post = self.post_for([("ou", "@" + self.ou)], "post_for (1 OU)")
        acc = self.accept_gated(ag, "member", True, "accept as OU board member")
        self.life("gated OU: post_for, accept, deliver",
                  [post, acc, self.deliver(ag, actor="member")])

        ag, cap, post = self.draft_gate_publish(
            [("ou", "@" + self.ou), ("player", self.at("hauler"))],
            "draft + require_to_claim + publish (OU, player)")
        acc = self.accept_gated(ag, "member", True, "accept as OU board member (2-entry gate)")
        self.life("gated draft: draft/gate/publish, accept, deliver",
                  [post, acc, self.deliver(ag, actor="member")])

        # Worst case: a full 32-principal gate, matched by the last entry.
        fillers = [("machine", "@0x" + format(0x1000 + i, "064x")) for i in range(31)]
        ag, cap, post = self.post_for(fillers + [("player", self.at("hauler"))],
                                      "post_for (32 principals)")
        acc = self.accept_gated(ag, "hauler", False, "accept matching 32nd principal")
        self.life("gated 32 principals: post_for, accept, deliver",
                  [post, acc, self.deliver(ag)])

        ag, cap, post = self.post_for([("player", self.at("hauler"))],
                                      "post_for (1 player)")
        self.life("gated player: post_for, cancel", [post, self.cancel(ag, cap)])

        self.admin_teardown_features()


# === Report ===

def sui_amount(mist):
    return f"{mist / MIST_PER_SUI:.6f}"


def write_report(h, publishes, gas_price):
    RESULTS.mkdir(parents=True, exist_ok=True)
    data = {"rpc": RPC_URL, "reference_gas_price": gas_price,
            "terms": {"reward": REWARD, "collateral": COLLATERAL, "post_fee": POST_FEE,
                      "delivery_fee_bps": DELIVERY_FEE_BPS},
            "publish": publishes, "transactions": h.rows, "lifecycles": h.lifecycles}
    (RESULTS / "gas-report.json").write_text(json.dumps(data, indent=2) + "\n")

    def table(rows, key):
        out = [f"| {key} | computation | storage | rebate | outlay | net (MIST) | net (SUI) |",
               "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for r in rows:
            outlay = r["computation"] + r["storage"]
            out.append(f"| {r[key]} | {r['computation']:,} | {r['storage']:,} | "
                       f"{r['rebate']:,} | {outlay:,} | {r['net']:,} | {sui_amount(r['net'])} |")
        return "\n".join(out)

    total = {k: sum(r[k] for r in h.rows) for k in ("computation", "storage", "rebate", "net")}
    publish_rows = [{"package": name, **g} for name, g in publishes.items()]

    seen, features = set(), []
    for r in h.rows:
        if r["feature"] not in seen:
            seen.add(r["feature"])
            features.append(r)
    lines = [
        "# Delivery agreements: gas per feature",
        "",
        f"Local network, reference gas price {gas_price} MIST per gas unit. Computation "
        "scales with the reference gas price; storage and rebate do not. `net` is "
        "computation + storage - rebate, what a sponsor pays.",
        "",
        "## Per transaction (first run of each feature)",
        "",
        table(features, "feature"),
        "",
        "## Per agreement life (sum of its transactions)",
        "",
        "`outlay` is what the sponsor fronts before any rebate; `net` is its cost once the "
        "agreement's objects are deleted and their storage is refunded to the sponsor of the "
        "closing transaction.",
        "",
        table(h.lifecycles, "lifecycle"),
        "",
        "## Whole run",
        "",
        f"{len(h.rows)} measured transactions: net {total['net']:,} MIST "
        f"({sui_amount(total['net'])} SUI); computation {total['computation']:,}, "
        f"storage {total['storage']:,}, rebate {total['rebate']:,}.",
        "",
        "## One-time publish (not sponsored traffic)",
        "",
        table(publish_rows, "package"),
        "",
    ]
    (RESULTS / "gas-report.md").write_text("\n".join(lines))
    say(f"\nreport: {RESULTS / 'gas-report.md'}")


def run(keep=False):
    reset_state()
    up()
    addrs = create_actors()
    pkgs, config, admin_cap, publishes = publish_all()
    h = Harness(addrs, pkgs, config, admin_cap)
    h.setup()
    h.run_all()
    write_report(h, publishes, int(rpc("suix_getReferenceGasPrice")))
    if not keep:
        down()


def reset_state():
    down()
    shutil.rmtree(STATE, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=["run", "up", "down", "reset"])
    ap.add_argument("--keep", action="store_true", help="leave the chain running after `run`")
    args = ap.parse_args()
    if shutil.which("sui") is None:
        fail("sui not found on PATH")
    if args.command == "run":
        run(keep=args.keep)
    else:
        {"up": up, "down": down, "reset": reset_state}[args.command]()


if __name__ == "__main__":
    main()
