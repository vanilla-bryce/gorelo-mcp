# Gorelo MCP server

Lets an AI assistant read your Gorelo PSA — your ticket backlog, clients, contacts and
managed devices — by talking to the Gorelo API on your behalf.

It runs on your own machine and speaks [MCP](https://modelcontextprotocol.io) over
stdin/stdout. Nothing is hosted, nothing is exposed to the internet, and your API key never
leaves your computer.

**Twenty-three tools, nineteen of them read-only.** Plain Ruby — **no gems, no Bundler, no build step.**

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
> One more thing from that release: until 3 October 2026 a **`contract` was what Gorelo's
> web UI called a "Contract Group"**, and a **`ServiceLine` was what the UI called a
> "Contract"**. That was true then; the UI now uses the API's words. See
> [contract naming](#contracts-the-api-and-the-ui-now-use-the-same-words).

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
| `GORELO_API_KEY` | **Required.** Make it read-only to start with — only six tools write. See [key scopes](#api-key-scopes) below. |
| `GORELO_MY_EMAIL` | **Required** for `assignee: "me"`. Must match your Gorelo user exactly. |
| `GORELO_BASE_URL` | Defaults to `https://api.aue.gorelo.io`. Change for other regions. |
| `GORELO_ALLOW_WRITES` | `true` enables the six write tools. Off by default. |
| `GORELO_DOWNLOAD_DIR` | Where `gorelo_get_invoice_pdf` saves PDFs. Defaults to `~/gorelo-invoices`. |
| `GORELO_ATTACH_DIR` | The **only** folder comment attachments can come from. Defaults to `~/gorelo-attachments`. |

#### API key scopes

Since 3 October 2026 Gorelo lets you limit an API key **per module** to Read, Write or Delete
(existing keys keep full access). Create this server's key with:

- **Read** on every module you want the assistant to see;
- **Write** only on **Tickets** (comments, status and client changes), **Time entries** (only if
  you use `gorelo_update_time_entry` or `gorelo_update_time_entries`), **Invoices** (drafts) and **Uptime** (maintenance);
- **no Delete scope on any module.**

Why: this server already has no `DELETE` call anywhere, and with no Delete scope Gorelo enforces
that too, so a bug or a hijacked key still can't remove anything.

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
| `gorelo_list_contracts` | | Contracts with their service lines, recurring amount, cost and margin |
| `gorelo_billing_roles` | | The sell-rate table — what an hour is worth under each role |
| `gorelo_work_types` | | Multipliers and per-entry minimum times — the two fields that change an invoice without changing the hours |
| `gorelo_list_invoices` | | Invoices by client, status, contract or date — names the ones approved but never emailed, and the overdue |
| `gorelo_get_invoice_pdf` | | Saves an invoice PDF to a local folder. ⚠ Gorelo logs every download as an export event |
| `gorelo_get_contract` | | One contract in full: schedule, service lines, labour terms, line items |
| `gorelo_list_items` | | The product and bundle catalogue with category, tax and margin; a bundle against its parts |
| `gorelo_list_uptime` | | Uptime checks and their maintenance windows — names the ones that never expire |
| `gorelo_add_ticket_comment` | **yes** | Adds a comment, optionally with files from one folder. Off by default. |
| `gorelo_update_ticket` | **yes** | Sets a ticket's client or status — nothing else. Off by default. |
| `gorelo_set_uptime_maintenance` | **yes** | Starts or ends a maintenance window on one check — nothing else. Off by default. |
| `gorelo_create_draft_invoice` | **yes** | Raises a manual invoice, always as a Draft. Off by default. |
| `gorelo_update_time_entry` | **yes** | Recodes one time entry's work type, billable status, service line or comment — nothing else. Previews unless `confirm: true`. Gorelo **re-prices** the entry. Off by default. |
| `gorelo_update_time_entries` | **yes** | The batch form: previews up to 50 entries as one list, then applies them one by one and stops at the first error. Off by default. |
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

#### `gorelo_update_time_entry` and `gorelo_update_time_entries`

`PATCH /v1/time-entries/{id}`. Sends only `WorkTypeId`, `BillableStatusId`, `ServiceLineId` and
`Comment`. Hours, dates, technician, billing role and ticket are not reachable, and any other
argument is refused rather than ignored.

- **No `confirm: true`: preview only.** The entry is read and shown with its ticket, date
  (Brisbane time), technician and hours, and each field as current → new. Nothing is written.
  The preview prints `expected_updated_on`.
- **`confirm: true`:** the entry is read again, the write is refused if a supplied
  `expected_updated_on` no longer matches, only the fields that differ are sent, and the
  values Gorelo returns are printed.
- **Gorelo re-prices the entry** when work type, billable status or service line changes: the
  work type's minimum and increment, the role's rate and the contract's terms are re-applied
  and hours move between BlockHours / LimitedHours contracts. Approved, completed, invoiced
  and void entries are refused by Gorelo (409).
- `work_type` is a name or id matched against the live work types (`"Peer Assist"`).
  `billable_status` is Billable, Non-billable, No charge or Void: there is no endpoint that
  lists them, so the four values seen on real entries are built in.
- `service_line_id` is the API ServiceLine (older UI screens called it a Contract).
- The batch tool refuses the whole batch if any entry is invalid, applies entries about one per
  second and stops at the first error, reporting what was and was not applied.
- Every applied change is written to `~/.gorelo-mcp-writes.jsonl`.

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

#### `gorelo_set_uptime_maintenance`

Starts or ends a maintenance window on **one** uptime check, and sends **only**
`MaintenanceMode` — never the target, type, client or tags. A check in maintenance raises no
alerts, so the risk here is silence, not damage:

- `start` needs a **reason** and a **duration** (1–10,080 minutes). A duration outside that
  range, both a duration and `indefinite`, or an action other than `start`/`end` is refused
  before sending. A duration of `0` means the
  window never ends, so it can only be sent with **`indefinite: true`** — never from a default,
  a missing value or a typo.
- The PATCH has no "updated by" field, so the reason is prefixed **`[Gorelo MCP]`**.
- The check is read back, as `gorelo_update_ticket` does, because this API accepts and ignores
  fields it doesn't recognise. On a `start`, the read-back compares the **reason as well as the
  duration**, so a replacement window Gorelo accepted but ignored — leaving the old window's
  duration and reason in place — is reported as failed, not verified.
- If the PATCH itself fails in a way that doesn't prove Gorelo said no — a timeout, a dropped
  connection, a 5xx that outlasted the retries — the change is **never reported as refused**.
  The check is read back anyway, the write is logged as `UNVERIFIED`, and the reply says the
  change **MAY have been applied**, what the read-back shows, and whether that matches what
  was sent. Only an auth failure or a 4xx is reported as refused.

`gorelo_list_uptime` names every window that never expires or has run more than seven days.

A check is chosen by id, or by a fragment of its description **or of its target** (IP or
URL) that matches exactly one check. Gorelo allows a check with no description at all; the
list names such a check by its target and prints its id underneath, since a blank row can be
neither read nor selected.

#### `gorelo_create_draft_invoice`

Raises a manual invoice against one client, **always as a Draft**. `StatusId` is hard-coded to
`1` and there is no parameter to change it: approving an invoice pushes it to Xero/QuickBooks,
and that stays a person's decision, made in Gorelo.

- Each line names a catalogue item by id or **exact** name. A partial or ambiguous name is
  refused with the candidates — an invoice line never lands on a guessed product.
- **Every line is checked before anything is sent**, and every problem is reported at once.
- **No `RecipientEmails`** is ever sent. Cost, tax, account code and billable status come from
  the item.
- An identical invoice within 24 hours is refused, using the same fingerprint log as comments.
  The fingerprint is taken over normalised values, so `2` and `2.0` are the same quantity.
- The POST returns only an id, so the tool reads the invoice back with `GET /v1/invoices/{id}`
  (new on 3 October 2026; before that it had to list the client's recent invoices) — then
  reports the number, status, totals and line items as Gorelo computed them, with a bundle's
  parts indented under it. If that read fails it says so loudly and does not retry.

**A POST whose outcome is unknown is never retried** — for invoices, comments and uploads
alike. That covers a 5xx, a read timeout, a connection dropped or reset after the body went
out (EOF, reset, broken pipe, TLS failure, write timeout), and a success status whose reply
can't be read. None of those says whether the write was applied, and retrying a POST that
*was* applied raises a second invoice. The reply says it *may* exist, and the fingerprint is
recorded so a repeat is refused. Only failures that happen before anything is sent — a
refused connection, a connect timeout, a DNS failure — are reported as "nothing was
created". A 429 is still retried: a rate-limited request was never processed.

#### Attachments on `gorelo_add_ticket_comment`

`files` attaches files to a comment, uploading them first with `POST /v1/attachments`. **Only
files in `GORELO_ATTACH_DIR`** (default `~/gorelo-attachments`) can be attached. Ticket text is
untrusted input the assistant reads; without a fixed folder, a crafted ticket could talk it
into attaching `~/.ssh/id_rsa` or this project's `.env` to a public comment. Paths are resolved
with `realpath` **before** the check, so `..`, `~` and symlinks can't step outside. Each file
must be under Gorelo's 44 MB limit, and every check runs before any upload.

Keep `GORELO_ATTACH_DIR` **empty except while you are attaching something**: the folder is
the whole boundary, so a crafted ticket can still get any file that happens to be sitting in
it attached to that ticket.

At most **10 files** can be attached to one comment, with duplicate names collapsed before
that count is checked, so passing the same file name twice doesn't cost two of the ten.

If an upload or the comment fails after some files were uploaded, those files stay on the
ticket with nothing referencing them — the API has no way to remove them — and the reply names
them; a file whose own upload failed ambiguously (a 5xx, timeout, dropped connection or
unreadable reply after the POST reached Gorelo) is instead named as one that "MAY have been uploaded," since there's no id back to
confirm it landed.

### There is no DELETE, anywhere

Gorelo now exposes `DELETE` for tickets, clients, contacts, agent assets, custom assets,
private comments and time entries — and, since 25 September 2026, invoices, contracts, items
and uptime checks. **None of it is reachable from here, and the guarantee is structural rather
than a policy**: `Gorelo::Client` has `get`, `get_binary`, `post`, `post_multipart` and `patch`
methods and no `delete` method at all. A tool cannot call a method that does not exist.

`gorelo_api_probe` is likewise GET-only — it has no `method` parameter to pass, which the test
suite asserts against the published tool schema.

Leave the write tools off until the read tools have earned their place.

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
/v1/attachments                   POST  ← since 2026-09-25, multipart. /v1/tickets/{id}/attachments
                                        is no longer in the spec
/v1/tickets/statuses | /tags | /types
/v1/clients                       inactive excluded by default since 2026-10-03; this server sends StatusIds=1,2
/v1/contacts                      ClientId is SINGULAR here
/v1/assets/agents                 ClientIds filter since 2026-08-21
/v1/assets/custom                 since 2026-08-21
/v1/organization/users
/v1/time-entries                  GET   ← since 2026-09-04. Tenant-wide, cursor-paginated.
                                        Filters documented 2026-09-25 - see below
/v1/contracts                     GET   ← since 2026-09-04. (a "Contract Group" on UI screens before 3 Oct)
/v1/billing-roles                 GET   ← since 2026-09-04. Small, unpaginated
/v1/work-types                    GET   ← since 2026-09-04. Small, unpaginated
/v1/invoices                      GET, POST   ← since 2026-09-25. POST used for Drafts only
/v1/invoices/{id}                 GET   ← since 2026-10-03. Line items (bundle parts in SubItems) and attachments
/v1/invoices/{id}/pdf             GET   ← since 2026-09-25. A file, not the envelope
/v1/contracts/{id}                GET   ← since 2026-09-25. Service lines with line items
/v1/items | /{id} | /categories   GET   ← since 2026-09-25
/v1/taxes                         GET   ← since 2026-09-25. Small, unpaginated
/v1/uptime | /{id}                GET, PATCH (MaintenanceMode only)  ← since 2026-09-25
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
| `GET /v1/contracts` | yes, cursor | Recurring agreements (older UI screens: Contract Groups) |
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

*An entry has no client.* It names its `Ticket` and nothing else. **Filtering** by client
is now done by the API with `ClientIds` (see the 25 September release below), but
**grouping** entries by client across several clients still needs a ticket-to-client
lookup. This server builds one with a **single paged sweep of `/v1/tickets`** — scoped with
`ClientIds` to just the matched clients' tickets when a client filter was given, otherwise
the whole tenant, cached for the life of the process — and says so in the reply. Never a
fetch per entry, which is the N+1 the new endpoint exists to remove.

### The 25 September 2026 release

**It settled the one thing the 4 September section left open, and exposed a bug.**

*The window filter is documented now.* This README used to say the window parameter on
`/v1/time-entries` was unverified, and the server guessed `CreatedSince`, padded it, and
hedged every reply. The spec now documents `StartedSince`, `StartedBefore`,
`CreatedSince`/`Before`, `UpdatedSince`/`Before`, and the id filters `ClientIds`,
`LocationIds`, `TicketIds`, `TaskIds`, `UserIds` and `InvoiceIds`. The server now sends
`StartedSince`, `UserIds`, `ClientIds` and `TicketIds`. Checked against a live tenant: a
7-day report is **one request** and nothing from before the window comes back. Because the
API silently ignores names it doesn't recognise, the window, `UserIds` and `TicketIds` are
still re-checked locally on every entry, as a safety net: a row that fails is dropped, and
the reply names the filter that wasn't honoured. `ClientIds` can't be re-checked — an entry
carries no client — so it is trusted.

*`AdjustedHours` can be null, and null does not mean zero.* The spec now says
`AdjustedHours` is **null when no rounding applied, and the billed duration is then
`ActualHours`**. This server read the null as `0`, so every unrounded entry vanished from
"to invoice" and "billable", and realisation came out low. It is fixed. On the tenant it
was checked against, every work type rounds, so no entry in the previous 30 days was
affected — but a tenant, or a work type, without rounding would have been.

The same release added invoices, the item catalogue, taxes, full contract detail, uptime
checks and a general attachment upload, and the tools above use all of them. Three things
about them are easy to miss:

- **Downloading an invoice PDF is not a pure read.** Gorelo records each download against the
  invoice as an export event.
- **`PageSize` outside 1–200 is a 400** on `/v1/invoices`, `/v1/items` and `/v1/uptime`, not
  clamped as on the older endpoints.
- **Subcategory ids are not unique.** They are issued independently of category ids, so one
  number can name a subcategory under two categories. Look one up only inside its own
  category.

A fourth wrinkle sits in `gorelo_list_items` rather than the API itself: when a bundle's part
has no cost or price, the tool prints the bundle's sum-of-parts as **"unknown"** rather than
silently counting the missing part as zero, which would understate the total without saying so.

### The 3 October 2026 release

**One of these broke things silently; the rest are renames and new capabilities.**

- **`BaseStatusId` became `BaseStatus {Id, Name}`.** A ticket's status class is now an object.
  This server read the old field, got nothing, and so could no longer tell closed tickets from
  open ones: "open" returned closed tickets as well — **664 against 78 live**. Fixed in
  `8445efa`, which reads `BaseStatus.Id`. This is the same failure shape as the 2026-08-21
  renames: nothing errors, the numbers are just wrong.
- **The web UI was renamed to match the API.** Contract Group → **Contract**, Contract →
  **Service line**, Contract Type → **Labor terms**, Per Hour → **Hourly**, Automatically
  Covered → **Coverage**. The API's own words did not change. See
  [the contracts note](#contracts-the-api-and-the-ui-now-use-the-same-words).
- **`GET /v1/invoices/{invoiceId}` exists.** It returns the invoice plus `LineItems[]` (a
  bundle is one line with its parts in `SubItems`) and `Attachments[]`. `gorelo_create_draft_invoice`
  now reads the new draft back with it, and `gorelo_list_invoices` with `number` shows the line
  items. The old "list the client's recent invoices" read-back is gone.
- **`GET /v1/clients` excludes inactive clients by default.** `StatusIds=1,2` returns both
  (173 active + 3 inactive = 176 on the tenant checked). The server now always asks for both,
  so an inactive client's tickets still have a name, and marks such clients `(inactive)`.
- **Time-entry billable status names changed:** `Billable`, `No charge`, `Non-billable` (were
  `Billable`, `No Charge`, `Not Billable`). The server decides billable by the status name
  *starting with* "billable", so `Non-billable` is correctly not billable; the suite pins that.
- **API keys can be limited per module** to Read, Write or Delete — see
  [key scopes](#api-key-scopes).
- **Contract dates are now calendar dates** rather than timestamps. No code change was needed:
  the server already shows only the first ten characters.
- **`ClientId` / `LocationId` are `null` instead of `-1`** for unassigned agents and uptime
  checks. No code change was needed.

### Contracts: the API and the UI now use the same words

Until 3 October 2026 the UI used different words from the API for the same objects:

| In the API | In Gorelo's web UI until 3 Oct 2026 | Now |
|---|---|---|
| a `contract` (`/v1/contracts`) | a **Contract Group** — the invoice | **Contract** |
| a `ServiceLine` inside it | a **Contract** | **Service line** |

That mismatch was real and made correct data look wrong, which is why the tools used to print
both vocabularies. It is gone: the UI was renamed to match the API. The contract tools now
print a single line saying so, for anyone holding an old screenshot or export.

A contract with **no service lines** is flagged: it is an invoice container with
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
- Spec JSON: `https://api.aue.gorelo.io/swagger/v1/swagger.json` (no API key needed).
  Appending `/v1/swagger.json` to the base URL, as this README used to say, is a 404.
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

263 assertions covering the cases that have actually broken: merged tickets, unlisted statuses,
assisting assignees, watcher-only exclusion, closed-ticket exclusion, lookup by number,
deleted comments, cursor pagination, rate-limit retry, every write guard, and the protocol
edge cases (unknown method, unknown tool, malformed input). The driver sets
`GORELO_READ_TIMEOUT` low so a read timeout on a POST can be reproduced in well under a
second instead of waiting on the real 60-second default.

The fake tenant carries 225 time entries — enough to force a second cursor page — including
**two technicians logging time on one ticket**, which is precisely the case the old
lead-assignee attribution got wrong. One client is held back from the bulk generator so a
per-client total is exactly predictable, which is what proves the ticket-to-client
resolution works at all: an entry carries no client of its own. One of that client's
entries has a **null `AdjustedHours`**, which must invoice at its `ActualHours`. The fake
`/v1/time-entries` honours the filters the spec documents and **ignores every other name**,
as the real API does, and it records the query it last received, so the suite asserts
which parameter names were actually sent. `/v1/time-entries/statuses` answers 404,
because it does.

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
(invoiceable ÷ recorded hours — what survived rounding and write-downs, where a null
`AdjustedHours` invoices at `ActualHours`) with the **billable
share** as a separate column, rather than the two being folded into one number.

⚠️ **Do not treat any endpoint list as complete, including this one.** The published
`swagger.json` is large enough that fetching it through a summarising tool silently truncates,
and a truncated list reads exactly like a short one. The time-entry route above was missed
precisely that way — declared absent on the strength of a partial read of the spec plus two
404s on the wrong path spellings.

⚠️ Note `/v1/tickets/{ticketId}` now accepts **PATCH** and **DELETE**, and clients and contacts
accept **POST/PATCH/DELETE**. This server issues none of them.
