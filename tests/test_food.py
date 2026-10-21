import base64
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent
from aide.backup import mirror_photos
from aide.channels.api import create_app
from aide.db import Database
from aide.food import FoodStore
from aide.photos import PhotoStore
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.food import food_tools
from test_api import AUTH, TOKEN, Block, FakeCalendar, FakeClient, call, done

ROME = ZoneInfo("Europe/Rome")
JPEG = b"\xff\xd8\xff\xe0fake-jpeg"


class RecordingClient(FakeClient):
    """Keeps every request, to see what the model was sent."""

    def __init__(self, responses):
        super().__init__(responses)
        self.requests: list[dict] = []

    async def _create(self, **kwargs):
        self.requests.append(kwargs)
        return await super()._create(**kwargs)


@pytest.fixture
def env(tmp_path):
    db = Database(":memory:")
    food = FoodStore(db.conn, ROME)
    photos = PhotoStore(tmp_path / "photos")

    def make(responses=()):
        client = RecordingClient(responses)
        agent = Agent(client, db, ToolRegistry(food_tools(food, photos, ROME)), model="m", smart_model="smart",
                      tz=ROME, photos=photos, delegate=False)
        app = create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, food=food)
        return TestClient(app), agent, food, photos, client
    yield make
    db.close()


def log_meal(**input):
    """A log_meal call (call() takes the tool's name as `name`, and so does log_meal)."""
    return ("tool_use", [Block(type="tool_use", id="t1", name="log_meal", input=input)])


def upload(api, data=JPEG, kind="image/jpeg"):
    return api.post("/v1/photos", content=data, headers={**AUTH, "Content-Type": kind})


def images(request: dict) -> list[str]:
    """The base64 images in a model request, oldest first."""
    return [b["source"]["data"] for m in request["messages"] if isinstance(m["content"], list)
            for b in m["content"] if b.get("type") == "image"]


def test_photo_upload_and_fetch(env):
    api, *_ = env()
    photo = upload(api).json()["id"]
    assert photo.startswith("p_")
    r = api.get(f"/v1/photos/{photo}", headers=AUTH)
    assert r.content == JPEG and r.headers["content-type"] == "image/jpeg"
    assert api.get("/v1/photos/p_0000000000000000", headers=AUTH).status_code == 404
    assert api.get("/v1/photos/..%2Faide.db", headers=AUTH).status_code == 404
    assert upload(api, b"").status_code == 400
    assert upload(api, kind="image/gif").status_code == 415
    assert upload(api, b"x" * 3_600_000).status_code == 413
    assert api.post("/v1/photos", content=JPEG, headers={"Content-Type": "image/jpeg"}).status_code == 401


def test_chat_with_a_photo_logs_the_meal(env):
    api, agent, food, *_ = env()
    photo = upload(api).json()["id"]
    api2, _, _, _, client = env([log_meal(name="Pasta al pomodoro", calories=652, protein_g=20.4,
                                      carbs_g=110, fat_g=15, photo_id=photo, notes="about 120 g dry pasta"),
                                 done("Pasta al pomodoro, about 650 kcal.")])
    body = api2.post("/v1/chat", json={"text": "", "photos": [photo]}, headers=AUTH).json()
    meal = food.day(food.today())[0]
    assert (meal["calories"], meal["protein_g"], meal["photo"]) == (650, 20, photo)  # rounded
    [attachment] = body["attachments"]
    assert attachment["type"] == "meals" and attachment["meals"][0]["name"] == "Pasta al pomodoro"
    # The model saw the photo as an image, with the line naming it.
    assert [r["model"] for r in client.requests] == ["smart", "smart"]  # a photo turn gets the smart model
    first = client.requests[0]["messages"][-1]["content"]
    assert first[0]["type"] == "image" and base64.b64decode(first[0]["source"]["data"]) == JPEG
    assert f"[Photo {photo}]" in first[1]["text"]
    # History shows the photo, not the line.
    user = api2.get("/v1/history", headers=AUTH).json()["messages"][0]
    assert user["text"] == "" and user["photos"] == [photo]
    api3, _, _, _, client = env([done("ok")])
    api3.post("/v1/chat", json={"text": "it was half"}, headers=AUTH)
    assert client.requests[0]["model"] == "m"


def test_only_the_last_three_photos_are_images(env):
    api, *_ = env()
    ids = [upload(api, JPEG + bytes([i])).json()["id"] for i in range(5)]
    for i in range(4):
        api, *_ = env([done("ok")])
        api.post("/v1/chat", json={"text": f"photo {i}", "photos": ids[i:i + 1]}, headers=AUTH)
    api, _, _, _, client = env([done("ok")])
    api.post("/v1/chat", json={"text": "and this", "photos": [ids[4]]}, headers=AUTH)
    seen = [base64.b64decode(d) for d in images(client.requests[0])]
    assert seen == [JPEG + bytes([i]) for i in (2, 3, 4)]


def test_unknown_or_too_many_photos_are_400(env):
    api, *_ = env()
    assert api.post("/v1/chat", json={"text": "hi", "photos": ["p_0000000000000000"]}, headers=AUTH).status_code == 400
    ids = [upload(api).json()["id"] for _ in range(5)]
    assert api.post("/v1/chat", json={"photos": ids}, headers=AUTH).status_code == 400
    assert api.post("/v1/chat", json={"text": "  "}, headers=AUTH).status_code == 400


def test_food_log_goes_to_coachs_food_chat(env):
    api, agent, food, *_ = env()
    photo = upload(api).json()["id"]
    yesterday = food.today() - timedelta(days=1)
    api, *_ = env([log_meal(name="Pizza", calories=900, protein_g=35, carbs_g=110, fat_g=32, photo_id=photo,
                        eaten_at=f"{yesterday}T20:00"), done("Pizza, about 900 kcal.")])
    body = api.post("/v1/food/log", json={"photos": [photo], "date": yesterday.isoformat()}, headers=AUTH).json()
    assert body["reply"] == "Pizza, about 900 kcal." and body["meals"][0]["name"] == "Pizza"
    chat = agent.db.app_conversation(body["conversation_id"])
    assert chat["agent"] == "coach" and chat["title"] == "Food log"
    said = api.get(f"/v1/history?conversation_id={body['conversation_id']}", headers=AUTH).json()["messages"][0]
    assert "I ate this on" in said["text"] and said["photos"] == [photo]
    # The next log goes to the same chat; a deleted one is made again.
    api, *_ = env([done("What was it?")])
    again = api.post("/v1/food/log", json={"text": "a snack"}, headers=AUTH).json()
    assert again["conversation_id"] == body["conversation_id"] and again["meals"] == []
    agent.delete_conversation(CONVERSATION, body["conversation_id"])
    api, *_ = env([done("ok")])
    assert api.post("/v1/food/log", json={"text": "a snack"}, headers=AUTH).json()["conversation_id"] != body["conversation_id"]
    assert api.post("/v1/food/log", json={}, headers=AUTH).status_code == 400


def test_food_endpoints(env):
    api, _, food, *_ = env()
    today = food.today()
    noon = datetime.combine(today, time(0, 1), ROME)  # early today: always in the past
    lunch = food.add("Salad", 420, 18, 30, 25, noon)
    food.add("Toast", 300, 10, 40, 10, noon - timedelta(days=2))
    body = api.get("/v1/food", headers=AUTH).json()
    assert body["date"] == today.isoformat()
    assert body["totals"] == {"calories": 420, "protein_g": 18, "carbs_g": 30, "fat_g": 25}
    assert body["goals"] == {"calories": None, "protein_g": None, "carbs_g": None, "fat_g": None}
    assert body["meals"][0]["eaten_at"] == noon.isoformat() and body["meals"][0]["photo"] is None

    days = api.get("/v1/food/days", headers=AUTH).json()["days"]
    assert len(days) == 7 and days[-1]["date"] == today.isoformat() and days[-1]["meals"] == 1
    assert days[-3]["totals"]["calories"] == 300 and days[-2]["meals"] == 0

    r = api.patch(f"/v1/food/meals/{lunch['id']}", json={"calories": 515, "notes": "with dressing"}, headers=AUTH)
    assert r.json()["calories"] == 520 and r.json()["notes"] == "with dressing"
    assert api.patch("/v1/food/meals/999", json={"calories": 1}, headers=AUTH).status_code == 404
    assert api.patch(f"/v1/food/meals/{lunch['id']}", json={"calories": -5}, headers=AUTH).status_code == 400

    goals = api.put("/v1/food/goals", json={"calories": 2400, "protein_g": 140}, headers=AUTH).json()
    assert goals == {"calories": 2400, "protein_g": 140, "carbs_g": None, "fat_g": None}
    assert api.get("/v1/food/goals", headers=AUTH).json() == goals

    assert api.delete(f"/v1/food/meals/{lunch['id']}", headers=AUTH).json() == {"ok": True}
    assert api.delete(f"/v1/food/meals/{lunch['id']}", headers=AUTH).status_code == 404


async def test_tools_correct_list_and_queue_a_delete(env):
    _, agent, food, *_ = env([call("update_meal", meal_id=1, calories=325, carbs_g=50), done("Fixed."),
                              call("set_food_goals", protein_g=140), done("Set."),
                              call("delete_meal", meal_id=1), done("Queued.")])
    food.add("Rice", 650, 12, 100, 4)
    turn = await agent.respond(CONVERSATION, "it was half")
    assert food.get(1)["calories"] == 330 and turn.attachments[0]["meals"][0]["carbs_g"] == 50
    await agent.respond(CONVERSATION, "aim for 140 g protein")
    assert food.goals()["protein_g"] == 140
    await agent.respond(CONVERSATION, "delete the rice")
    assert food.get(1) is not None and agent.pending(CONVERSATION) == ["Delete meal 'Rice' (" +
                                                                       f"{datetime.fromisoformat(food.get(1)['eaten_at']).astimezone(ROME):%a %d %b %H:%M}, 330 kcal)"]


def test_a_meal_in_the_future_is_refused(env):
    _, _, food, *_ = env()
    with pytest.raises(ValueError):
        food.add("Dinner", 500, 20, 50, 20, datetime.now(ROME) + timedelta(hours=3))


def test_backup_copies_only_new_photos(tmp_path):
    src, dst = tmp_path / "photos", tmp_path / "backup"
    store = PhotoStore(src)
    store.save(JPEG, "image/jpeg")
    assert mirror_photos(src, dst) == 1
    store.save(JPEG, "image/png")
    assert mirror_photos(src, dst) == 1 and len(list(dst.iterdir())) == 2
    assert mirror_photos(tmp_path / "none", dst) == 0
