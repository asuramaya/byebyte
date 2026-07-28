# sutra_xen — the family's vendored Xen guest-surface reader.
#
# Guest-side pre-stage of the Xen adaptation program (Ra's dom0-seam
# doctrine, decision 32b88ff24f87; sequencing, decision 78954338af3d).
# Scope, exactly three things, none of which move when XEN.md lands:
#
#   1. virt_type() / is_guest() — is this box a Xen guest at all? Pills use
#      it to decide which truths they own locally vs which come from the
#      host seam.
#   2. balloon_target_kb() / balloon_headroom_kb() — the xen_memory sysfs
#      surface. Pure guest-local reads, zero contract dependency: the gap
#      between the hypervisor's granted target_kb and the guest kernel's
#      own MemTotal is real machinery (memory the balloon driver hasn't
#      onlined yet), not measurement noise — RAMstein's balloon-aware
#      totals need target_kb as the ceiling, never MemTotal.
#   3. refresh_host_telemetry() — the guest-side cache half of the dom0
#      seam: whatever an injected `fetch` callable returns gets cached to a
#      local status.json via sutra.write_status, so a pill reads host truth
#      the same way it reads its own daemon's status. The TRANSPORT itself
#      (orchestratord's host.telemetry method, over the guest<->dom0
#      bridge) is Ra's contract to define — XEN.md-GATED, NOT built here.
#      Per Ra's preliminary lean (his 904, addendum to the pre-stage order):
#      read-only telemetry rides UNAUTHENTICATED on trusted-local under the
#      connection-trust split — no node key for reads, signing is
#      actuation-only (phanspeed's pin/unpin, entirely outside this
#      module). The eventual node key itself is ALSO contract-gated: dom0
#      mints it at guest-create, TPM-sealed, dropped at a path XEN.md will
#      spec — do not invent key handling here either. Wire the real fetch
#      only once XEN.md lands.
#
# stdlib only. Vendored beside sutra.py, always together — imports it
# directly for write_status rather than reimplementing the atomic write.

SUTRA_XEN_VERSION = "0.1.1"

import os
import subprocess

import sutra


# --- virt detection -----------------------------------------------------
# systemd-detect-virt first — it identifies containers and other
# hypervisors honestly, not just xen. /proc/xen + the DMI vendor string are
# the fallback for a box without systemd or where the binary is missing;
# both are guest-only signals, absent on bare metal.

def _detect_virt(run):
    try:
        r = run(["systemd-detect-virt"], capture_output=True, text=True,
                 timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() or None


def _read_line(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def virt_type(proc_xen="/proc/xen", hypervisor_type="/sys/hypervisor/type",
              dmi_vendor="/sys/class/dmi/id/sys_vendor", run=subprocess.run):
    """'xen', 'none', or whatever systemd-detect-virt names (kvm, docker,
    ...) — an honest report, not a xen-or-nothing gate. The fallback path
    (systemd-detect-virt missing or erroring) only ever answers xen-or-none:
    that's the one hypervisor this family's guest seam cares about."""
    out = _detect_virt(run)
    if out is not None:
        return out
    if os.path.isdir(proc_xen) or _read_line(hypervisor_type) == "xen":
        return "xen"
    if "xen" in (_read_line(dmi_vendor) or "").lower():
        return "xen"
    return "none"


def is_guest(vtype=None):
    """True iff virt_type() (or a caller-supplied vtype, to skip a second
    detect call) names an actual hypervisor."""
    if vtype is None:
        vtype = virt_type()
    return vtype not in (None, "none")


# --- balloon reader -------------------------------------------------------

XEN_MEMORY_DIR = "/sys/devices/system/xen_memory/xen_memory0"


def _read_int(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def balloon_target_kb(xen_memory_dir=XEN_MEMORY_DIR):
    """The hypervisor's current balloon target for this guest, in KB, or
    None off-Xen / if the sysfs surface isn't present."""
    return _read_int(os.path.join(xen_memory_dir, "target_kb"))


def _meminfo_total_kb(meminfo_path="/proc/meminfo"):
    try:
        with open(meminfo_path) as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def balloon_headroom_kb(xen_memory_dir=XEN_MEMORY_DIR,
                         meminfo_path="/proc/meminfo"):
    """(target_kb, mem_total_kb, headroom_kb) — headroom is target minus
    what the guest kernel currently sees; positive means the hypervisor has
    granted more than is onlined yet. All three are None when
    balloon_target_kb() is None (off-Xen, or the surface is absent)."""
    target = balloon_target_kb(xen_memory_dir)
    if target is None:
        return None, None, None
    total = _meminfo_total_kb(meminfo_path)
    if total is None:
        return target, None, None
    return target, total, target - total


# --- host-telemetry cache: the guest-side half of the dom0 seam ---------

def refresh_host_telemetry(status_path, fetch, owner=None, mode=0o640):
    """Call `fetch()` — XEN.md-GATED; the real one is orchestratord's
    host.telemetry over the guest<->dom0 bridge, unauthenticated (reads
    ride trusted-local under the connection-trust split; signing is
    actuation-only and out of this module's scope) — injected here as a
    plain callable so nothing wires the actual crossing before that
    contract lands. Caches the return value via sutra.write_status.
    Returns the cached doc, or None (leaving any existing cache untouched)
    if fetch() raised or returned something that isn't a JSON object: a
    guest reads STALE host truth over NO truth, never a corrupted one."""
    try:
        doc = fetch()
    except Exception:  # noqa: BLE001 — an unbuilt transport, never crash the caller
        return None
    if not isinstance(doc, dict):
        return None
    sutra.write_status(status_path, doc, owner=owner, mode=mode)
    return doc
