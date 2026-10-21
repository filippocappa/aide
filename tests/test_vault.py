
import httpx

from aide.vault import Vault
from aide.webdav import USER, config
from test_api import AUTH
from test_study import NOTES, NOW, ROME, SLIDES, add_pdf, done, env, upload  # noqa: F401 (env is a fixture)

DAY = f"{NOW.astimezone(ROME):%Y-%m-%d}"
PAGE = f"Aide/macroeconomics/{DAY} The IS-LM model.md"


async def ready(env, tmp_path, *responses):
    api, study, worker, *_ = env([done(NOTES), *responses])
    lecture = upload(api).json()
    await worker.process(study.next_queued())
    return api, study, worker, lecture, Vault(tmp_path / "vault" / "Uni", study)


async def test_a_lecture_becomes_a_page_with_its_course_and_slides(env, tmp_path):
    api, study, worker, lecture, vault = await ready(env, tmp_path)
    add_pdf(api, course=study.course_by_name("macroeconomics")["id"])
    assert await vault.sync() == {"written": 3, "removed": 0}
    page = (vault.folder / PAGE).read_text()
    assert page.startswith(f"---\ncourse: macroeconomics\ndate: {DAY}\n")
    assert f"lecture: {lecture['id']}\ntags:\n  - lecture\n  - macroeconomics\n---\n\n# The IS-LM model\n" in page
    assert "[[Aide/macroeconomics/macroeconomics|macroeconomics]] · " in page and "## Summary\nIS meets LM." in page
    assert "> [!quote]- Transcript\n> [0:00] Today, the IS-LM model." in page
    index = (vault.folder / "Aide/macroeconomics/macroeconomics.md").read_text()
    assert f"[[Aide/macroeconomics/{DAY} The IS-LM model|" in index
    assert "Next exam: " in index and "[[Aide/macroeconomics/Files/Week 3 slides.pdf|Week 3 slides.pdf]]" in index
    assert (vault.folder / "Aide/macroeconomics/Files/Week 3 slides.pdf").read_bytes() == SLIDES
    assert await vault.sync() == {"written": 0, "removed": 0}  # nothing changed
    assert not list(vault.folder.rglob(".*.tmp"))

    async def unreachable():  # the calendar is down: the folders stay, only the exam line goes
        return []
    study.courses = unreachable
    assert await vault.sync() == {"written": 1, "removed": 0}
    assert (vault.folder / PAGE).exists() and "Next exam" not in (vault.folder / "Aide/macroeconomics/macroeconomics.md").read_text()


async def test_changed_notes_are_written_but_the_users_edits_stay(env, tmp_path):
    api, study, _, lecture, vault = await ready(env, tmp_path)
    await vault.sync()
    api.patch(f"/v1/lectures/{lecture['id']}", json={"notes": "New notes."}, headers=AUTH)
    assert (await vault.sync())["written"] == 1 and "New notes." in (vault.folder / PAGE).read_text()
    (vault.folder / PAGE).write_text("My own notes.")
    api.patch(f"/v1/lectures/{lecture['id']}", json={"notes": "Aide's again."}, headers=AUTH)
    await vault.sync()
    assert (vault.folder / PAGE).read_text() == "My own notes."
    (vault.folder / PAGE).unlink()  # deleted by the user: not brought back
    await vault.sync()
    assert not (vault.folder / PAGE).exists()


async def test_a_renamed_or_deleted_lecture_moves_or_removes_its_page(env, tmp_path):
    api, study, _, lecture, vault = await ready(env, tmp_path)
    await vault.sync()
    api.patch(f"/v1/lectures/{lecture['id']}", json={"title": "IS: LM?"}, headers=AUTH)
    assert await vault.sync() == {"written": 2, "removed": 1}  # the page and the course index
    renamed = vault.folder / f"Aide/macroeconomics/{DAY} IS LM.md"
    assert renamed.exists() and not (vault.folder / PAGE).exists()
    api.delete(f"/v1/lectures/{lecture['id']}", headers=AUTH)
    await vault.sync()
    assert not (vault.folder / "Aide").exists()  # empty folders go too


async def test_a_users_file_with_the_same_name_is_left_alone(env, tmp_path):
    api, study, _, lecture, vault = await ready(env, tmp_path)
    (vault.folder / PAGE).parent.mkdir(parents=True)
    (vault.folder / PAGE).write_text("Mine.")
    await vault.sync()
    assert (vault.folder / PAGE).read_text() == "Mine."
    api.delete(f"/v1/lectures/{lecture['id']}", headers=AUTH)
    await vault.sync()
    assert (vault.folder / PAGE).read_text() == "Mine."


def test_vault_setup_is_off_without_a_password(env):
    api, *_ = env()
    assert api.get("/v1/vault", headers=AUTH).json() == {"enabled": False}


def test_webdav_serves_the_folder_with_a_password(tmp_path):
    from wsgidav.wsgidav_app import WsgiDAVApp

    (tmp_path / "Uni").mkdir()
    app = WsgiDAVApp(config(str(tmp_path), "secret", 8789))
    dav = httpx.Client(transport=httpx.WSGITransport(app=app), base_url="http://cappa")
    assert dav.request("PROPFIND", "/Uni/", headers={"Depth": "1"}).status_code == 401
    good = httpx.BasicAuth(USER, "secret")
    assert dav.request("PROPFIND", "/Uni/", headers={"Depth": "1"}, auth=good).status_code == 207
    assert dav.put("/Uni/note.md", content=b"# Hi", auth=good).status_code in (201, 204)
    assert (tmp_path / "Uni" / "note.md").read_bytes() == b"# Hi"
    assert dav.get("/Uni/note.md", auth=httpx.BasicAuth(USER, "wrong")).status_code == 401
    assert dav.request("PROPFIND", "/:dir_browser/", headers={"Depth": "0"}).status_code in (401, 404)
    preflight = dav.options("/Uni/note.md", headers={"Origin": "app://obsidian.md",
                                                       "Access-Control-Request-Method": "PROPFIND"})
    assert preflight.headers["access-control-allow-origin"] == "app://obsidian.md"
