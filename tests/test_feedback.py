from aide.feedback import FeedbackStore, render
from test_api import AUTH, call, done, env  # noqa: F401 (fixture)


def test_a_rated_reply_keeps_its_whole_turn_and_shows_in_the_history(env):  # noqa: F811
    client, agent, _ = env([call("create_reminder", title="Bins"), done("Added it."), done("Hi again.")])
    chat = client.post("/v1/conversations", json={}, headers=AUTH).json()["id"]
    body = client.post("/v1/chat", json={"text": "remind me bins", "conversation_id": chat}, headers=AUTH).json()
    reply = body["message_id"]
    client.post("/v1/chat", json={"text": "hello", "conversation_id": chat}, headers=AUTH)
    msgs = client.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"]
    assert [m["id"] for m in msgs if m["text"] == "Added it."] == [reply]

    r = client.post("/v1/feedback", json={"conversation_id": chat, "message_id": reply, "rating": "down",
                                          "note": "it should have asked which day"}, headers=AUTH)
    assert r.json() == {"ok": True, "rating": "down"}
    msgs = client.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"]
    assert [(m["text"], m.get("feedback")) for m in msgs if m["role"] == "assistant"] == [
        ("Added it.", "down"), ("Hi again.", None)]

    (saved,) = FeedbackStore(agent.db.conn).all()
    texts = render(saved)
    assert "remind me bins" in texts and "create_reminder" in texts and "Added it." in texts
    assert "hello" not in texts and "Hi again." not in texts  # only that turn
    assert "note: it should have asked which day" in texts

    client.post("/v1/feedback", json={"conversation_id": chat, "message_id": reply, "rating": "up"}, headers=AUTH)
    (saved,) = FeedbackStore(agent.db.conn).all()
    assert (saved["rating"], saved["note"]) == ("up", "it should have asked which day")  # the note stays
    client.post("/v1/feedback", json={"conversation_id": chat, "message_id": reply, "rating": None}, headers=AUTH)
    assert FeedbackStore(agent.db.conn).all() == []

    user = next(m for m in msgs if m["role"] == "user")
    assert client.post("/v1/feedback", json={"conversation_id": chat, "message_id": user["id"], "rating": "down"},
                       headers=AUTH).status_code == 400
