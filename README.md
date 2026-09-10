# Gorelo MCP server

Lets an AI assistant read your Gorelo PSA — your ticket backlog, clients, contacts and
managed devices — by talking to the Gorelo API on your behalf.

It runs on your own machine and speaks [MCP](https://modelcontextprotocol.io) over
stdin/stdout. Nothing is hosted, nothing is exposed to the internet, and your API key never
leaves your computer.

**Twelve tools, ten of them read-only.** Plain Ruby — **no gems, no Bundler, no build step.**

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
| `gorelo_billing_review` | | The Billing queue split by recorded hours — invoice, re-file, or set up a recurring charge |
| `gorelo_time_report` | | Recorded vs invoiceable vs billable hours, and realisation, by technician or client |
| `gorelo_response_report` | | First-response times — median, 90th, worst, share within target. Costs no extra requests |
| `gorelo_add_ticket_comment` | **yes** | One of two writes. Off by default. |
| `gorelo_update_ticket` | **yes** | Sets a ticket's client or status — nothing else. Off by default. |
| `gorelo_api_probe` | | Raw `GET` on any `/v1/…` path, for exploring |

### The write tools

Four guards sit in front of `gorelo_add_ticket_comment`:

1. **Disabled** unless `GORELO_ALLOW_WRITES=true`
2. **`confirm: true` required** on every call
3. **`ConversationTypeId` is always sent explicitly** — `2` (Private) by default, `1` (Public)
   only when `visibility: "client"` is asked for. The field is *optional* in the API, so
   omitting it lets the server pick, and a private note posting publicly is the worst thing
   this tool could do. It is never left to a default.
4. **Identical comments within 24 hours are refused.** MCP has no transport-level
   idempotency, so a retried call could otherwise post twice. A fingerprint log at
   `~/.gorelo-mcp-writes.jsonl` prevents it. The fingerprint includes the visibility, so the
   same text cannot be posted once privately and once publicly by accident.

The body is sent as **HTML**, because that is what the API expects. Plain text is escaped and
paragraph-wrapped, so `<` and `&` cannot corrupt the markup.

The request body is `CreatePublicCommentCommand`: `ConversationTypeId`, `Body`,
`CreatedByName`, `Attachments`. `ConversationId` is **rejected** for Public and Private and is
never sent. The test mock enforces all of that — it rejects unknown fields — so the suite
fails if the payload drifts from the documented schema.

#### `gorelo_update_ticket`

Sets **the client or the status**, and nothing else. Not the title, not the assignee, not the
priority.

It exists for two recurring problems: a ticket with **no client attached** never appears in any
client-scoped review, and a ticket parked in the wrong status makes a queue mean two things.

**The endpoint accepts far more than this tool sends.** The documented PATCH body includes
`Title`, `LeadAssigneeId`, `AssistingAssigneeIds`, `WatcherIds`, `PriorityId`, `TypeId`,
`TagIds`, `GroupIds`, `ContactId`, `CcContactIds`, `AgentAssetIds`, `CustomAssetIds`,
`UptimeIds` and `BillingOverride`. Sending only `ClientId` and `StatusId` is a deliberate
restriction — reassigning a ticket or rewriting its title from here would change someone
else's queue without them watching it happen.

**Changes are attributed.** `UpdatedByName` is set (default `"Gorelo MCP"`, overridable with
`author`). Unlike a comment, a status change leaves no visible content in the ticket — only a
history line — so an unattributed one is indistinguishable from a human doing it by hand.

**Every change is verified.** The tool reads the ticket, writes, reads it back, and confirms
the value actually moved — then reports before and after. That is not belt-and-braces: this API
**ignores fields it does not recognise instead of rejecting them**, exactly as it does with
query parameters, so a mistyped payload field returns `200` and changes nothing. Without the
read-back, a write that never happened is indistinguishable from one that did. When the check
fails the tool says so loudly, names the likely cause, and prints the payload it sent.

### There is no DELETE, anywhere

Gorelo now exposes `DELETE` for tickets, clients, contacts, agent assets, custom assets,
private comments and time entries. **None of it is reachable from here, and the guarantee is
structural rather than a policy**: `Gorelo::Client` has `get`, `post` and `patch` methods and
no `delete` method at all. A tool cannot call a method that does not exist.

`gorelo_api_probe` is likewise GET-only — it has no `method` parameter to pass, which the test
suite asserts against the published tool schema.

Leave both write tools off until the read tools have earned their place.

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
/v1/tickets/{id}                  GET   ← much richer than a list row; see below
/v1/tickets/{id}/comments         GET, POST   (oldest-first; ConversationType filter)
/v1/tickets/{id}/comments/{id}    GET
/v1/tickets/{id}/conversations    GET
/v1/tickets/{id}/attachments      POST
/v1/tickets/statuses | /tags | /types
/v1/clients
/v1/contacts                      ClientId is SINGULAR here
/v1/assets/agents                 ClientIds filter since 2026-08-21
/v1/assets/custom                 since 2026-08-21
/v1/organization/users
```

### The 2026-08-21 release

**Three fields were renamed, and every one of them fails silently.** A renamed field does not
error — it simply stops appearing, so a flag stops showing and a date vanishes from a report
with nothing to say it happened. This server reads **both** names so it works against a tenant
on either version:

| Endpoint | Was | Now |
|---|---|---|
| `/v1/tickets` | `IsAwaitingClient` | `IsWaitingOnThem` |
| `/v1/tickets` | SLA minutes | `Sla.FirstResponse.ElapsedBusinessMinutes` |
| `/v1/assets/agents` | `ClientLocationId` | `LocationId` |
| `/v1/assets/agents` | `WarrantyExpiryDate` | `WarrantyStartDate` + `WarrantyEndDate` |
| `/v1/contacts` | `ClientLocationId` | `LocationId` |

**`GET /v1/tickets/{id}` now answers billing questions the API previously could not.** A list
row does not carry any of this — only the get-by-id does, so a tool that wants it must fetch
the detail even when it already has the ticket:

```
Time.ActualHours          what was recorded
Time.AdjustedHours        what will be invoiced
Time.Breakdown.Billable / .NotBillable / .NotBillableHidden
Products.Count / .TotalAmount
BillingOverride, Shipments, Description, AgentAssetIds, Banner
```

The distinction that matters for a backlog review: **a ticket sitting in *Billing* with
`ActualHours` of 0 was never time-recorded**, which is a different problem — and a different
fix — from one with hours that simply have not been invoiced yet. `gorelo_get_ticket` flags
both.

**Filtering arrived on clients, contacts and agent assets:** `StatusIds`, `ClientIds`, keyword
`Query`, and created/updated date ranges. `gorelo_list_assets` used to page the entire fleet —
626 devices on a real tenant — to show four; it now sends `ClientIds`. Verified applied rather
than ignored by the FilterHash trick below.

⚠️ **DELETE endpoints now exist** for agent assets, custom assets, clients, contacts, tickets
and private comments. **This server never sends DELETE**, and `gorelo_api_probe` is GET-only —
both asserted in the test suite so it stays that way. Blocked deletes return 409 naming what is
in the way.

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

**405 versus 404 maps the surface.** A `404` means no route of any verb matches that path. A
`405` means **the route exists and does not accept this one**. So a plain `GET` against a
candidate path is a reliable existence test, even for write-only endpoints this server would
never call — which is how the DELETE-only time-entry route above was confirmed after two
wrongly-spelled guesses had returned 404. `gorelo_api_probe` explains any 405 it gets rather
than reporting it as a dead end.

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

69 assertions covering the cases that have actually broken: merged tickets, unlisted statuses,
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

**Not readable through the API:** invoices, contracts, and **time entries**.

Confirmed endpoints (this list is what has been *observed*, not a claim to completeness — see
the warning below):

```
/v1/alerts (POST)                     /v1/organization/users
/v1/assets/agents      {id}           /v1/organization/groups
/v1/assets/custom      {id}           /v1/tickets
/v1/clients            {id}           /v1/tickets/{ticketId}   GET PATCH DELETE
/v1/clients/{id}/locations            /v1/contacts             {id}
/v1/tickets/{id}/time-entries/{id}    DELETE only — see below
```

### Time entries exist, and cannot be read

`/v1/tickets/{ticketId}/time-entries/{id}` **is a real route** — a `GET` returns **405 Method
Not Allowed**, not 404. But:

- the **collection** path `/v1/tickets/{id}/time-entries` returns 404 — no route at all;
- `/v1/time-entries/{id}` returns 404 — it is ticket-scoped only;
- the ticket detail carries `Time` **totals**, never individual entry ids.

So Gorelo ships a way to **delete** a time entry and no way to **read** one. Nothing in the API
will tell you an entry's id, which makes the DELETE unusable from the API alone. Worth raising
with them; until it changes, hours exist only as a per-ticket total.

That is why `gorelo_time_report` attributes a ticket's hours to its lead assignee — counting an
assisting technician's time against the lead — says so on every run, and leans on
**realisation** (billable ÷ invoiceable), a ratio that survives the attribution problem far
better than a per-person total does.

⚠️ **Do not treat any endpoint list as complete, including this one.** The published
`swagger.json` is large enough that fetching it through a summarising tool silently truncates,
and a truncated list reads exactly like a short one. The time-entry route above was missed
precisely that way — declared absent on the strength of a partial read of the spec plus two
404s on the wrong path spellings.

⚠️ Note `/v1/tickets/{ticketId}` now accepts **PATCH** and **DELETE**, and clients and contacts
accept **POST/PATCH/DELETE**. This server issues none of them.
