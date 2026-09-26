# Tools for Gorelo's 25 September 2026 release — design

Status: draft for review · 2026-09-26

## Goal

Cover the endpoints Gorelo shipped on 25 September 2026 that are useful to an MSP
reviewing billing and monitoring, **without weakening the server's safety model**:
read-mostly, every write off by default, and no DELETE reachable from any tool.

Agreed scope (from brainstorming):

- **Read:** invoices, invoice PDF, full contract detail, item catalogue (with categories
  and taxes), uptime checks.
- **Guarded writes:** uptime maintenance mode, Draft-only manual invoices, file
  attachments on ticket comments.
- **Out of scope:** item create/edit, invoice approve/void/delete, contract delete, uptime
  create/delete, anything on projects/forms. The structural no-DELETE guarantee stays:
  `Gorelo::Client` still has no `delete` method.

Part A (time-entry filters, null `AdjustedHours`, README corrections) is already done in
commit `8c1993a` and is not repeated here.

## Tools

Server goes from **16 tools to 23**: 5 read, 2 write, and one existing write tool gains a
parameter.

### Read

**`gorelo_list_invoices`** — `GET /v1/invoices`

- Inputs: `client` (name fragment → `ClientIds`), `status` (`draft|approved|paid|void|all`,
  default `all` → `StatusIds` 1/5/3/4), `contract` (id → `ContractIds`), `days` (window on
  `InvoiceDateSince`, default 90), `emailed` (`true|false` → `IsEmailSent`), `number`
  (→ `Number`), `limit` (default 50).
- Output: one row per invoice — display number, client name, status, invoice/due date,
  total, amount due, emailed yes/no. Totals per status.
- Flags, each listed by name rather than counted:
  - **Approved but never emailed** (`Status` Approved, `IsEmailSent` false) — pushed to
    accounting, never reached the client.
  - **Overdue** (`AmountDue > 0`, `DueDate` before today, not Void).
- Every filter is a documented parameter, so all filtering is server-side. An invoice's
  `Id` is a UUID; the `DisplayNumber` (e.g. `INV-1042`) is what people quote, so that is
  what the tool prints.

**`gorelo_get_invoice_pdf`** — `GET /v1/invoices/{id}/pdf`

- Input: `invoice` — a UUID, or a number (`INV-1042` / `1042`) resolved with one
  `GET /v1/invoices?Number=` call.
- Saves the PDF to `GORELO_DOWNLOAD_DIR` (default `~/gorelo-invoices`) as the display
  number, and returns the absolute path and size. The binary never passes through MCP.
- ⚠ The spec says **each download is recorded against the invoice as an export event**.
  It's a GET, but it leaves a visible trace in Gorelo, so the tool description says so.
- Needs `Client#get_binary`: same auth/retry/error handling as `get`, but returns the raw
  body when `Content-Type` is `application/pdf` (errors still arrive as the JSON envelope).

**`gorelo_get_contract`** — `GET /v1/contracts/{id}`

- Input: `contract` — numeric id, or a name fragment matched against the
  `/v1/contracts` list (one paged sweep, cached); an ambiguous fragment lists the
  candidates instead of guessing.
- Output: client, status, dates, repeat period, invoice schedule
  (`DaysBeforeInvoiceCreation`, `InvoiceDue`, `AutoApproveAndSend`), contacts, recurring
  amount / cost / margin; then each service line with its labour terms, the filled terms
  detail (block-hours balance and thresholds, rate type, auto-approve), work types, roles,
  and its line items (name, qty, unit price, cost, amount, tax name, billable status).
- Prints both vocabularies on every run, as `gorelo_list_contracts` does:
  API "contract" = UI "Contract Group", API "ServiceLine" = UI "Contract".
- Flags: `AutoApproveAndSend` on (invoices go out unreviewed), a block-hours line below its
  warning threshold, a service line with no line items.
- Tax names come from `GET /v1/taxes` (one small request, cached).

**`gorelo_list_items`** — `GET /v1/items`, `/v1/items/{id}`, `/v1/items/categories`, `/v1/taxes`

- Inputs: `query` (→ `Query`), `type` (`product|bundle|all` → `TypeIds`), `category`
  (name fragment, resolved locally against categories → `CategoryIds`), `client`
  (→ `ClientIds`), `status` (`active|archived|all`, default `active` → `StatusIds`),
  `item` (one UUID or exact name → detail view), `limit`.
- List view: name, type, SKU, category › subcategory, unit cost, unit price, margin %, tax
  name. Categories and taxes are one request each, cached.
- Detail view (`item`): adds bundle `SubItems` with quantity and cost/price, the bundle's
  derived cost vs. the sum of its parts, and whether sub-items show on the invoice.
- This is where a caller finds the `ItemId` that `gorelo_create_draft_invoice` needs.
  There is no separate taxes tool; `gorelo_api_probe` covers a raw lookup.

**`gorelo_list_uptime`** — `GET /v1/uptime`, `/v1/uptime/{id}`

- Inputs: `client` (→ `ClientIds`), `type` (`icmp|http|tcp` → `TypeIds`), `query`
  (→ `Query`), `maintenance` (`only|exclude|all`, local filter), `limit`.
- Output: description, client, type, target (IP:port or URL), status, frequency, and
  maintenance state — reason, start, and **when it ends** (start + duration), or
  **"never expires"** when the duration is 0.
- Flags: checks in maintenance with no expiry, and windows that started more than 7 days ago.

### Writes

All three follow the existing pattern exactly: refused unless `GORELO_ALLOW_WRITES=true`,
refused unless `confirm: true`, attributed, read back after writing, and the result reports
before/after — or a loud failure naming the payload sent. Each advertises
`readOnlyHint: false`; the suite asserts the exact set of write tools.

**`gorelo_set_uptime_maintenance`** — `PATCH /v1/uptime/{id}`

- Inputs: `check` (UUID, or a description fragment that must match exactly one check),
  `action` (`start|end`), `minutes` (required for `start`, 1–10080), `indefinite`
  (bool; the only way to send `DurationInMinutes: 0`), `reason` (required for `start`),
  `confirm`.
- Payload is **only** `MaintenanceMode`. Start → `{Enabled: true, StartDateTime: now,
  DurationInMinutes, Reason}`; end → `{Enabled: false}`. Nothing else in the PATCH body is
  ever sent, and the mock rejects any other field.
- Attribution: the PATCH has no "updated by" field, so `Reason` is prefixed with
  `[Gorelo MCP] ` — otherwise a paused check looks like a human did it.
- Why `indefinite` is separate: a duration of 0 means the window never ends, so a check
  stays silenced forever. That should never come from a default or a typo.
- Read-back: `GET /v1/uptime/{id}` and confirm `MaintenanceMode.Enabled` moved.

**`gorelo_create_draft_invoice`** — `POST /v1/invoices`

- Inputs: `client` (must resolve to exactly one), `lines` (array of `{item, quantity,
  unit_price?, description?}`; `item` is an ItemId UUID or an exact item name, resolved via
  `/v1/items`), `reference`, `invoice_date`, `due_date`, `confirm`.
- **`StatusId` is always `1` (Draft).** There is no parameter to change it. Approving pushes
  the invoice to Xero/QuickBooks, and that stays a human action in Gorelo.
- Not sent: `RecipientEmails` (Draft invoices aren't emailed; leaving it out means nothing
  goes to a client address from here), `UnitCost`, `TaxId`, `CoaCode`, `BillableStatusId`,
  `DiscountPercent` — all fall back to the item's own values, which is the safe default.
- Duplicate guard: fingerprint of client + normalised lines + reference, refused within 24h,
  using the same `~/.gorelo-mcp-writes.jsonl` log as comments. MCP has no idempotency, so a
  retried call would otherwise raise two invoices.
- Read-back: the POST returns only `Id`, and there is no `GET /v1/invoices/{id}`. So the
  tool records the time before the POST, then lists
  `GET /v1/invoices?ClientIds=…&CreatedSince=<that time>` and finds the `Id`. It reports
  display number, status (must be Draft), subtotal/tax/total, and line count. If the `Id`
  can't be found, it says so loudly and does **not** retry the POST.

**`gorelo_add_ticket_comment` gains `files`** — `POST /v1/attachments` (multipart)

- New optional input: `files`, an array of local file names.
- **Files must live in `GORELO_ATTACH_DIR`** (default `~/gorelo-attachments`). A path is
  resolved with `File.realpath` and refused if it lands outside that directory — so no `..`
  and no symlink escape. **Why this guard matters:** ticket text is untrusted input
  that an assistant reads. Without a fixed directory, a crafted ticket could talk the
  assistant into "attaching" `~/.ssh/id_rsa` or this project's `.env` to a public comment.
  With it, only files a person deliberately put in that directory can leave the machine.
- Each file: must be a regular file, ≤ 44 MB (the documented limit), checked before any
  upload. Uploaded with `itemType=Ticket`, `itemId=<ticket GUID>`; the returned `{Name, Url}`
  goes into the comment's `Attachments`. The URL is never stored (the spec says its token
  is time-limited).
- Order: all uploads first, then the comment. If the comment then fails, the uploaded files
  are orphaned on the ticket, with nothing referencing them. The reply says so and names
  them. There is no endpoint to remove them.
- The dedupe fingerprint gains each file's SHA-256, so the same text with a different
  attachment isn't refused as a duplicate.
- Needs `Client#post_multipart(path, fields, file)`: `guard_writes!` first, and
  `Net::HTTP::Post#set_form` with `multipart/form-data`. Stdlib only.

## Structure

- `lib/gorelo.rb`: add `get_binary` and `post_multipart`. **No `delete`.** Add cached
  `taxes`, `item_categories` and `contracts` helpers beside `clients`/`users`.
- `lib/gorelo_billing_tools.rb` (new): invoices, invoice PDF, contract detail, items, draft
  invoice. `lib/gorelo_uptime_tools.rb` (new): uptime list and maintenance.
  Both are `module_function` modules registered from `GoreloTools.register`. They call the
  existing formatting helpers as `GoreloTools.pad` / `.clip` / `.nested` (already
  `module_function`), so nothing in `gorelo_tools.rb` moves.
- `gorelo_tools.rb` changes only in `add_ticket_comment` (the `files` parameter) and
  `register`.
- `gorelo-mcp-server.rb`: the server instructions list the write tools and state that
  invoices are only ever created as Draft.
- `.env.example`: `GORELO_DOWNLOAD_DIR`, `GORELO_ATTACH_DIR`.

## Errors

Same as today: auth failures surface plainly, 429/5xx retry, 4xx surface Gorelo's
notification text. Specific to this release:

- `/pdf` returns the JSON envelope on error but a PDF on success; `get_binary` checks the
  content type before deciding which.
- `PageSize` out of range is a **400** on `/v1/invoices`, `/v1/items` and `/v1/uptime`
  (not clamped, unlike older endpoints). The client already sends 200, which is in range.
  The mock will enforce the 400 so a future change can't slip past.
- Id filters reject a non-id with a 400, so name fragments are always resolved to ids first.

## Testing

Extend `test/mock_gorelo.py` with invented fixtures for every new endpoint, following
its existing rule: reproduce the awkward parts, don't be a polite fake.

- Invoices across all four statuses, including one Approved and never emailed, and one
  overdue; `Number` filter; `PageSize` > 200 → 400.
- `/pdf` returns `%PDF-` bytes with `application/pdf`; unknown id → JSON 404.
- One contract with a block-hours line under its warning threshold and
  `AutoApproveAndSend` on.
- Products and a bundle with sub-items; categories with subcategories; a tax with
  `SubTaxes`.
- Uptime checks: one in maintenance with duration 0.
- `PATCH /v1/uptime/{id}` **rejects any field other than `MaintenanceMode`**.
  `POST /v1/invoices` rejects unknown fields, and records `StatusId` so the suite asserts
  it was 1.
- `POST /v1/attachments` parses multipart, and requires `file`, `itemType`, `itemId`.

Assertions (in `test/drive.py`), beyond "it prints the right rows":

- 23 tools advertised, and the write set is exactly the four named write tools.
- No tool schema has a `method`/`verb` parameter; `Gorelo::Client` has no `delete` method
  (checked with `ruby -e`).
- Draft invoice: refused without the flag, refused without `confirm`, `StatusId == 1` on
  the wire, duplicate refused, read-back reports Draft.
- Maintenance: `minutes: 0` without `indefinite` is refused; `Reason` carries the
  attribution prefix; `end` sends `{Enabled: false}` only.
- Attachments: a path outside `GORELO_ATTACH_DIR`, a `..` path, a symlink pointing out, and
  a > 44 MB file are all refused **before any request**; a good file is uploaded, then
  referenced in the comment's `Attachments`.
- PDF lands in the download dir with the display-number filename.

After the suite passes, a single read-only smoke run against the live tenant for each read
tool, as for part A. No live write is made without asking first.

## Documentation

README: tool table and count, the write-tool section (three guards per new write, and why
`StatusId` and `indefinite` are fixed/explicit), the attachment-directory guard and the
threat it closes, the PDF export-event side effect, and the 25 September section updated
from "not used yet" to what is now used.
