# Putting your own API in front of this

**Short answer: you do not have to build an inference integration.** This
package ships `TurboFieldfareServer`, an OpenAI-compatible HTTP server. Anything
that can speak HTTP — Go, Node, Python, an existing OpenAI SDK — can drive it as
a normal Chat Completions endpoint.

Everything below was verified on this fork: MacBook Pro M1 Max, macOS 14.8.3.

Upstream's own reference is [`docs/OPENAI_SERVER.md`](docs/OPENAI_SERVER.md).
This document covers the fronting-it case and the operational constraints that
matter when you do.

---

## Start it

```bash
.build/release/TurboFieldfareServer --model scratch/gemma4.gturbo --port 8080
```

Options:

| Flag | Default | Notes |
| --- | --- | --- |
| `--model <dir>` | *required* | A completed `.gturbo` directory |
| `--port <1-65535>` | `8080` | Loopback only |
| `--model-id <id>` | `gemma-4-26b-a4b-it` | The id clients must send |
| `--max-context <tokens>` | `16384` | 4096, 8192, 16384, 32768, or 65536 |
| `--queue-limit <count>` | `4` | Max queued requests |
| `--prompt-cache-mode <off\|single-prefix>` | `single-prefix` | KV reuse for a shared prompt prefix |

It listens on `http://127.0.0.1:<port>/v1`. Startup includes loading the model,
so allow a few seconds before the first request.

## Endpoints

```bash
curl http://127.0.0.1:8080/v1/models
# {"data":[{"id":"gemma-4-26b-a4b-it","owned_by":"turbofieldfare",...}],"object":"list"}

curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-26b-a4b-it",
       "messages":[{"role":"user","content":"Name three primary colors, comma separated only."}],
       "temperature":0,"max_tokens":40}'
```

Returns a standard completion object:

```json
{"object":"chat.completion","model":"gemma-4-26b-a4b-it",
 "choices":[{"index":0,"finish_reason":"stop",
             "message":{"role":"assistant","content":"Red, yellow, blue"}}],
 "usage":{"prompt_tokens":22,"completion_tokens":6,"total_tokens":28,
          "prompt_tokens_details":{"cached_tokens":0}}}
```

## Parameters — what actually works

Verified by sending each one. The server **rejects** unsupported parameters with
a `400` rather than silently ignoring them, so you find out immediately.

| Parameter | Supported | Notes |
| --- | --- | --- |
| `model` | ✅ | Must match `--model-id` exactly, else `model_not_found` |
| `messages` | ✅ | `system`, `user`, `assistant`; multi-turn history works |
| `temperature` | ✅ | `0` for deterministic greedy |
| `top_p` | ✅ | |
| `top_k` | ✅ | Non-standard OpenAI extension |
| `repetition_penalty` | ✅ | Non-standard OpenAI extension |
| `max_tokens` | ✅ | `max_completion_tokens` also accepted |
| `stop` | ✅ | Array of strings |
| `stream` | ✅ | SSE `chat.completion.chunk` deltas |
| `stream_options` | ✅ | |
| `tools` / `tool_choice` | ✅ | Returns `tool_calls`, `finish_reason: "tool_calls"` |
| `presence_penalty` | ⚠️ | Accepted only when `0` |
| `frequency_penalty` | ❌ | `"frequency_penalty must be zero"` |
| `n` | ❌ | `"only n=1 is supported"` |
| `logprobs` | ❌ | `"logprobs are not supported"` |

Errors are OpenAI-shaped:

```json
{"error":{"type":"invalid_request_error","code":"unsupported_value",
          "param":"n","message":"only n=1 is supported"}}
```

### Streaming

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-26b-a4b-it","messages":[{"role":"user","content":"Count 1 to 5."}],
       "max_tokens":30,"stream":true}'
```

```
data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"}}],...}
data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"1"}}],...}
```

### Tool calling

Send OpenAI-style `tools`; the model returns the call and **your** code executes
it. The server never runs anything itself.

```json
{"choices":[{"finish_reason":"tool_calls",
  "message":{"role":"assistant","content":null,
    "tool_calls":[{"id":"call_9f7c...","type":"function",
      "function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]}}]}
```

---

## Constraints that shape your design

Read these before building on top.

1. **Requests are serialized.** One model, one GPU. Three concurrent requests
   completed at +4s, +5s, and +6s — queued, not parallel. Adding concurrency in
   your front end will not increase throughput.
2. **`--queue-limit` defaults to 4.** Beyond that, requests are refused. Do your
   own queueing or backpressure if you expect bursts.
3. **Only one model-owning process at a time.** The server, the CLI, the Mac app,
   and the decode service each want the model and the GPU. Do not run two.
4. **No authentication and no TLS, loopback only.** This is exactly why a front
   end is a good idea — put auth, TLS, rate limiting, and logging in your layer
   and keep the backend on `127.0.0.1`.
5. **Model load happens at startup**, not per request. Keep the process alive;
   do not spawn it per call. (Spawning `TurboFieldfareCLI` per request would
   reload ~14 GB each time — do not do that.)
6. **Memory stays ~2.2 GB** regardless of generation length.

---

## Worked Go example

A small service that adds an API key, injects a fixed system prompt, and
serializes access. Built and run against the live server on this machine.

```go
// Minimal API in front of TurboFieldfareServer.
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"sync"
)

const upstream = "http://127.0.0.1:8080/v1/chat/completions"
const modelID = "gemma-4-26b-a4b-it"

// The backend owns one model on one GPU and serves requests serially,
// so serialize here to control queueing rather than relying on its queue.
var oneAtATime sync.Mutex

type msg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type askReq struct {
	Prompt      string   `json:"prompt"`
	Temperature *float64 `json:"temperature,omitempty"`
	MaxTokens   *int     `json:"max_tokens,omitempty"`
}

type upstreamReq struct {
	Model       string   `json:"model"`
	Messages    []msg    `json:"messages"`
	Temperature *float64 `json:"temperature,omitempty"`
	MaxTokens   *int     `json:"max_tokens,omitempty"`
	Stop        []string `json:"stop,omitempty"`
}

func handleAsk(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-API-Key") != "secret123" {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}
	var in askReq
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, `{"error":"bad json"}`, http.StatusBadRequest)
		return
	}

	body, _ := json.Marshal(upstreamReq{
		Model: modelID,
		Messages: []msg{
			{Role: "system", Content: "You are terse. Answer in one sentence."},
			{Role: "user", Content: in.Prompt},
		},
		Temperature: in.Temperature,
		MaxTokens:   in.MaxTokens,
	})

	oneAtATime.Lock()
	defer oneAtATime.Unlock()

	resp, err := http.Post(upstream, "application/json", bytes.NewReader(body))
	if err != nil {
		http.Error(w, `{"error":"backend unreachable"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)

	var parsed struct {
		Choices []struct {
			Message      msg    `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
		Usage map[string]any `json:"usage"`
		Error map[string]any `json:"error"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil || parsed.Error != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		w.Write(raw)
		return
	}
	if len(parsed.Choices) == 0 {
		http.Error(w, `{"error":"empty response"}`, http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"answer": parsed.Choices[0].Message.Content,
		"finish": parsed.Choices[0].FinishReason,
		"usage":  parsed.Usage,
	})
}

func main() {
	http.HandleFunc("/ask", handleAsk)
	log.Println("listening on :9090")
	log.Fatal(http.ListenAndServe(":9090", nil))
}
```

Run it:

```bash
# terminal 1
.build/release/TurboFieldfareServer --model scratch/gemma4.gturbo --port 8080

# terminal 2
go mod init myapi && go build -o myapi . && ./myapi
```

Verified output:

```bash
$ curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:9090/ask -d '{"prompt":"hi"}'
401

$ curl -s -X POST localhost:9090/ask -H 'X-API-Key: secret123' \
    -d '{"prompt":"What is the tallest mountain on Earth?","temperature":0,"max_tokens":40}'
{"answer":"Mount Everest is the tallest mountain on Earth above sea level.",
 "finish":"stop","usage":{"prompt_tokens":35,"completion_tokens":13,"total_tokens":48}}
```

### Using an OpenAI SDK instead

Because the API is OpenAI-shaped, existing clients work by pointing the base URL
at the server and passing any non-empty API key:

```go
// github.com/openai/openai-go
client := openai.NewClient(
    option.WithBaseURL("http://127.0.0.1:8080/v1"),
    option.WithAPIKey("unused"),
)
```

Same idea in Python: `OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="unused")`.
This is the fastest path if you want streaming and tool calling without writing
the plumbing yourself — but remember the unsupported parameters above, and that
SDK defaults sometimes set `frequency_penalty`, which will be rejected.
