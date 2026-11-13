import pytest

from bb_server import admin_main


@pytest.fixture
def startup(tmp_path, monkeypatch):
    environment = {
        "BB_DATABASE_PATH": str(tmp_path / "business.db"),
        "BB_PORT": "8000",
        "BB_ADMIN_DATABASE_PATH": str(tmp_path / "admin.db"),
        "BB_ADMIN_PORT": "9001",
        # These must never open management to external interfaces or proxy trust.
        "BB_HOST": "0.0.0.0",
        "UVICORN_HOST": "0.0.0.0",
        "FORWARDED_ALLOW_IPS": "*",
    }
    for name, value in environment.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(admin_main, "is_elevated", lambda: False)
    calls = []
    monkeypatch.setattr(
        admin_main.uvicorn, "run", lambda *args, **kwargs: calls.append(kwargs)
    )
    return environment, calls


def test_listener_options_are_fixed_and_proxy_environment_is_ignored(startup):
    _, calls = startup
    admin_main.main()
    assert calls == [
        {"host": "127.0.0.1", "port": 9001, "proxy_headers": False, "access_log": False}
    ]


@pytest.mark.parametrize(
    "conflict", ["port", "database", "hardlink", "elevated", "bad_port"]
)
def test_unsafe_startup_never_runs_listener(startup, tmp_path, monkeypatch, conflict):
    environment, calls = startup
    if conflict == "port":
        monkeypatch.setenv("BB_ADMIN_PORT", environment["BB_PORT"])
    elif conflict == "database":
        monkeypatch.setenv("BB_ADMIN_DATABASE_PATH", environment["BB_DATABASE_PATH"])
    elif conflict == "hardlink":
        business = tmp_path / "business.db"
        business.touch()
        (tmp_path / "admin.db").hardlink_to(business)
    elif conflict == "elevated":
        monkeypatch.setattr(admin_main, "is_elevated", lambda: True)
    else:
        monkeypatch.setenv("BB_ADMIN_PORT", "65536")
    with pytest.raises((ValueError, RuntimeError)):
        admin_main.main()
    assert not calls
