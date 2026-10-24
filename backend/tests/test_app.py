import json
import sqlite3
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from urllib.parse import parse_qs

import httpx
from fastapi.testclient import TestClient

from app import Settings, Store, create_app


AUDIO = b"\x00\x00\x00\x18ftypM4A " + b"fake-audio"
AUTH = {"Authorization": "Bearer test-backend-token"}
SEGMENT = {"id": "0", "speaker": "Speaker 1", "start": 0.2, "end": 1.5, "text": "Hello there."}


def settings(data_dir, **updates):
    values = {
        "data_dir": Path(data_dir),
        "backend_token": "test-backend-token",
        "deepgram_api_key": "test-deepgram-key",
        "openrouter_api_key": "test-openrouter-key",
    }
    values.update(updates)
    return Settings(**values)


def wait_for_status(client, recording_id, expected):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        response = client.get("/v1/recordings/" + recording_id, headers=AUTH)
        if response.status_code == 200 and response.json()["status"] == expected:
            return response.json()
        time.sleep(0.01)
    raise AssertionError("Recording did not reach status %r" % expected)


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_repeated_upload_returns_existing_job(self):
        config = settings(self.temp_dir.name, deepgram_api_key=None)
        recording_id = str(uuid.uuid4())
        headers = {**AUTH, "X-Idempotency-Key": recording_id}
        with TestClient(create_app(config)) as client:
            uploaded = client.post("/v1/recordings", headers=headers,
                files={"file": ("audio.m4a", AUDIO, "audio/mp4")})
            self.assertEqual(uploaded.status_code, 202)
            self.assertEqual(uploaded.json()["id"], recording_id)
            wait_for_status(client, recording_id, "failed")
            repeated = client.post("/v1/recordings", headers=headers,
                files={"file": ("audio.m4a", AUDIO, "audio/mp4")})
            self.assertEqual(repeated.status_code, 202)
            self.assertEqual(repeated.json(), {"id": recording_id, "status": "failed"})
            self.assertEqual(len(list((Path(self.temp_dir.name) / "audio").iterdir())), 1)
            invalid = client.post("/v1/recordings", headers={**AUTH, "X-Idempotency-Key": "../bad"})
            self.assertEqual(invalid.status_code, 422)

    def test_auth_and_health_hide_credentials(self):
        app = create_app(settings(self.temp_dir.name))
        with TestClient(app) as client:
            health = client.get("/health")
            self.assertEqual(health.status_code, 200)
            self.assertEqual(health.json(), {"status": "ok", "ready": True, "missing_config": []})
            self.assertEqual(client.get("/v1/status").status_code, 401)
            status = client.get("/v1/status", headers=AUTH)
            self.assertEqual(status.status_code, 200)
            self.assertEqual(status.json(), health.json())
            self.assertEqual(client.get("/v1/recordings/missing").status_code, 401)
            self.assertEqual(client.get("/v1/recordings/missing", headers={"Authorization": "Bearer wrong"}).status_code, 401)
            self.assertEqual(client.get("/v1/recordings/missing", headers=AUTH).status_code, 404)

        missing = settings(self.temp_dir.name, backend_token=None, deepgram_api_key=None, openrouter_api_key=None)
        with TestClient(create_app(missing)) as client:
            health_response = client.get("/health")
            health = health_response.json()
            self.assertEqual(health_response.status_code, 503)
            self.assertFalse(health["ready"])
            self.assertEqual(set(health["missing_config"]), {"BACKEND_TOKEN", "DEEPGRAM_API_KEY", "OPENROUTER_API_KEY"})
            self.assertNotIn("test-deepgram-key", json.dumps(health))
            self.assertEqual(client.get("/v1/recordings/missing").status_code, 503)

        missing_providers = settings(self.temp_dir.name, deepgram_api_key=None, openrouter_api_key=None)
        with TestClient(create_app(missing_providers)) as client:
            health = client.get("/health")
            status = client.get("/v1/status", headers=AUTH)
            self.assertEqual(health.status_code, 503)
            self.assertEqual(status.status_code, 503)
            self.assertEqual(status.json(), health.json())

    def test_provider_urls_allow_http_only_for_loopback(self):
        for url in ("http://localhost:8001", "http://127.0.0.2:8001", "http://[::1]:8001"):
            with self.subTest(url=url):
                config = settings(self.temp_dir.name, deepgram_base_url=url)
                self.assertEqual(config.deepgram_base_url, url)
        with self.assertRaisesRegex(ValueError, "must use HTTPS"):
            settings(self.temp_dir.name, deepgram_base_url="http://deepgram.test")

    def test_upload_size_limit_and_audio_validation(self):
        app = create_app(settings(self.temp_dir.name, max_upload_bytes=32))
        with TestClient(app) as client:
            oversized = client.post(
                "/v1/recordings", headers=AUTH,
                files={"file": ("too-big.m4a", AUDIO + b"x" * 64, "audio/mp4")},
            )
            self.assertEqual(oversized.status_code, 413)
            unsupported = client.post(
                "/v1/recordings", headers=AUTH,
                files={"file": ("notes.txt", b"not audio", "text/plain")},
            )
            self.assertEqual(unsupported.status_code, 415)
            duplicate_files = client.post(
                "/v1/recordings", headers=AUTH,
                files=[("file", ("one.m4a", AUDIO, "audio/mp4")), ("file", ("two.m4a", AUDIO, "audio/mp4"))],
            )
            self.assertEqual(duplicate_files.status_code, 400)
            oversized_request = client.post(
                "/v1/recordings", headers=AUTH,
                files={"file": ("too-big.m4a", AUDIO + b"x" * 66000, "audio/mp4")},
            )
            self.assertEqual(oversized_request.status_code, 413)
            self.assertEqual(oversized_request.json()["detail"], "Request body is too large.")
        self.assertEqual(list((Path(self.temp_dir.name) / "audio").iterdir()), [])

    def test_processing_job_recovers_after_restart(self):
        store = Store(Path(self.temp_dir.name))
        store.initialize()
        recording_id = str(uuid.uuid4())
        (store.audio_dir / (recording_id + ".audio")).write_bytes(AUDIO)
        store.add(recording_id, "Recovered", "en", "audio/mp4")
        self.assertEqual(store.claim_next()["status"], "processing")

        config = settings(self.temp_dir.name, deepgram_api_key=None, openrouter_api_key=None)
        with TestClient(create_app(config)) as client:
            recovered = wait_for_status(client, recording_id, "failed")
            self.assertEqual(recovered["error"], "DEEPGRAM_API_KEY is not configured.")

    def test_legacy_database_migrates_speech_checkpoint(self):
        data_dir = Path(self.temp_dir.name)
        data_dir.mkdir(exist_ok=True)
        database = data_dir / "recordings.sqlite3"
        with sqlite3.connect(database) as connection:
            connection.execute(
                """CREATE TABLE recordings (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL CHECK(status IN ('queued', 'processing', 'complete', 'failed')),
                    title TEXT,
                    language TEXT NOT NULL,
                    audio_type TEXT NOT NULL,
                    duration REAL,
                    segments_json TEXT NOT NULL DEFAULT '[]',
                    summary TEXT,
                    actions_json TEXT NOT NULL DEFAULT '[]',
                    error TEXT,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )"""
            )
            connection.execute(
                "INSERT INTO recordings (id, status, language, audio_type, duration) VALUES (?, 'failed', 'en', 'audio/mp4', 12.5)",
                ("old-recording",),
            )
        store = Store(data_dir)
        store.initialize()
        migrated = store.get("old-recording")
        self.assertEqual(migrated["speech_complete"], 1)
        store.add("new-recording", None, "en", "audio/mp4")
        self.assertEqual(store.get("new-recording")["speech_complete"], 0)

    def test_retry_reuses_transcript_when_summary_fails(self):
        calls = {"deepgram": 0, "openrouter": 0}

        def provider(request):
            if request.url.path == "/v1/listen":
                calls["deepgram"] += 1
                return httpx.Response(200, json={
                    "metadata": {"duration": 12.5},
                    "results": {
                        "channels": [{"alternatives": [{"transcript": "Hello there."}]}],
                        "utterances": [{"start": 0.2, "end": 1.5, "speaker": 0, "transcript": "Hello there."}],
                    },
                })
            calls["openrouter"] += 1
            if calls["openrouter"] == 1:
                return httpx.Response(429)
            return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps({
                "title": "Meeting", "summary": "A short greeting.", "actions": [],
            })}}]})

        config = settings(
            self.temp_dir.name,
            deepgram_base_url="http://127.0.0.1:8001",
            openrouter_base_url="http://[::1]:8001/api/v1",
        )
        with TestClient(create_app(config, httpx.MockTransport(provider))) as client:
            uploaded = client.post("/v1/recordings", headers=AUTH, files={"file": ("voice.m4a", AUDIO, "audio/mp4")})
            recording_id = uploaded.json()["id"]
            failed = wait_for_status(client, recording_id, "failed")
            self.assertEqual(failed["duration"], 12.5)
            self.assertEqual(failed["segments"], [SEGMENT])
            self.assertEqual(failed["error"], "OpenRouter request failed (HTTP 429).")
            self.assertEqual(calls, {"deepgram": 1, "openrouter": 1})

            retried = client.post("/v1/recordings/%s/retry" % recording_id, headers=AUTH)
            self.assertEqual(retried.status_code, 202)
            complete = wait_for_status(client, recording_id, "complete")
            self.assertEqual(complete["segments"], [SEGMENT])
            self.assertEqual(complete["summary"], "A short greeting.")
            self.assertEqual(calls, {"deepgram": 1, "openrouter": 2})

    def test_empty_speech_checkpoint_survives_restart(self):
        store = Store(Path(self.temp_dir.name))
        store.initialize()
        recording_id = str(uuid.uuid4())
        (store.audio_dir / (recording_id + ".audio")).write_bytes(AUDIO)
        store.add(recording_id, "Silence", "en", "audio/mp4")
        self.assertEqual(store.claim_next()["status"], "processing")
        self.assertTrue(store.checkpoint_speech(recording_id, 4.0, []))
        calls = {"deepgram": 0, "openrouter": 0}

        def provider(request):
            calls["deepgram" if request.url.path == "/v1/listen" else "openrouter"] += 1
            raise AssertionError("A saved empty speech result must skip both providers.")

        config = settings(self.temp_dir.name)
        with TestClient(create_app(config, httpx.MockTransport(provider))) as client:
            recovered = wait_for_status(client, recording_id, "complete")
            self.assertEqual(recovered["duration"], 4.0)
            self.assertEqual(recovered["segments"], [])
            self.assertEqual(recovered["summary"], "")
            self.assertEqual(calls, {"deepgram": 0, "openrouter": 0})

    def test_provider_parsing_retry_persistence_and_delete(self):
        calls = {"deepgram": 0, "openrouter": 0}

        def provider(request):
            if request.url.host == "deepgram.test":
                calls["deepgram"] += 1
                query = parse_qs(request.url.query.decode())
                self.assertEqual(query["utterances"], ["true"])
                self.assertEqual(query["diarize"], ["true"])
                self.assertEqual(query["model"], ["nova-3"])
                self.assertEqual(query["language"], ["en"])
                self.assertEqual(request.headers["authorization"], "Token test-deepgram-key")
                self.assertEqual(request.content, AUDIO)
                if calls["deepgram"] == 1:
                    return httpx.Response(500, text="provider body must not reach the user")
                return httpx.Response(200, json={
                    "metadata": {"duration": 12.5},
                    "results": {
                        "channels": [{"alternatives": [{"transcript": "Hello there."}]}],
                        "utterances": [{"start": 0.2, "end": 1.5, "speaker": 0, "transcript": "Hello there."}],
                    },
                })
            calls["openrouter"] += 1
            self.assertEqual(request.url.path, "/api/v1/chat/completions")
            self.assertEqual(request.headers["authorization"], "Bearer test-openrouter-key")
            payload = json.loads(request.content)
            self.assertEqual(payload["model"], "openai/gpt-4o-mini")
            self.assertIn("Hello there.", payload["messages"][1]["content"])
            return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps({
                "title": "Meeting", "summary": "A short greeting.",
                "actions": [{"text": "Send the draft", "owner": "Speaker 1"}],
            })}}]})

        transport = httpx.MockTransport(provider)
        config = settings(
            self.temp_dir.name,
            deepgram_base_url="https://deepgram.test",
            openrouter_base_url="https://openrouter.test/api/v1",
        )
        with TestClient(create_app(config, transport)) as client:
            uploaded = client.post(
                "/v1/recordings", headers=AUTH,
                files={"file": ("a user supplied name.m4a", AUDIO, "audio/mp4")},
            )
            self.assertEqual(uploaded.status_code, 202)
            recording_id = uploaded.json()["id"]
            failed = wait_for_status(client, recording_id, "failed")
            self.assertEqual(failed["error"], "Deepgram request failed (HTTP 500).")
            self.assertNotIn("provider body", failed["error"])
            audio_path = Path(self.temp_dir.name) / "audio" / (recording_id + ".audio")
            self.assertTrue(audio_path.is_file())
            self.assertEqual([path.name for path in audio_path.parent.iterdir()], [recording_id + ".audio"])

            retried = client.post("/v1/recordings/%s/retry" % recording_id, headers=AUTH)
            self.assertEqual(retried.status_code, 202)
            complete = wait_for_status(client, recording_id, "complete")
            self.assertEqual(complete["duration"], 12.5)
            self.assertEqual(complete["segments"], [SEGMENT])
            self.assertEqual(complete["summary"], "A short greeting.")
            self.assertEqual(complete["actions"], [{"id": "0", "text": "Send the draft", "owner": "Speaker 1"}])
            self.assertEqual(calls, {"deepgram": 2, "openrouter": 1})

        with TestClient(create_app(config, transport)) as restarted:
            persisted = restarted.get("/v1/recordings/" + recording_id, headers=AUTH)
            self.assertEqual(persisted.status_code, 200)
            self.assertEqual(persisted.json()["summary"], "A short greeting.")
            deleted = restarted.delete("/v1/recordings/" + recording_id, headers=AUTH)
            self.assertEqual(deleted.status_code, 204)
            self.assertFalse(audio_path.exists())
            self.assertEqual(restarted.get("/v1/recordings/" + recording_id, headers=AUTH).status_code, 404)

    def test_summary_chat_parsing_and_missing_provider_key(self):
        def provider(request):
            payload = json.loads(request.content)
            if "Template: meeting" in payload["messages"][1]["content"]:
                content = '{"title":"Planning","summary":"The team chose a date.","actions":[]}'
            else:
                content = "The transcript says Friday."
            return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

        app = create_app(settings(self.temp_dir.name), httpx.MockTransport(provider))
        with TestClient(app) as client:
            summarized = client.post("/v1/summarize", headers=AUTH, json={"segments": [SEGMENT], "template": "meeting"})
            self.assertEqual(summarized.status_code, 200)
            self.assertEqual(summarized.json(), {"title": "Planning", "summary": "The team chose a date.", "actions": []})
            answer = client.post("/v1/chat", headers=AUTH, json={"segments": [SEGMENT], "question": "When?"})
            self.assertEqual(answer.status_code, 200)
            self.assertEqual(answer.json(), {"answer": "The transcript says Friday."})
            oversized = [
                {**SEGMENT, "id": str(index), "text": "x" * 9000}
                for index in range(2)
            ]
            rejected = client.post("/v1/chat", headers=AUTH, json={"segments": oversized, "question": "When?"})
            self.assertEqual(rejected.status_code, 413)
            self.assertIn("16 KiB chat context limit", rejected.json()["detail"])

        no_key = settings(self.temp_dir.name, openrouter_api_key=None)
        with TestClient(create_app(no_key)) as client:
            response = client.post("/v1/chat", headers=AUTH, json={"segments": [SEGMENT], "question": "When?"})
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.json()["detail"], "OPENROUTER_API_KEY is not configured.")

    def test_large_transcript_summary_uses_bounded_chunks_and_reduction(self):
        calls = {"chunks": 0, "reductions": 0, "final": 0}

        def provider(request):
            messages = json.loads(request.content)["messages"]
            system = messages[0]["content"]
            user = messages[1]["content"]
            self.assertLessEqual(len(user.encode("utf-8")), 16 * 1024 + 100)
            if system.startswith("Write concise"):
                calls["chunks"] += 1
                return httpx.Response(200, json={"choices": [{"message": {"content": "Fact %d " % calls["chunks"] + "x" * 2400}}]})
            if system.startswith("Combine transcript notes"):
                calls["reductions"] += 1
                return httpx.Response(200, json={"choices": [{"message": {"content": "Reduced facts " + "x" * 2400}}]})
            calls["final"] += 1
            return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps({
                "title": "Long meeting", "summary": "The transcript was summarized in full chunks.", "actions": [],
            })}}]})

        config = settings(self.temp_dir.name, openrouter_base_url="https://openrouter.test/api/v1")
        segments = [
            {**SEGMENT, "id": str(index), "start": float(index), "end": float(index + 1), "text": "x" * 9000}
            for index in range(40)
        ]
        with TestClient(create_app(config, httpx.MockTransport(provider))) as client:
            response = client.post(
                "/v1/summarize", headers=AUTH,
                json={"segments": segments, "template": "meeting"},
            )
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["title"], "Long meeting")
        self.assertGreater(calls["chunks"], 1)
        self.assertGreater(calls["reductions"], 0)
        self.assertEqual(calls["final"], 1)


if __name__ == "__main__":
    unittest.main()
