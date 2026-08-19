# Gorelo MCP server

Lets an AI assistant read your Gorelo PSA — your ticket backlog, clients, contacts and
managed devices — by talking to the Gorelo API on your behalf.

It runs on your own machine and speaks [MCP](https://modelcontextprotocol.io) over
stdin/stdout. Nothing is hosted, nothing is exposed to the internet, and your API key never
leaves your computer.

**Eight tools, seven of them read-only.** Plain Ruby — **no gems, no Bundler, no build step.**

---

## Install

Pick whichever you already have. Both are equally supported.

<details open>
<summary><b>Linux, macOS, or Windows with WSL</b></summary>

```bash
# Ruby (skip if `ruby -v` already works)
sudo apt update && sudo apt install -y ruby      # Debian/Ubuntu
# brew install ruby                              # macOS

git clone <this-repo> ~/gorelo-mcp     # or just copy the folder there
cd ~/gorelo-mcp
cp .env.example .env && nano .env      # fill in your API key
```

Check it starts and answers:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  | ruby gorelo-mcp-server.rb
```

You want a JSON line containing `"serverInfo"`, plus two `[gorelo-mcp]` lines on stderr.

Then add it to your MCP client's config. For Claude Desktop that is
`%APPDATA%\Claude\claude_desktop_config.json` on Windows, or
`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS:

```json
{
  "mcpServers": {
    "gorelo": {
      "command": "wsl.exe",
      "args": ["-d", "Ubuntu", "-e", "/usr/bin/ruby",
               "/home/YOURNAME/gorelo-mcp/gorelo-mcp-server.rb"]
    }
  }
}
```

On Linux or macOS, drop the `wsl.exe` wrapper:

```json
{
  "mcpServers": {
    "gorelo": {
      "command": "/usr/bin/ruby",
      "args": ["/home/YOURNAME/gorelo-mcp/gorelo-mcp-server.rb"]
    }
  }
}
```

**Two things bite under WSL.** Use the **absolute** path to Ruby — `wsl -e` doesn't run a
login shell, so it won't have your full `PATH`. And keep the project **inside** the WSL
filesystem (`~/gorelo-mcp`), not under `/mnt/c`, which is slow and unreliable with
cloud-synced folders.

</details>

<details>
<summary><b>Windows, natively</b></summary>

Install Ruby from [rubyinstaller.org](https://rubyinstaller.org/). There are no gems to
install, so you don't need the DevKit.

```powershell
Copy-Item .env.example .env
notepad .env                     # fill in your API key
(Get-Command ruby).Source        # note this path for the config below
```

Check it starts:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' `
  | ruby gorelo-mcp-server.rb
```

Then in `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "gorelo": {
      "command": "C:\\Ruby34-x64\\bin\\ruby.exe",
      "args": ["C:\\path\\to\\gorelo-mcp\\gorelo-mcp-server.rb"]
    }
  }
}
```

Use the **full path** to `ruby.exe` — the client does not inherit your `PATH` — and
**double every backslash**, since JSON treats a single one as an escape.

</details>

Restart your MCP client. Then ask it something like *"list my open Gorelo tickets"* or
*"what have I got assigned that hasn't been touched in 90 days?"*

### Configuration

| Variable | |
|---|---|
| `GORELO_API_KEY` | **Required.** Make it read-only to start with — only one tool writes. |
| `GORELO_MY_EMAIL` | **Required** for `assignee: "me"`. Must match your Gorelo user exactly. |
| `GORELO_BASE_URL` | Defaults to `https://api.aue.gorelo.io`. Change for other regions. |
| `GORELO_ALLOW_WRITES` | `true` enables the single write tool. Off by default. |

---

## The tools

| Tool | Writes | |
|---|---|---|
| `gorelo_list_tickets` | | The backlog view — assignee, client, status, title, staleness |
| `gorelo_get_ticket` | | One ticket in full, with its conversation |
| `gorelo_search_clients` | | Find a client by name fragment or id |
| `gorelo_get_client` | | One client's whole footprint: tickets, contacts, devices |
| `gorelo_get_contact` | | Find a person by name or email across all clients |
| `gorelo_list_assets` | | Managed devices, filterable by client or last-seen age |
| `gorelo_add_ticket_comment` | **yes** | The only write. Off by default. |
| `gorelo_api_probe` | | Raw `GET` on any `/v1/…` path, for exploring |

### The write tool

Four guards sit in front of `gorelo_add_ticket_comment`:

1. **Disabled** unless `GORELO_ALLOW_WRITES=true`
2. **`confirm: true` required** on every call
3. **Defaults to an internal note** — `visibility: "client"` has to be asked for, because it
   may email the client
4. **Identical comments within 24 hours are refused.** MCP has no transport-level
   idempotency, so a retried call could otherwise post twice. A fingerprint log at
   `~/.gorelo-mcp-writes.jsonl` prevents it.

Leave it off until the read tools have earned their place.

---

## Three things it does differently, and why

**Status is judged on `BaseStatusId`, never on the status name.** Gorelo files custom statuses
under one of five bases, and instances commonly put *"Billing"* or *"Standing Ticket"* under
the **solved** base. Those are real outstanding work. A server-side status filter silently
drops them, so filtering happens locally. Ask for `status: "open"` to get everything that
isn't genuinely closed.

**"Merged" is a status, not the `IsMerged` flag.** `IsMerged` is `false` even on merged
tickets; they carry status id 5. Filtering on the flag leaves merged duplicates sitting in
your backlog looking like live work. They're excluded, and the exclusion is stated.

**Nothing is dropped silently.** Every list states the full unfiltered count first, names what
it excluded, and warns when a ticket carries a status the API didn't return from
`/v1/tickets/statuses` — an unfamiliar status can never quietly remove work from your view.

---

## What the API can and can't do

Confirmed working:

```
/v1/tickets                       GET, POST
/v1/tickets/{id}                  GET
/v1/tickets/{id}/comments         GET, POST   (oldest-first; ConversationType filter)
/v1/tickets/{id}/comments/{id}    GET
/v1/tickets/{id}/conversations    GET
/v1/tickets/{id}/attachments      POST
/v1/tickets/statuses | /tags | /types
/v1/clients
/v1/contacts                      ClientId is SINGULAR here
/v1/assets/agents                 no client filter
/v1/organization/users
```

**Gorelo publishes a full OpenAPI spec** — read it before guessing at parameter names:

- Swagger UI: `https://api.aue.gorelo.io/swagger` (AU) · `https://api.usw.gorelo.io/swagger` (US)
- Spec JSON: append `/v1/swagger.json`
- Docs index built for LLMs: [help.gorelo.io/llms.txt](https://help.gorelo.io/llms.txt)

`GET /v1/tickets` documents: `Query`, `StatusIds`, `ClientIds`, `PriorityIds`, `TypeIds`,
`LeadAssigneeIds`, `ContactIds`, `TagIds`, `GroupIds`, `UpdatedSince`, `UpdatedBefore`,
`CreatedSince`, `CreatedBefore`, `SortBy`, `SortOrder`, `PageSize`, `Cursor`.

⚠️ **Unknown query parameters are ignored, not rejected.** A misspelled or invented filter
returns HTTP 200 and the full unfiltered set, which looks exactly like a working call. Check
the spec rather than trying names.

Three consequences worth knowing:

**There is no assisting-assignee filter.** `LeadAssigneeIds` is the only assignment filter in
the spec; `AssistingAssigneeIds` and `WatcherIds` are response fields only. Gorelo's own UI
counts you as lead *or* assisting, so this server sweeps the organisation's unclosed tickets to
match — usually one page, one request. Pass `include_assisting: false` to skip it.

**`Query` searches title, number and display number** (200 characters max), which is how a
ticket number is resolved to the GUID that `/v1/tickets/{id}` needs.

**Deleted comments are still returned by the API**, with their body intact. The comment schema
contains no deletion, removal or visibility property at all, so a consumer cannot tell — while
the web UI correctly shows *"This comment has been deleted"*. Reported to Gorelo. This server
withholds the body of any comment carrying a deletion flag, so it will do the right thing if
one ever appears; until then, **treat comment history as potentially including retracted
content**, and never rely on deleting a comment to remove sensitive data.

### Two tricks worth stealing

`DataContext.Pagination.TotalCount` comes back on every query, so **counting anything costs
one request** with `PageSize=1`.

The pagination cursor base64-decodes to JSON containing a **`FilterHash`**. If a query's hash
matches the unfiltered query's hash, the parameter you passed was ignored. That is how the
list above was established, in a handful of calls rather than by guessing.

### `StatusReason` is the most useful field in the API

It's stored as JSON, not text:

```json
{"reason":"waiting on the replacement part","updatedById":42,"updatedOn":"..."}
```

Every status with `AskForReason` set collects one. On a stalled ticket it's the note saying
*why* it stopped, which is usually the only thing you need to act. Pass
`include_reasons: true` to `gorelo_list_tickets` and a whole queue explains itself in one call.

---

## Tests

`test/` holds a self-contained fake Gorelo — no live tenant, no real data — and a driver that
speaks genuine JSON-RPC to the server over stdio.

```bash
python3 test/mock_gorelo.py       # in one terminal
python3 test/drive.py             # in another
```

35 assertions covering the cases that have actually broken: merged tickets, unlisted statuses,
assisting assignees, watcher-only exclusion, closed-ticket exclusion, lookup by number,
deleted comments, cursor pagination, rate-limit retry, every write guard, and the protocol
edge cases (unknown method, unknown tool, malformed input).

`python3 test/drive.py somefile.json` runs an arbitrary list of tool calls instead, which is
the quick way to eyeball output while changing a tool.

The mock deliberately reproduces the API's awkward parts — the ignored parameters, the missing
`Merged` status, cursor pagination, `429` with `retry_after`. Testing against a polite fake
would have caught none of the real bugs.

---

## Extras

`scripts/whose-tickets.rb` prints your unclosed tickets split into **lead / assisting /
watcher**, by scanning the whole ticket table. Use it to reconcile against the number Gorelo's
own UI shows you.

---

## Notes

**Why no MCP gem.** The stdio surface of MCP is five methods, so `lib/mcp_server.rb`
implements them directly in about 150 lines. That means no Bundler, no `gem install`, and no
dependency that can break the one tool you actually use. `lib/gorelo_tools.rb` knows nothing
about the transport, so swapping in the official
[Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk) later — for HTTP, OAuth or
resources — leaves the tools unchanged.

**Windows encoding.** Output is written in binary mode so `\n` is never rewritten to `\r\n`,
which would corrupt the line framing, and JSON is generated `ascii_only` so the bytes on the
wire are pure ASCII whatever the machine's code page.

**Not available in the API:** time entries, invoices, contracts, products. Gorelo's public API
doesn't expose them, so anything billing-related has to come from elsewhere.
