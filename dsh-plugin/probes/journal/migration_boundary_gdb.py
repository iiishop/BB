# GDB observer: stop at syscall entry, verify durable artifacts, kill owned inferior.
# Linux x86_64 only. No code, memory, syscall arguments or external files are patched.
import hashlib
import json
import os

import gdb

ledger = os.environ["PROBE_MIGRATION_FILE"]
proof = os.environ["PROBE_MIGRATION_PROOF"]
daemon_pid = int(os.environ["PROBE_DAEMON_PID"])


class RenameBarrier:
    def stop(self):
        inferior = gdb.selected_inferior()
        number = int(gdb.parse_and_eval("$orig_rax"))
        registers = {82: ("$rdi", "$rsi"), 264: ("$rsi", "$r10"), 316: ("$rsi", "$r10")}
        if number not in registers:
            return False
        try:
            a, b = [
                gdb.parse_and_eval(f"(char*){reg}").string()
                for reg in registers[number]
            ]
        except gdb.error:
            return False
        if b != ledger or not a.startswith(ledger + ".tmp-"):
            return False
        # On x86 syscall entry rax is -ENOSYS; don't accept syscall-exit evidence.
        if int(gdb.parse_and_eval("$rax")) != -38:
            return False
        with open(ledger, "rb") as f:
            original = f.read()
        with open(ledger + ".v1-backup", "rb") as f:
            backup = f.read()
        with open(a, "rb") as f:
            staged = f.read()
        assert inferior.pid != daemon_pid and inferior.pid > 0
        assert original == backup and json.loads(original)["version"] == 1
        assert json.loads(staged)["version"] == 2
        with open(proof, "w") as f:
            json.dump(
                {
                    "edge": "rename-syscall-entry",
                    "original_version": 1,
                    "staged_version": 2,
                    "backup_equal": True,
                    "original_sha256": hashlib.sha256(original).hexdigest(),
                    "inferior_pid": inferior.pid,
                },
                f,
            )
        return True


gdb.execute("catch syscall rename renameat renameat2")
gdb.execute("run")
barrier = RenameBarrier()
while gdb.selected_inferior().pid:
    if barrier.stop():
        gdb.execute("kill")
        break
    gdb.execute("continue")
assert os.path.exists(proof), "rename barrier not reached"
