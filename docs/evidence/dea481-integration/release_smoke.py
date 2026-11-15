"""Run the Linux test bundle against isolated real FastAPI and Dart processes.

From repository root, under xvfb-run, using the locked dsh-plugin Python project.
Only synthetic accounts and a disposable session directory are used.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "dsh-plugin/probes"))
from space_live import Live  # noqa: E402

output = Path(__file__).resolve().parent
with Live() as live:
    wm_log = open(output / "release-wm.log", "w+")
    wm = subprocess.Popen(["openbox", "--sm-disable"], stdout=wm_log, stderr=wm_log)
    live.children.append((wm, wm_log))
    account = live.register("ReleaseSmoke")
    live.login(account)
    draft = live.call("create_draft", {
        "operation_id": "release-draft", "text": "DEA-481 isolated release smoke",
    })
    live.call("publish_draft", {
        "operation_id": "release-publish", "draft_id": draft["resource_id"],
        "expected_version": 1,
    })
    (live.root / "client/server.json").write_text(json.dumps({"server_url": live.api}))
    log = open(output / "release-ui.log", "w+")
    app = subprocess.Popen(
        [str(REPO / "client/build/linux/x64/release/bundle/bb_mobile")],
        env={**os.environ, "BB_SESSION_FILE": str(live.root / "client/session.json")},
        stdout=log, stderr=log,
    )
    live.children.append((app, log))
    time.sleep(5)
    assert app.poll() is None, "release app exited"
    window = subprocess.check_output(["xdotool", "search", "--name", "^BB$"]).splitlines()[0]
    window = window.decode()
    subprocess.run(["xdotool", "windowsize", "--sync", window, "1440", "900"], check=True)
    subprocess.run(["xdotool", "windowmove", window, "0", "0"], check=True)
    time.sleep(2)
    subprocess.run(["xdotool", "mousemove", "--window", window, "46", "155", "click", "1"], check=True)
    time.sleep(3)
    geometry = subprocess.check_output(["xdotool", "getwindowgeometry", "--shell", window]).decode()
    assert "WIDTH=1440" in geometry and "HEIGHT=900" in geometry, geometry
    subprocess.run(["import", "-window", window, str(output / "release-space.png")], check=True)
    assert len(live.call("list_posts")["items"]) == 1
    print(json.dumps({"release_process_alive": app.poll() is None,
                      "synthetic_post_count": 1, "window": geometry,
                      "screenshot": "release-space.png",
                      "scope": "Linux real release smoke, not a target-device acceptance"}))
