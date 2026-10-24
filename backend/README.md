# PocketBridge backend

This service accepts audio from the iPhone app. It stores audio and results in SQLite and on disk. It sends audio to Deepgram and transcript text to OpenRouter. It does not use Pocket accounts or Pocket APIs.

## Run locally

Use Python 3.11 or newer. From this directory, run:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Set `BACKEND_TOKEN`, `DEEPGRAM_API_KEY`, and `OPENROUTER_API_KEY` in `.env`. These values are service credentials. Keep `.env` private. Load the file, then start the server on localhost:

```sh
set -a
. ./.env
set +a
uvicorn app:app --host 127.0.0.1 --port 8000
```

`GET /health` is public. It reports missing setting names but never returns key values. It returns 503 until all three keys are set. `GET /v1/status` returns the same readiness data and requires `Authorization: Bearer $BACKEND_TOKEN`, like every other `/v1` route. Without provider keys, provider calls return a clear configuration error and recording jobs fail with that error. The service does not use sample transcripts or provider fallbacks.

The default upload limit is 100 MiB. The service checks request size, streams file data to disk, checks audio signatures, and names files with local UUIDs. Set `MAX_UPLOAD_BYTES` to change the limit. SQLite and audio files live under `DATA_DIR`. Run one Uvicorn process for each data directory.

## Settings

| Setting               | Default                        | Use                                                               |
| --------------------- | ------------------------------ | ----------------------------------------------------------------- |
| `DATA_DIR`            | `./data`                       | SQLite database and audio files                                   |
| `BACKEND_TOKEN`       | unset                          | Bearer token for `/v1`                                            |
| `DEEPGRAM_API_KEY`    | unset                          | Deepgram service key                                              |
| `OPENROUTER_API_KEY`  | unset                          | OpenRouter service key                                            |
| `DEEPGRAM_BASE_URL`   | `https://api.deepgram.com`     | Deepgram API or compatible proxy; use HTTPS except for loopback   |
| `OPENROUTER_BASE_URL` | `https://openrouter.ai/api/v1` | OpenRouter API or compatible proxy; use HTTPS except for loopback |
| `DEEPGRAM_MODEL`      | `nova-3`                       | Speech model                                                      |
| `OPENROUTER_MODEL`    | `openai/gpt-4o-mini`           | Summary and chat model                                            |
| `DEFAULT_LANGUAGE`    | `en`                           | Language for uploaded recordings                                  |
| `MAX_UPLOAD_BYTES`    | `104857600`                    | Maximum audio size in bytes                                       |

## API

The routes follow [`../docs/api-contract.md`](../docs/api-contract.md). Upload one multipart `file`; `title` and `language` are optional. Jobs run one at a time. On restart, jobs left in `processing` return to `queued`. Failed jobs can be retried. Deleting a recording removes its database row and audio file, and cancels an active provider request.

The service saves the Deepgram duration and transcript before it asks OpenRouter for a summary. A retry or restart reuses that saved speech result, including an empty result. If the process stops before Deepgram returns and the service saves its result, it can repeat the speech request. A stop after OpenRouter replies but before the job completes can repeat the summary request.

Summary requests send the transcript in chronological chunks with at most 16 KiB of serialized transcript evidence per OpenRouter call. The service reduces chunk notes before it asks for the final summary, so long transcripts use more provider calls. Chat accepts up to 16 KiB of serialized transcript evidence and returns HTTP 413 above that limit. It does not trim the transcript.

## Provider request formats

Deepgram's [pre-recorded audio guide](https://developers.deepgram.com/docs/pre-recorded-audio), [diarization guide](https://developers.deepgram.com/docs/diarization), and [utterances guide](https://developers.deepgram.com/docs/utterances) document `POST /v1/listen`, `Authorization: Token`, and the `utterances=true` and `diarize=true` options.

OpenRouter's [chat completions API](https://openrouter.ai/docs/api-reference/overview) documents `POST /api/v1/chat/completions`, bearer authentication, and the `choices[].message` response.
