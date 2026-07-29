# Serving this over HTTP

## The whole thing, if you are in a hurry

```bash
.build/release/TurboFieldfareServer \
  --model scratch/gemma4.gturbo --port 8080 --queue-limit 32
```

Leave it running. Point anything at `http://127.0.0.1:8080/v1`. It speaks the
OpenAI Chat Completions API, so existing SDKs and tools work unchanged.

**You do not need to write any program to sit in front of this.** You do not
need to manage queueing. Requests that arrive during a generation wait their turn
and return normally.

### Client applications cost you nothing

To be explicit, because it is easy to get the wrong impression:

- **One server process holds the model.** ~1.5 GB, once.
- **Any number of client applications can use it concurrently.** A client is
  anything sending HTTP — your scripts, a chat UI, an editor plugin, `curl`.
  Clients do not load the model and add **no** memory.
- Ten apps hitting one server still means one ~1.5 GB server.

The only way to end up with two copies of the model in RAM is to run two
programs that each *load* it — the server, the CLI, and the Mac app each do.
Running the server and the CLI simultaneously would do that. Running the server
and ten client apps would not.

---

Everything below is detail: the API surface, measured memory, LAN access, and an
optional example of wrapping it in your own service.

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

## Queueing and memory — the important part

**The server already queues requests for you.** Nothing is lost and nothing runs
in parallel. A request that arrives while another is generating simply waits and
then returns normally. You do not need to build a queue.

This is also what protects the memory budget: because only one generation ever
runs at a time, a queued request costs a pending HTTP connection and nothing
more. It does **not** load a second copy of the model.

Measured on this machine, all figures process RSS:

| State | Memory |
| --- | --- |
| Idle, model resident | 1.08 GB |
| 5 requests in flight (1 running, 4 queued) | 1.41 GB peak |
| 8 requests in flight, `--queue-limit 32` | 1.46 GB peak |

Queue depth barely moves memory — 5 in flight and 8 in flight differ by 50 MB.
Generation length does not move it either; a 700-token completion peaks at the
same ~2.2 GB footprint as an 8-token one.

Timing confirms serialization rather than parallelism: three concurrent requests
completed at +4s, +5s, and +6s — one after another.

### Raise `--queue-limit` so nothing is ever refused

The default is `4`, and the limit is real. Firing 6 concurrent requests at a
default server gives five `200`s and one:

```json
{"error":{"type":"invalid_request_error","code":"queue_full",
          "message":"generation queue is full"}}
```

returned as **HTTP 429**. With `--queue-limit 32`, eight concurrent requests all
returned `200` with zero refusals:

```bash
.build/release/TurboFieldfareServer \
  --model scratch/gemma4.gturbo --port 8080 --queue-limit 32
```

For single-user LAN use where waiting is fine, raise it. It costs almost nothing
in memory and converts a refusal into a wait.

Two things to set on the client side, since waits are long by HTTP standards:

- **Generous client timeouts.** A queued request behind several others can take
  minutes. Go's `http.Client` has no default timeout, which is actually what you
  want here; if you set one, set it high.
- **Consider `stream: true`** for interactive use. Tokens arrive as they are
  produced, so the connection is not silent while you wait.

## Reaching it from other machines on your LAN

This is the one thing that genuinely does not work out of the box. The bind
address is hardcoded and there is no flag for it:

```swift
// Sources/TurboFieldfareServer/Core/HTTPServer.swift
let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
```

`127.0.0.1` means **only this Mac can connect.** Apps on the same machine work
fine; a phone or laptop elsewhere on the network cannot reach it at all.

Upstream did this deliberately, because the server has no authentication and no
TLS. Anything that can reach the port can use the model.

Three ways to get LAN access, cheapest first:

1. **SSH tunnel from the client machine** — no code changes, and stays
   authenticated:
   ```bash
   ssh -N -L 8080:127.0.0.1:8080 you@this-mac.local
   # then use http://127.0.0.1:8080/v1 on the client
   ```
2. **A reverse proxy** on this Mac listening on the LAN and forwarding to
   loopback. Put a password or mTLS on the proxy. Caddy or nginx in ~5 lines.
3. **Patch the bind address in this fork.** Small change, and it is your fork.
   Prefer adding a `--host` flag that still defaults to `127.0.0.1` over
   hardcoding `0.0.0.0`, so exposure is always explicit and opt-in.

Whichever you pick, remember there is no auth. On a trusted home network that
may be fine; do not put it on a network you do not control.

## Other notes

1. **Model load happens at startup**, not per request. Keep the process alive; do
   not spawn it per call. Spawning `TurboFieldfareCLI` per request would reload
   ~14 GB every time.
2. **Adding concurrency in your own code will not increase throughput**, because
   the backend serializes regardless. It only changes where requests wait.
3. **Do not run the server and the CLI or Mac app at the same time.** Each loads
   its own copy of the model. This is the only realistic way to exceed the memory
   budget.

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

// The backend already queues and never runs two generations at once, so this
// mutex is not required for correctness or for memory safety. It is here so
// requests wait in this process instead of occupying a backend queue slot,
// which means you can never hit the backend's queue_full 429 no matter how
// many callers show up. Drop it if you would rather let the backend queue,
// and raise --queue-limit instead.
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
.build/release/TurboFieldfareServer \
  --model scratch/gemma4.gturbo --port 8080 --queue-limit 32

# terminal 2
go mod init myapi && go build -o myapi . && ./myapi
```

Because the mutex above serializes in-process, every caller waits its turn and
returns normally — no request is ever dropped and no `429` is possible. On a LAN
where a 30–60 second wait is acceptable, that is usually the behaviour you want.
`http.Client` has no default timeout, so waits are not cut short.

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
