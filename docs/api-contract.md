# PocketBridge API

The iPhone stores audio and notes locally. The service has its own credentials.
The service must not use Pocket accounts or Pocket cloud APIs.

All `/v1` requests require `Authorization: Bearer <BACKEND_TOKEN>`.
`GET /health` returns service readiness without secrets.
`GET /v1/status` returns the same readiness data after it checks the access token.

## Upload and process

`POST /v1/recordings` accepts multipart `file` and optional `title` and `language`.
Returns HTTP 202: `{"id":"uuid","status":"queued"}`.
An optional `X-Idempotency-Key` UUID sets the job identifier. Repeating an
accepted upload returns its existing job. The iPhone uses its local recording
identifier so a lost upload response does not create another speech job.

`GET /v1/recordings/{id}` returns:

```json
{
  "id": "uuid",
  "status": "queued|processing|complete|failed",
  "title": "Meeting",
  "duration": 12.5,
  "language": "en",
  "segments": [
    {"id": "0", "speaker": "Speaker 1", "start": 0.0, "end": 2.1, "text": "Hello."}
  ],
  "summary": "Summary text",
  "actions": [{"id":"0","text":"Send the draft","owner":"Speaker 1"}],
  "error": null
}
```

`POST /v1/recordings/{id}/retry` retries a failed job.
`DELETE /v1/recordings/{id}` removes service audio and results.

## Notes and questions

`POST /v1/summarize` accepts `{"segments":[...],"template":"meeting|lecture|journal|general"}`.
Returns `{"title":"...","summary":"...","actions":[...]}`.

`POST /v1/chat` accepts `{"segments":[...],"question":"..."}`.
Returns `{"answer":"..."}`. Answers must use the supplied transcript.

## Provider choice

Use a speech provider that returns speaker labels and timestamps. Deepgram is
the first adapter. Use OpenRouter for summaries and transcript questions.
Provider keys stay on the service. Return clear configuration errors if keys
are missing. Never return invented transcript or speaker data as a fallback.
