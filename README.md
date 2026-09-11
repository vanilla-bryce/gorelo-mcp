# Gorelo MCP server

Lets an AI assistant read your Gorelo PSA — your ticket backlog, clients, contacts and
managed devices — by talking to the Gorelo API on your behalf.

It runs on your own machine and speaks [MCP](https://modelcontextprotocol.io) over
stdin/stdout. Nothing is hosted, nothing is exposed to the internet, and your API key never
leaves your computer.

**Sixteen tools, fourteen of them read-only.** Plain Ruby — **no gems, no Bundler, no build step.**

> ### ⚠️ Correction — 11 September 2026
>
> Earlier versions of this README stated, as established fact, that **Gorelo has no
> readable time-entry API** and that per-user hours were impossible. That was true when it
> was written. **It is false now.** Gorelo's **4 September 2026** release shipped
> `GET /v1/time-entries` — one row per logged entry, tenant-wide, each carrying the user
> who logged it — along with `/v1/contracts`, `/v1/billing-roles` and `/v1/work-types`.
>
> `gorelo_time_report` has been rebuilt on it. It no longer attributes a ticket's hours to
> the lead assignee, no longer warns that per-person totals are "indicative", and no longer
> costs one request per ticket. **If you built anything on the old limitation, or repeated
> it to anyone, it needs revisiting.** Details:
> [what changed on 4 September 2026](#the-4-september-2026-release).
>
> One more thing that release makes unavoidable: in the API a **`contract` is what
> Gorelo's web UI calls a "Contract Group"**, and a **`ServiceLine` is what the UI calls a
> "Contract"**. The words are inverted. See
> [contracts are inverted](#contracts-the-api-and-the-ui-use-the-same-words-for-different-things).

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
| `GORELO_ALLOW_WRITES` | `true` enables the two write tools. Off by default. |

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
| `gorelo_time_report` | | Recorded vs invoiceable vs billable hours, and realisation, by technician or client — from real per-entry data, so per-person totals are exact |
| `gorelo_list_time_entries` | | The individual entries behind a total: who, when, comment, work type, billing role, service line |
| `gorelo_response_report` | | First-response times — median, 90th, worst, share within target. Costs no extra requests |
| `gorelo_list_contracts` | | Contract **groups** (what the UI calls contracts' parent invoice) with their service lines, recurring amount, cost and margin |
| `gorelo_billing_roles` | | The sell-rate table — what an hour is worth under each role |
| `gorelo_work_types` | | Multipliers and per-entry minimum times — the two fields that change an invoice without changing the hours |
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
/v1/time-entries                  GET   ← since 2026-09-04. Tenant-wide, cursor-paginated
/v1/contracts                     GET   ← since 2026-09-04. "Contract GROUPS" in the UI
/v1/billing-roles                 GET   ← since 2026-09-04. Small, unpaginated
/v1/work-types                    GET   ← since 2026-09-04. Small, unpaginated
```

`GET /v1/time-entries/statuses` is a **404**. It looks like it ought to exist, by analogy
with `/v1/tickets/statuses`. It does not. Don't invent it.

### The 4 September 2026 release

**This release invalidated a claim this README made for three weeks.** Four endpoints
appeared, all returning HTTP 200 with the usual
`{StatusCode, IsSuccess, Data, DataContext, Notifications}` envelope and the same
`DataContext.Pagination.NextCursor` scheme everything else uses:

| Endpoint | Paginated | What it holds |
|---|---|---|
| `GET /v1/time-entries` | yes, cursor | One row per logged entry, **tenant-wide** |
| `GET /v1/contracts` | yes, cursor | Recurring agreements — *the UI calls these Contract Groups* |
| `GET /v1/billing-roles` | no | `Id`, `Name`, `HourlyRate`, `CoaCode`, `Tax` |
| `GET /v1/work-types` | no | `Id`, `Name`, `HourlyMultiplier`, `IsDefaultOutsideBusinessHours`, `BillableStatus`, `CoaCode`, `Tax`, `MinimumTimeInMinutes` |

A time entry carries:

```
Id, Ticket {Id, Number, Title}, Task, User {Id, Name},
StartedOn, EndedOn, ActualHours, AdjustedHours,
BillableStatus {Id, Name}, BillingRole {Id, Name}, WorkType {Id, Name},
ServiceLine {Id, Name}, Comment, Distance, Attachments,
CreatedOn, UpdatedOn
```

**What this changed here.** `gorelo_time_report` used to page `/v1/tickets`, fetch each
ticket's time summary with **one extra request per ticket**, and book every hour to that
ticket's **lead assignee** — so an assisting technician's time was reported against
somebody else. It said so on every run, and the caveat was honest. It is now one paged
sweep of `/v1/time-entries`, grouped by the `User` on each entry, so **per-technician
totals are exact** and assisting time lands on whoever did it. The warning has been
deleted along with the behaviour that made it necessary.

**Two things to settle before you rely on it.**

*An entry has no client.* It names its `Ticket` and nothing else, so anything grouped or
filtered by client needs a ticket-to-client lookup. This server builds one with a **single
paged sweep of `/v1/tickets`**, cached for the life of the process, and says so in the
reply — never a fetch per entry, which is the N+1 the new endpoint exists to remove.
Grouping by technician costs nothing beyond the entries themselves.

*The window filter's parameter name is unverified.* `/v1/tickets` documents
`CreatedSince`/`UpdatedSince`; whether `/v1/time-entries` accepts either has not been
confirmed against the spec, and this API **ignores parameters it doesn't recognise**, so a
wrong name returns everything and looks like it worked. So the guess is only allowed to
make the call cheaper, never to decide what's in the report: the window is applied
**locally** on `StartedOn`, the value sent is padded two weeks earlier, and the call is
retried without it if it's rejected. Every reply says which of those happened, so the
first person to run it against a live tenant learns the answer instead of inheriting the
guess.

### Contracts: the API and the UI use the same words for different things

**They are inverted, and it will make correct data look wrong.**

| In the API | In Gorelo's web UI |
|---|---|
| a `contract` (`/v1/contracts`) | a **Contract Group** — the invoice |
| a `ServiceLine` inside it | a **Contract** |

So one API contract is a billing container holding several UI contracts. Gorelo has said
it intends to **align the UI to the API** eventually, which means the words will swap
rather than the confusion disappearing. `gorelo_list_contracts` prints both vocabularies on
every run for exactly that reason, and `gorelo_list_time_entries` labels an entry's
`ServiceLine` as *"service line (UI: contract)"*.

A contract group with **no service lines** is flagged: it is an invoice container with
nothing on it, and from outside it looks identical to a healthy one.

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
never call — which is how `/v1/tickets/{id}/time-entries/{id}` was confirmed to be a
DELETE-only route after two wrongly-spelled guesses had returned 404. `gorelo_api_probe`
explains any 405 it gets rather than reporting it as a dead end.

⚠️ **But a 405 tells you about one path and one verb — never about a feature.** That
DELETE-only route was read here as proof that *time entries could not be read at all*, which
it never was; the tenant-wide collection simply hadn't shipped yet. Map paths this way, not
capabilities.

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

97 assertions covering the cases that have actually broken: merged tickets, unlisted statuses,
assisting assignees, watcher-only exclusion, closed-ticket exclusion, lookup by number,
deleted comments, cursor pagination, rate-limit retry, every write guard, and the protocol
edge cases (unknown method, unknown tool, malformed input).

The fake tenant carries 224 time entries — enough to force a second cursor page — including
**two technicians logging time on one ticket**, which is precisely the case the old
lead-assignee attribution got wrong. One client is held back from the bulk generator so a
per-client total is exactly predictable, which is what proves the ticket-to-client
resolution works at all: an entry carries no client of its own. The fake `/v1/time-entries`
**ignores every query parameter it is given**, as the real API does with names it doesn't
recognise, so a tool that trusted a server-side window filter would report the wrong window
and the suite would catch it. `/v1/time-entries/statuses` answers 404, because it does.

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

**Still not observed through the API:** invoices. Contracts and time entries **are** readable
as of 4 September 2026 — see above.

Confirmed endpoints (this list is what has been *observed*, not a claim to completeness — see
the warning below):

```
/v1/alerts (POST)                     /v1/organization/users
/v1/assets/agents      {id}           /v1/organization/groups
/v1/assets/custom      {id}           /v1/tickets
/v1/clients            {id}           /v1/tickets/{ticketId}   GET PATCH DELETE
/v1/clients/{id}/locations            /v1/contacts             {id}
/v1/time-entries       (2026-09-04)   /v1/contracts            (2026-09-04)
/v1/billing-roles      (2026-09-04)   /v1/work-types           (2026-09-04)
/v1/tickets/{id}/time-entries/{id}    DELETE only — see below
```

### Time entries: what was true until 4 September 2026, and what is true now

**This section used to say time entries could not be read. That is no longer correct, and the
reasoning that led there is worth keeping as a warning.**

The evidence at the time was real: `/v1/tickets/{ticketId}/time-entries/{id}` answers **405**
to a `GET`, so the route exists for another verb; the **collection** path
`/v1/tickets/{id}/time-entries` answered **404**; `/v1/time-entries/{id}` answered **404**;
and the ticket detail carried `Time` **totals** with no entry ids. The conclusion drawn — that
Gorelo shipped a way to *delete* a time entry and no way to *read* one — followed from those
four observations and was stated here as fact.

**What was actually being measured was four paths on one day.** On **4 September 2026** Gorelo
shipped the tenant-wide collection `GET /v1/time-entries`, which returns every entry with its
`User`, hours, `BillableStatus`, work type, billing role and comment. The per-ticket sub-route
is still DELETE-only, and this server still never sends DELETE — but "one path is write-only"
was never the same claim as "this data cannot be read", and conflating them cost this README
three weeks of telling other people something untrue.

`gorelo_time_report` no longer attributes hours to a lead assignee, because it no longer has
to guess who did the work: the entry says. **Realisation** is now reported as its own ratio
(`AdjustedHours ÷ ActualHours` — what survived rounding and write-downs) with the **billable
share** as a separate column, rather than the two being folded into one number.

⚠️ **Do not treat any endpoint list as complete, including this one.** The published
`swagger.json` is large enough that fetching it through a summarising tool silently truncates,
and a truncated list reads exactly like a short one. The time-entry route above was missed
precisely that way — declared absent on the strength of a partial read of the spec plus two
404s on the wrong path spellings.

⚠️ Note `/v1/tickets/{ticketId}` now accepts **PATCH** and **DELETE**, and clients and contacts
accept **POST/PATCH/DELETE**. This server issues none of them.
