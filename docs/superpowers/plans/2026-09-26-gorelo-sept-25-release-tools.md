# Gorelo 25 September 2026 release tools — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 5 read tools (invoices, invoice PDF, contract detail, item catalogue, uptime) and 2 guarded write tools (uptime maintenance, Draft-only invoices), and let `gorelo_add_ticket_comment` attach files — without adding any way to DELETE.

**Architecture:** New tools live in two new `module_function` modules, `lib/gorelo_billing_tools.rb` and `lib/gorelo_uptime_tools.rb`, registered from `gorelo-mcp-server.rb` next to `GoreloTools`. They borrow the existing formatting helpers by delegating to `GoreloTools`. `Gorelo::Client` (`lib/gorelo.rb`) gains `get_binary` and `post_multipart`, a few cached lookups, and a rule that a POST is never retried after a 5xx. It still has no `delete` method.

**Tech Stack:** Ruby 3.4 stdlib only (no gems). Tests: `test/mock_gorelo.py` (a fake Gorelo API, Python 3 stdlib) and `test/drive.py` (drives the real server over JSON-RPC stdio and asserts on tool output).

**Spec:** `docs/superpowers/specs/2026-09-26-gorelo-sept-25-release-tools-design.md`

## Global Constraints

- No gems, no Bundler. Ruby stdlib only; Python stdlib only in `test/`.
- `Gorelo::Client` must never gain a method whose name contains `delete`. No tool may take an HTTP method/verb parameter.
- Every write tool: refused unless `GORELO_ALLOW_WRITES=true` (`api.writes_allowed?`), refused unless `confirm == true`, declared with `read_only: false`, read back after writing, and reports a failed read-back loudly.
- `gorelo_create_draft_invoice` always sends `StatusId: 1` and never sends `RecipientEmails`, `UnitCost`, `TaxId`, `CoaCode`, `BillableStatusId` or `DiscountPercent`.
- `gorelo_set_uptime_maintenance` sends only `MaintenanceMode`. `DurationInMinutes: 0` only with `indefinite: true`. Minutes 1–10080. Reason prefixed `[Gorelo MCP] `.
- Attachments only from `GORELO_ATTACH_DIR` (default `~/gorelo-attachments`), resolved with `File.realpath` before the containment check, max 44 MB (46,137,344 bytes), all checked before any upload.
- PDFs saved to `GORELO_DOWNLOAD_DIR` (default `~/gorelo-invoices`); the server-supplied filename never chooses the directory.
- Prose output, not JSON. State counts; never drop rows silently; name flagged items.
- Speak both contract vocabularies wherever a contract appears: API "contract" = UI "Contract Group", API "ServiceLine" = UI "Contract".
- **Run the suite** (a fresh mock every run, so its in-memory state is clean):
  `bash -c 'python3 test/mock_gorelo.py 2>/dev/null & M=$!; sleep 1; python3 test/drive.py; S=$?; kill $M; exit $S'`
  The last line is `N passed, M failed`. Run from the repo root.
- **Commit** with the repo's existing identity (git has none configured here), ending the message with the attribution line:
  `git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "…" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`
- Work on branch `gorelo-2026-09-25` (it exists; part A is already committed there).

## Deviations from the spec (decided while planning)

- New modules are registered in `gorelo-mcp-server.rb`, not from inside `GoreloTools.register` — that avoids a circular `require_relative`.
- `gorelo_get_contract` does not call `/v1/taxes`: each contract line item already carries `Tax.Name`. `/v1/taxes` is used only by `gorelo_list_items`.
- "Overdue" means **Approved**, past due and still owing. A Draft has not been issued, so it is never overdue (the spec said "not Void").
- `find_item` takes `active_only:` — invoices accept only active items; the catalogue detail view can show an archived one.

## Review Focus

1. **A POST that gets a 5xx after Gorelo applied it** → must not be retried (a retry raises a second invoice or comment); the reply must say it *may* exist and a repeat must be refused. Pinned in Task 7.
2. **A hostile `Content-Disposition` filename** such as `../../evil.pdf` → saved inside the download folder as `evil.pdf`, never outside it. Pinned in Task 2.
3. **A subcategory id that also exists under another category** → labelled with the subcategory from its *own* category. Pinned in Task 4.
4. **`..`, `~`, absolute paths and symlinks passed as attachments** → all refused before any upload. Pinned in Task 8.
5. **A name fragment that matches several records** (client, contract, uptime check, item) → refused with the candidates, never resolved to the first match. Pinned in Tasks 3, 4, 6 and 7.

---

### Task 1: `gorelo_list_invoices`, the billing-tools module, and the no-DELETE guards

**Files:**
- Create: `lib/gorelo_billing_tools.rb`
- Modify: `gorelo-mcp-server.rb` (requires + registration)
- Modify: `test/mock_gorelo.py` (generic last-query recorder, filter helpers, invoice fixtures, `GET /v1/invoices`)
- Modify: `test/drive.py` (`last_query`, tool count, structural checks, invoice checks)

**Interfaces:**
- Consumes: `GoreloTools.pad/clip/nested`, `api.get_all(path, query)`, `api.resolve_clients(term)`, `api.client_name(id)`.
- Produces: `module GoreloBillingTools` with `register(server, api)`, delegators `pad(...)`, `clip(...)`, `nested(...)`, `money(value) -> String`, constants `INVOICE_STATUS` (`{'draft'=>1,'paid'=>3,'void'=>4,'approved'=>5}`), `STATUS_DRAFT = 1`, `STATUS_APPROVED = 5`. Mock: `LAST_QUERY` dict, `q_ids(q, name)`, `q_instant(q, name)`, `page_too_big(q)`, `day(d)`, `INVOICES`, `INVOICE_STATUS_NAMES`, route `/__debug/last-query?path=`. Drive: `last_query(path) -> dict`.

- [ ] **Step 1: Mock — replace the time-entries-only query recorder with a general one**

In `test/mock_gorelo.py`, replace:

```python
# The query string /v1/time-entries last received, for asserting which
# parameter names a tool actually sends.
LAST_TE_QUERY = {}
```

with:

```python
# The query string each GET path last received, for asserting which parameter
# names a tool actually sends. Read it at /__debug/last-query?path=<path>.
LAST_QUERY = {}
```

In `do_GET`, replace:

```python
        if urlparse(self.path).path == "/__debug/time-entries-query":
            return self.reply(200, LAST_TE_QUERY)
        if not self.authorised():
            return
        u = urlparse(self.path)
        path, q = u.path, parse_qs(u.query)
```

with:

```python
        d = urlparse(self.path)
        if d.path.startswith("/__debug/"):
            want = parse_qs(d.query).get("path", [""])[0]
            if d.path == "/__debug/last-query":
                return self.reply(200, LAST_QUERY.get(want, {}))
            return self.reply(404, fail(404, "No debug route %s" % d.path))
        if not self.authorised():
            return
        u = urlparse(self.path)
        path, q = u.path, parse_qs(u.query)
        LAST_QUERY[path] = {k: v[0] for k, v in q.items()}
```

In the `/v1/time-entries` branch, delete these two lines:

```python
            LAST_TE_QUERY.clear()
            LAST_TE_QUERY.update({k: v[0] for k, v in q.items()})
```

- [ ] **Step 2: Mock — shared filter helpers**

Insert immediately above `class Handler(BaseHTTPRequestHandler):`:

```python
def q_ids(q, name):
    """A comma-separated id filter as a set of strings, or None when absent."""
    raw = q.get(name, [None])[0]
    return {x for x in raw.split(",") if x} if raw else None


def q_instant(q, name):
    """An ISO-8601 query value as an aware UTC datetime, or None."""
    raw = q.get(name, [None])[0]
    if not raw:
        return None
    t = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def page_too_big(q):
    """The 25 Sept endpoints REJECT PageSize outside 1-200 rather than clamp it."""
    return not 1 <= int(q.get("PageSize", ["50"])[0]) <= 200
```

- [ ] **Step 3: Mock — invoice fixtures**

Insert immediately above the line `POSTED = []`:

```python
# --- invoices (Gorelo, 25 Sep 2026) ---------------------------------------
def day(d):
    """A calendar date d days ago (negative for the future), as the API sends it."""
    return (NOW - timedelta(days=d)).date().isoformat()


INVOICE_STATUS_NAMES = {1: "Draft", 3: "Paid", 4: "Void", 5: "Approved"}


def invoice(n, client, status, date_ago, due_ago, total, paid, emailed, contract=None):
    tax = round(total / 11, 2)
    return {"Id": "1a000000-0000-4000-8000-%012d" % n, "Number": n,
            "DisplayNumber": "INV-%04d" % n, "ClientId": client, "ContractId": contract,
            "Status": {"Id": status, "Name": INVOICE_STATUS_NAMES[status]},
            "InvoiceDate": day(date_ago), "DueDate": day(due_ago),
            "SubTotal": round(total - tax, 2), "TotalDiscount": 0.0, "TotalTax": tax,
            "Total": total, "AmountPaid": paid, "AmountDue": max(0.0, round(total - paid, 2)),
            "Reference": None, "ExternalId": None, "PaymentLink": None,
            "InvoiceTemplateId": None, "InvoiceEmailTemplateId": None,
            "BrandingThemeId": None, "IsEmailSent": emailed,
            "EmailSentOn": ago(date_ago) if emailed else None,
            "CreatedOn": ago(date_ago), "UpdatedOn": None}


INVOICES = [
    invoice(901, 11001, 3, 200, 186, 5335.00, 5335.00, True, 5001),  # outside a 90-day window
    invoice(1041, 11001, 3, 40, 26, 5335.00, 5335.00, True, 5001),
    invoice(1042, 11001, 5, 24, 10, 5335.00, 0.00, True, 5001),      # OVERDUE
    invoice(1043, 11002, 5, 5, -9, 1419.00, 0.00, False, 5002),      # approved, never emailed
    invoice(1044, 11003, 1, 30, 20, 990.00, 0.00, False),            # draft past its due date: NOT overdue
    invoice(1045, 11004, 4, 12, -2, 13200.00, 0.00, True, 5004),     # void
]
```

- [ ] **Step 4: Mock — `GET /v1/invoices`**

In `do_GET`, insert immediately above `if path == "/v1/time-entries/statuses":`:

```python
        if path == "/v1/invoices":
            if page_too_big(q):
                return self.reply(400, fail(400, "PageSize must be 1-200"))
            rows = INVOICES
            for name, key in (("ClientIds", lambda i: i["ClientId"]),
                              ("StatusIds", lambda i: i["Status"]["Id"]),
                              ("ContractIds", lambda i: i["ContractId"])):
                want = q_ids(q, name)
                if want is not None:
                    rows = [i for i in rows if str(key(i)) in want]
            if q.get("Number"):
                rows = [i for i in rows if str(i["Number"]) == q["Number"][0]]
            if q.get("InvoiceDateSince"):
                rows = [i for i in rows if i["InvoiceDate"] >= q["InvoiceDateSince"][0][:10]]
            if q.get("IsEmailSent"):
                rows = [i for i in rows if i["IsEmailSent"] == (q["IsEmailSent"][0] == "true")]
            since = q_instant(q, "CreatedSince")
            if since:
                rows = [i for i in rows if q_instant({"t": [i["CreatedOn"]]}, "t") >= since]
            text = q.get("Query", [""])[0].lower()
            if text:
                rows = [i for i in rows
                        if text in (i["DisplayNumber"] + " " + (i["Reference"] or "")).lower()]
            rows = sorted(rows, key=lambda i: i["InvoiceDate"], reverse=True)
            rows, pag = paginate(rows, q)
            return self.reply(200, env(rows, pag))
```

- [ ] **Step 5: Drive — helpers, tool count, structural guards, invoice checks**

In `test/drive.py`, add `import urllib.parse` beside `import urllib.request`, and replace the `te_query` function with:

```python
def last_query(path):
    """The query string the mock last received for a GET on `path`."""
    url = ENV["GORELO_BASE_URL"] + "/__debug/last-query?" + urllib.parse.urlencode({"path": path})
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def te_query():
    return last_query("/v1/time-entries")
```

Replace `check("16 tools advertised", len(tools) == 16, names)` with:

```python
    check("17 tools advertised", len(tools) == 17, names)
    # There is deliberately no way to DELETE from this server. The strongest
    # form of that is structural: the client has no such method to call.
    lib = os.path.abspath(os.path.join(HERE, "..", "lib", "gorelo.rb"))
    rc = subprocess.run(["ruby", "-e",
                         "require ARGV[0]; m = Gorelo::Client.instance_methods(false) + "
                         "Gorelo::Client.private_instance_methods(false); "
                         "exit(m.grep(/delete/).empty? ? 0 : 1)", lib]).returncode
    check("Gorelo::Client has no delete method at all", rc == 0, rc)
    check("no tool takes an HTTP method or verb",
          not any(k in ("method", "verb", "http_method")
                  for t in tools for k in t["inputSchema"].get("properties", {})))
```

Insert immediately above `print("\nresponse times")`:

```python
    print("\ninvoices (Gorelo, 25 Sep 2026)")
    inv = s.call("gorelo_list_invoices")
    check("the default window is 90 days of invoice dates, sent to the API",
          "INV-1042" in inv and "INV-0901" not in inv
          and "InvoiceDateSince" in last_query("/v1/invoices"), inv[:600])
    check("totals are broken down by status",
          "Approved" in inv and "Void" in inv and "still due" in inv, inv[:600])
    unsent = inv.split("APPROVED BUT NEVER EMAILED")[1].split("⚠ OVERDUE")[0] \
        if "APPROVED BUT NEVER EMAILED" in inv else ""
    check("approved-but-never-emailed invoices are named",
          "INV-1043" in unsent and "INV-1042" not in unsent, inv[-900:])
    over = inv.split("⚠ OVERDUE")[1] if "⚠ OVERDUE" in inv else ""
    check("overdue means approved, past due and still owing - never a draft",
          "INV-1042" in over and "INV-1044" not in over and "INV-1043" not in over, inv[-900:])
    drafts = s.call("gorelo_list_invoices", status="draft")
    check("a status filter is sent as StatusIds",
          "INV-1044" in drafts and "INV-1042" not in drafts
          and last_query("/v1/invoices").get("StatusIds") == "1", drafts[:400])
    old = s.call("gorelo_list_invoices", number="INV-0901")
    check("a number finds an invoice outside the window",
          "INV-0901" in old and "InvoiceDateSince" not in last_query("/v1/invoices"), old[:400])
    ce = s.call("gorelo_list_invoices", client="Contoso")
    check("a client filter is sent as ClientIds",
          "INV-1043" in ce and "INV-1042" not in ce
          and last_query("/v1/invoices").get("ClientIds") == "11002", ce[:400])
    check("no match says so", "No invoices" in s.call("gorelo_list_invoices", number="INV-7777"))
```

- [ ] **Step 6: Run the suite — verify it fails**

Run the suite command from Global Constraints.
Expected: existing checks pass; FAIL on `17 tools advertised` and every check under `invoices (Gorelo, 25 Sep 2026)` (the tool doesn't exist, so `s.call` returns "Unknown tool"). `Gorelo::Client has no delete method at all` and `no tool takes an HTTP method or verb` PASS.

- [ ] **Step 7: Create `lib/gorelo_billing_tools.rb`**

```ruby
# frozen_string_literal: true

# Tools for Gorelo's 25 September 2026 billing surface: invoices, the item
# catalogue and full contract detail. Same principles as gorelo_tools.rb -
# prose rather than JSON, and nothing filtered out silently - and the same
# formatting helpers, borrowed from GoreloTools rather than copied.

require 'time'
require 'date'
require 'fileutils'
require_relative 'gorelo'
require_relative 'gorelo_tools'

module GoreloBillingTools
  module_function

  def pad(...)    = GoreloTools.pad(...)
  def clip(...)   = GoreloTools.clip(...)
  def nested(...) = GoreloTools.nested(...)

  def money(value) = format('%.2f', value.to_f)

  # Invoice status ids, from the GET /v1/invoices parameter documentation.
  # There is no status 2.
  INVOICE_STATUS  = { 'draft' => 1, 'paid' => 3, 'void' => 4, 'approved' => 5 }.freeze
  STATUS_DRAFT    = 1
  STATUS_APPROVED = 5
  FLAG_LIST_MAX   = 25

  def register(server, api)
    list_invoices(server, api)
  end

  # ---- invoices -----------------------------------------------------------

  def list_invoices(server, api)
    server.tool(
      name:  'gorelo_list_invoices',
      title: 'List Gorelo invoices',
      description: <<~TEXT,
        Invoices with client, status, dates, total and the amount still due, over a window of
        invoice dates (default 90 days).

        Two lists are called out by name rather than left inside a total:
          - APPROVED BUT NEVER EMAILED - pushed to accounting, never sent to the client
          - OVERDUE - approved, past its due date, with money still owing
        A Draft has not been issued, so it is never counted as overdue.

        Every filter is one Gorelo documents, so the filtering happens in the API.
        Statuses: Draft, Approved, Paid, Void.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          client:   { type: 'string', description: 'Client name fragment or id. Comma-separate several.' },
          status:   { type: 'string', enum: %w[all draft approved paid void], description: 'Default "all".' },
          contract: { type: 'integer', description: 'Contract group id (an API "contract") the invoices were raised from.' },
          days:     { type: 'integer', description: 'Window on invoice date, in days. Default 90. Ignored when number is given.' },
          emailed:  { type: 'boolean', description: 'true: only invoices emailed to the client. false: only ones never emailed.' },
          number:   { type: 'string', description: 'One invoice by number, e.g. INV-1042 or 1042.' },
          limit:    { type: 'integer', description: 'Rows to print. Default 50. Totals always cover every match.' }
        },
        additionalProperties: false
      }
    ) do |args|
      limit = (args['limit'] || 50).to_i.clamp(1, 500)
      query = { 'SortBy' => 'date', 'SortOrder' => 'desc' }
      scope = []

      if args['number'] && !args['number'].to_s.strip.empty?
        num = args['number'].to_s.strip.sub(/\AINV-?/i, '')
        next "#{args['number'].inspect} is not an invoice number." unless num.match?(/\A\d+\z/)

        query['Number'] = num.to_i
        scope << "number #{num.to_i}"
      else
        days = (args['days'] || 90).to_i.clamp(1, 3650)
        query['InvoiceDateSince'] = (Date.today - days).iso8601
        scope << "invoice date in the last #{days}d"
      end

      if args['client'] && !args['client'].to_s.strip.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?

        query['ClientIds'] = matched.map { |c| c['Id'] }.join(',')
        scope << "client=#{matched.map { |c| c['Name'] }.first(3).join(' + ')}"
      end

      status = (args['status'] || 'all').to_s.downcase
      if INVOICE_STATUS.key?(status)
        query['StatusIds'] = INVOICE_STATUS[status]
        scope << status
      end

      if args['contract']
        query['ContractIds'] = args['contract'].to_i
        scope << "contract group #{args['contract'].to_i}"
      end

      unless args['emailed'].nil?
        query['IsEmailSent'] = args['emailed'] ? 'true' : 'false'
        scope << (args['emailed'] ? 'emailed' : 'never emailed')
      end

      rows = api.get_all('/v1/invoices', query)
      next "No invoices - #{scope.join(', ')}." if rows.empty?

      today    = Date.today
      due_on   = ->(i) { Date.iso8601(i['DueDate'].to_s[0, 10]) rescue nil }
      approved = ->(i) { nested(i, 'Status', 'Id') == STATUS_APPROVED }
      unsent   = rows.select { |i| approved.call(i) && i['IsEmailSent'] != true }
      overdue  = rows.select do |i|
        d = due_on.call(i)
        approved.call(i) && i['AmountDue'].to_f.positive? && d && d < today
      end
      client   = ->(i) { api.client_name(i['ClientId']) || "client #{i['ClientId']}" }

      out = ["#{rows.size} invoice(s) - #{scope.join(', ')}."]
      rows.group_by { |i| nested(i, 'Status', 'Name') || '(no status)' }.each do |name, group|
        out << format('  %-10s %4d   total %12s   still due %12s', name, group.size,
                      money(group.sum { |i| i['Total'].to_f }),
                      money(group.sum { |i| i['AmountDue'].to_f }))
      end
      out << ''
      out << "#{pad('Invoice', 11)}#{pad('Client', 26)}#{pad('Status', 10)}#{pad('Date', 11)}" \
             "#{pad('Due', 11)}#{'Total'.rjust(12)}#{'Still due'.rjust(12)}  Emailed"
      out << ('-' * 108)
      rows.first(limit).each do |i|
        out << "#{pad(i['DisplayNumber'], 11)}#{pad(client.call(i), 26)}" \
               "#{pad(nested(i, 'Status', 'Name'), 10)}#{pad(i['InvoiceDate'].to_s[0, 10], 11)}" \
               "#{pad(i['DueDate'].to_s[0, 10], 11)}#{money(i['Total']).rjust(12)}" \
               "#{money(i['AmountDue']).rjust(12)}  #{i['IsEmailSent'] ? 'yes' : 'NO'}"
      end
      out << "#{rows.size - limit} more not shown - raise limit." if rows.size > limit

      if unsent.any?
        out << ''
        out << "⚠ APPROVED BUT NEVER EMAILED - #{unsent.size}. Pushed to accounting, never sent to the client:"
        unsent.first(FLAG_LIST_MAX).each do |i|
          out << "  #{pad(i['DisplayNumber'], 11)}#{pad(client.call(i), 26)}#{money(i['Total']).rjust(12)}"
        end
        out << "  … #{unsent.size - FLAG_LIST_MAX} more" if unsent.size > FLAG_LIST_MAX
      end

      if overdue.any?
        out << ''
        out << "⚠ OVERDUE - #{overdue.size}, #{money(overdue.sum { |i| i['AmountDue'].to_f })} still due:"
        overdue.sort_by { |i| due_on.call(i) }.first(FLAG_LIST_MAX).each do |i|
          out << "  #{pad(i['DisplayNumber'], 11)}#{pad(client.call(i), 26)}" \
                 "due #{i['DueDate'].to_s[0, 10]} (#{(today - due_on.call(i)).to_i}d ago)" \
                 "#{money(i['AmountDue']).rjust(12)}"
        end
        out << "  … #{overdue.size - FLAG_LIST_MAX} more" if overdue.size > FLAG_LIST_MAX
      end
      out.join("\n")
    end
  end
end
```

- [ ] **Step 8: Register the module**

In `gorelo-mcp-server.rb`, after `require_relative 'lib/gorelo_tools'` add:

```ruby
require_relative 'lib/gorelo_billing_tools'
```

and replace `GoreloTools.register(server, api)` with:

```ruby
GoreloTools.register(server, api)
GoreloBillingTools.register(server, api)
```

- [ ] **Step 9: Run the suite — verify it passes**

Run the suite command. Expected: `… passed, 0 failed`.

- [ ] **Step 10: Commit**

```bash
git add lib/gorelo_billing_tools.rb gorelo-mcp-server.rb test/mock_gorelo.py test/drive.py
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Add gorelo_list_invoices; assert structurally that nothing can DELETE" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `gorelo_get_invoice_pdf` and `Client#get_binary`

**Files:**
- Modify: `lib/gorelo.rb` (`get_binary`, `request`, `handle`)
- Modify: `lib/gorelo_billing_tools.rb` (`GUID`, `download_dir`, `find_invoice`, `get_invoice_pdf`, register)
- Modify: `test/mock_gorelo.py` (PDF route), `test/drive.py` (download dir env, checks)

**Interfaces:**
- Consumes: Task 1's module, `INVOICES`.
- Produces: `api.get_binary(path, query = {}) -> {'Body' => String(binary), 'ContentType' => String, 'Filename' => String|nil}`; `request(klass, path, query:, body:, raw:)`; `handle(res, uri, raw: false)`; `GoreloBillingTools::GUID`; `find_invoice(api, ref) -> [row|nil, why|nil]`; `download_dir -> String`.

- [ ] **Step 1: Mock — PDF route**

In `do_GET`, insert immediately above `if path == "/v1/invoices":`:

```python
        m = re.fullmatch(r"/v1/invoices/([^/]+)/pdf", path)
        if m:
            hit = next((i for i in INVOICES if i["Id"] == m.group(1)), None)
            if not hit:
                return self.reply(404, fail(404, "Invoice not found"))
            # Void INV-1045 carries a hostile filename, to prove the server never
            # lets Content-Disposition choose the directory.
            name = "../../evil.pdf" if hit["Number"] == 1045 else hit["DisplayNumber"] + ".pdf"
            body = b"%PDF-1.4\n% fake invoice " + hit["DisplayNumber"].encode() + b"\n%%EOF\n"
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
```

- [ ] **Step 2: Drive — download dir and checks**

In the `ENV.update({...})` block add:

```python
    "GORELO_DOWNLOAD_DIR": os.path.join(HERE, "_tmp_home", "downloads"),
```

After `os.makedirs(ENV["HOME"], exist_ok=True)` add:

```python
import shutil
shutil.rmtree(ENV["GORELO_DOWNLOAD_DIR"], ignore_errors=True)
```

Replace `check("17 tools advertised", len(tools) == 17, names)` with `check("18 tools advertised", len(tools) == 18, names)`.

Insert immediately above `print("\nresponse times")`:

```python
    print("\ninvoice PDF")
    dl = ENV["GORELO_DOWNLOAD_DIR"]
    pdf = s.call("gorelo_get_invoice_pdf", invoice="INV-1042")
    saved = os.path.join(dl, "INV-1042.pdf")
    check("the PDF is saved under its display number",
          "Saved INV-1042" in pdf and os.path.isfile(saved)
          and open(saved, "rb").read(5) == b"%PDF-", pdf)
    check("the export-event side effect is stated", "export event" in pdf, pdf)
    evil = s.call("gorelo_get_invoice_pdf", invoice="INV-1045")
    check("a server-supplied filename cannot choose the directory",
          os.path.isfile(os.path.join(dl, "evil.pdf"))
          and not os.path.exists(os.path.join(HERE, "evil.pdf"))
          and not os.path.exists(os.path.join(ENV["HOME"], "evil.pdf")), evil)
    check("an unknown number is named",
          "No invoice numbered" in s.call("gorelo_get_invoice_pdf", invoice="INV-7777"))
    gone = s.call("gorelo_get_invoice_pdf", invoice="00000000-0000-4000-8000-000000000000")
    check("an unknown id surfaces Gorelo's 404, not an empty file", "404" in gone, gone)
```

- [ ] **Step 3: Run the suite — verify it fails**

Expected: FAIL on `18 tools advertised` and every `invoice PDF` check.

- [ ] **Step 4: Client — `get_binary`**

In `lib/gorelo.rb`, add below `def get(path, query = {})`'s method:

```ruby
    # A file download. Its ERRORS still arrive as the JSON envelope; its
    # success is the file itself. Returns Body (binary), ContentType, Filename.
    def get_binary(path, query = {})
      request(Net::HTTP::Get, path, query: query, raw: true)
    end
```

Change `def request(klass, path, query: {}, body: nil)` to `def request(klass, path, query: {}, body: nil, raw: false)`, replace `req['Accept']       = 'application/json'` with:

```ruby
      req['Accept']       = raw ? 'application/pdf, application/json' : 'application/json'
```

and replace `with_retry(path) { handle(http.request(req), uri) }` with:

```ruby
      with_retry(path) { handle(http.request(req), uri, raw: raw) }
```

Change `def handle(res, uri)` to `def handle(res, uri, raw: false)`, and insert immediately after the `if [401, 403].include?(code) … end` block:

```ruby
      # A file download succeeds with the file itself - only its errors use the
      # envelope - so a 2xx that isn't JSON is the answer, not a fault.
      if raw && code.between?(200, 299) && !res['Content-Type'].to_s.include?('json')
        return { 'Body'        => res.body.to_s.b,
                 'ContentType' => res['Content-Type'].to_s,
                 'Filename'    => res['Content-Disposition'].to_s[/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i, 1] }
      end
```

At the end of `handle`, replace the final `parsed` line with:

```ruby
      raise Error, "Gorelo returned JSON where #{uri.path} should return a file." if raw

      parsed
```

- [ ] **Step 5: Tool — `gorelo_get_invoice_pdf`**

In `lib/gorelo_billing_tools.rb`, add below `FLAG_LIST_MAX   = 25`:

```ruby
  GUID = Gorelo::Client::GUID
```

Add `get_invoice_pdf(server, api)` to `register`, and add these methods after `list_invoices`:

```ruby
  # Where PDFs land. Under WSL this is a Linux path; Windows reaches it as
  # \\wsl$\<distro>\<path>.
  def download_dir = File.expand_path(ENV['GORELO_DOWNLOAD_DIR'] || '~/gorelo-invoices')

  # "INV-1042", "1042" or an invoice UUID -> [row, nil] or [nil, why]. A number
  # costs one filtered request; a UUID costs none (the row then holds only Id).
  def find_invoice(api, ref)
    ref = ref.to_s.strip
    return [{ 'Id' => ref }, nil] if ref.match?(GUID)

    num = ref.sub(/\AINV-?/i, '')
    return [nil, "#{ref.inspect} is not an invoice number or id."] unless num.match?(/\A\d+\z/)

    row = Array(api.get('/v1/invoices', { 'Number' => num.to_i })['Data']).first
    row ? [row, nil] : [nil, "No invoice numbered #{num.to_i}."]
  end

  def get_invoice_pdf(server, api)
    server.tool(
      name:  'gorelo_get_invoice_pdf',
      title: 'Download a Gorelo invoice as PDF',
      description: <<~TEXT,
        Saves an invoice's PDF to a folder on the machine running this server and returns the
        path. The file itself never passes through the conversation.

        Gorelo renders the PDF on demand from the invoice's CURRENT data, and RECORDS EACH
        DOWNLOAD AGAINST THE INVOICE AS AN EXPORT EVENT - so this read leaves a visible trace
        in Gorelo. Don't download an invoice just to read its figures; gorelo_list_invoices
        has them.

        Folder: GORELO_DOWNLOAD_DIR, default ~/gorelo-invoices. A file of the same name is
        replaced.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          invoice: { type: 'string', description: 'Invoice number (INV-1042 or 1042) or invoice id.' }
        },
        required: ['invoice'],
        additionalProperties: false
      }
    ) do |args|
      row, why = find_invoice(api, args['invoice'])
      next why unless row

      file = api.get_binary("/v1/invoices/#{row['Id']}/pdf")
      body = file['Body']
      unless body.start_with?('%PDF-')
        next "Gorelo answered with #{file['ContentType']}, but the body is not a PDF. Nothing was saved."
      end

      # The server suggests a name; it never chooses the directory.
      name = File.basename(file['Filename'].to_s.tr('\\', '/'))
      name = "#{row['DisplayNumber'] || row['Id']}.pdf" if name.empty? || name.start_with?('.')
      name = name.gsub(/[^\w.\-]/, '_')
      name += '.pdf' unless name.downcase.end_with?('.pdf')

      FileUtils.mkdir_p(download_dir)
      path     = File.join(download_dir, name)
      replaced = File.exist?(path)
      File.binwrite(path, body)

      out = ["Saved #{row['DisplayNumber'] || row['Id']} to #{path} (#{body.bytesize} bytes)" \
             "#{replaced ? ', replacing an earlier copy' : ''}."]
      if row['ClientId']
        out << "#{api.client_name(row['ClientId'])} · #{nested(row, 'Status', 'Name')} · " \
               "total #{money(row['Total'])}"
      end
      out << 'Gorelo has recorded this download as an export event on the invoice.'
      out.join("\n")
    end
  end
```

- [ ] **Step 6: Run the suite — verify it passes**

Expected: `… passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add lib/gorelo.rb lib/gorelo_billing_tools.rb test/mock_gorelo.py test/drive.py
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Add gorelo_get_invoice_pdf; the server's filename never picks the folder" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `gorelo_get_contract`

**Files:**
- Modify: `lib/gorelo.rb` (cached `contracts`)
- Modify: `lib/gorelo_billing_tools.rb` (`find_contract`, `get_contract`, register)
- Modify: `test/mock_gorelo.py` (`TAXES`, contract detail fixtures, route), `test/drive.py`

**Interfaces:**
- Consumes: `money`, `pad`, `nested`, `api.client_name`.
- Produces: `api.contracts -> Array` (cached `get_all('/v1/contracts')`); `find_contract(api, ref) -> [id|nil, why|nil]`. Mock: `TAXES` (used again in Tasks 4 and 7), `CONTRACT_DETAILS`, `line_item(...)`.

- [ ] **Step 1: Mock — taxes and contract detail fixtures**

Insert immediately above `POSTED = []`:

```python
# --- taxes and contract detail (Gorelo, 25 Sep 2026) ----------------------
TAXES = [
    {"Id": 1, "Name": "GST on Income", "Code": "OUTPUT", "Percentage": 10.0,
     "IsDefault": True, "SubTaxes": []},
    {"Id": 2, "Name": "GST Free Income", "Code": "EXEMPTOUTPUT", "Percentage": 0.0,
     "IsDefault": False, "SubTaxes": []},
    # Components are what is charged; the parent's own Percentage is NOT added
    # on top. It is null here, so only reading the components gives a rate.
    {"Id": 3, "Name": "HST", "Code": "HST", "Percentage": None, "IsDefault": False,
     "SubTaxes": [{"Id": 31, "Name": "GST", "Code": "G", "Percentage": 5.0},
                  {"Id": 32, "Name": "PST", "Code": "P", "Percentage": 8.0}]},
]


def line_item(n, name, qty, price, cost, tax=None, billable=None):
    tax = tax or TAXES[0]
    return {"Id": n, "ItemId": None, "ItemType": {"Id": 1, "Name": "Product"},
            "Name": name, "Description": None, "Quantity": qty, "Cost": cost,
            "UnitPrice": price, "DiscountPercent": None, "StartDate": None, "EndDate": None,
            "Tax": {"Id": tax["Id"], "Name": tax["Name"]}, "Amount": round(qty * price, 2),
            "TaxAmount": None, "BillableStatus": billable or BILLABLE}


def contract_detail(c):
    d = {k: v for k, v in c.items() if k != "ClientId"}
    d["Client"] = {"Id": c["ClientId"],
                   "Name": next(x["Name"] for x in CLIENTS if x["Id"] == c["ClientId"])}
    d.update({"IsForAllLocations": True, "DaysBeforeInvoiceCreation": 7, "InvoiceDue": 14,
              "AutoApproveAndSend": False, "Contacts": []})
    d["ServiceLines"] = [dict(l, LaborTerms={"Id": 5, "Name": "No labor terms"},
                              WorkTypes=[], WorkRoles=[], UnlimitedHoursDetails=None,
                              PerHourDetails=None, LimitedHoursDetails=None,
                              BlockHoursDetails=None, RecurringAmount=0.0,
                              RecurringCost=0.0, LineItems=[])
                         for l in c["ServiceLines"]]
    return d


CONTRACT_DETAILS = {c["Id"]: contract_detail(c) for c in CONTRACTS}
# Northwind: invoices go out unreviewed, one block-hours line is under its
# warning threshold, and Backup Monitoring bills nothing. All three must flag.
_nw = CONTRACT_DETAILS[5001]
_nw["AutoApproveAndSend"] = True
_nw["Contacts"] = [{"Id": 100000, "Name": "Dana Ellis"}]
_desk, _srv, _bkp = _nw["ServiceLines"]
_desk.update(LaborTerms={"Id": 1, "Name": "Unlimited Hours"},
             UnlimitedHoursDetails={"AutoApprove": True},
             WorkTypes=[{"Id": WORK_TYPES[0]["Id"], "Name": WORK_TYPES[0]["Name"]}],
             RecurringAmount=3570.0, RecurringCost=1260.0,
             LineItems=[line_item(1, "Managed desktop seat", 42, 85.0, 30.0)])
_srv.update(LaborTerms={"Id": 3, "Name": "Block Hours"},
            BlockHoursDetails={"Balance": 3.5, "WarningThreshold": 5.0, "OverrunThreshold": 0.0},
            RecurringAmount=1280.0, RecurringCost=840.0,
            LineItems=[line_item(2, "Managed server", 4, 320.0, 210.0)])
```

- [ ] **Step 2: Mock — route**

In `do_GET`, insert immediately above `if path == "/v1/contracts":`:

```python
        m = re.fullmatch(r"/v1/contracts/(\d+)", path)
        if m:
            hit = CONTRACT_DETAILS.get(int(m.group(1)))
            if not hit:
                return self.reply(404, fail(404, "Contract not found"))
            return self.reply(200, env(hit))
```

- [ ] **Step 3: Drive — checks**

Change the tool count check to `19`. Insert immediately above `print("\nresponse times")`:

```python
    print("\ncontract detail")
    cd = s.call("gorelo_get_contract", contract="5001")
    check("both vocabularies are printed",
          'UI "Contract Group"' in cd and "(UI: contract)" in cd, cd[:400])
    check("line items are listed per service line",
          "Managed desktop seat" in cd and "3570.00" in cd, cd)
    check("automatic approve-and-send is flagged", "AUTO APPROVE AND SEND" in cd, cd[-900:])
    check("a block-hours balance at or under its warning threshold is flagged",
          "at or under its warning threshold" in cd, cd[-900:])
    check("a service line with no line items is flagged",
          "NO LINE ITEMS on service line 9003" in cd, cd[-900:])
    by_name = s.call("gorelo_get_contract", contract="contoso")
    check("a unique name fragment resolves", "Contract group 5002" in by_name, by_name[:200])
    amb = s.call("gorelo_get_contract", contract="a")
    check("an ambiguous fragment lists candidates instead of guessing",
          "Give the id" in amb and "Contract group" not in amb, amb)
    miss = s.call("gorelo_get_contract", contract="99999")
    check("an unknown id surfaces the 404", "404" in miss, miss)
```

- [ ] **Step 4: Run the suite — verify it fails**

Expected: FAIL on the tool count and every `contract detail` check.

- [ ] **Step 5: Client — cached contracts**

In `lib/gorelo.rb`, add directly after the `clients` method:

```ruby
    def contracts
      @cache[:contracts] ||= get_all('/v1/contracts')
    end
```

- [ ] **Step 6: Tool — `gorelo_get_contract`**

In `lib/gorelo_billing_tools.rb`, add `get_contract(server, api)` to `register`, and add after `get_invoice_pdf`:

```ruby
  # ---- contract detail ----------------------------------------------------

  # A contract group by numeric id, or by a name fragment that matches exactly
  # one. An ambiguous fragment is refused with the candidates.
  def find_contract(api, ref)
    ref = ref.to_s.strip
    return [nil, 'Give a contract group id or a fragment of its name.'] if ref.empty?
    return [ref.to_i, nil] if ref.match?(/\A\d+\z/)

    needle = ref.downcase
    hits = api.contracts.select { |c| c['Name'].to_s.downcase.include?(needle) }
    return [nil, "No contract group name contains #{ref.inspect} (#{api.contracts.size} exist)."] if hits.empty?
    if hits.size > 1
      return [nil, "#{hits.size} contract groups match #{ref.inspect}: " \
                   "#{hits.first(10).map { |c| "#{c['Id']} #{c['Name']}" }.join(', ')}. Give the id."]
    end

    [hits.first['Id'], nil]
  end

  def get_contract(server, api)
    server.tool(
      name:  'gorelo_get_contract',
      title: 'Show one Gorelo contract group in full',
      description: <<~TEXT,
        Everything about one contract group: client, term, invoice schedule, contacts,
        recurring amount/cost/margin, and each service line with its labour terms and the line
        items it actually bills.

        ⚠ THE TERMINOLOGY IS INVERTED. This is one /v1/contracts record, which Gorelo's web UI
        calls a CONTRACT GROUP. Each service line under it is what the UI calls a CONTRACT.

        Flagged: automatic approve-and-send (invoices go out with nobody reviewing them),
        block-hours balances at or under their warning threshold, and service lines with no
        line items.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          contract: { type: 'string', description: 'Contract group id, or a fragment of its name.' }
        },
        required: ['contract'],
        additionalProperties: false
      }
    ) do |args|
      id, why = find_contract(api, args['contract'])
      next why unless id

      c     = api.get("/v1/contracts/#{id}")['Data']
      flags = []
      term  = [c['StartDate'], c['EndDate']].map { |d| d.to_s[0, 10] }
      days  = c['DaysBeforeInvoiceCreation']

      out = ["Contract group #{c['Id']} - #{c['Name']}"]
      out << 'API "contract" = UI "Contract Group" (this record). ' \
             'API "ServiceLine" = UI "Contract" (each line below).'
      out << "Client: #{nested(c, 'Client', 'Name')} · #{nested(c, 'Status', 'Name')} · " \
             "#{nested(c, 'RepeatPeriod', 'Name')} · #{term[0].empty? ? '?' : term[0]} → " \
             "#{term[1].empty? ? 'open' : term[1]}" \
             "#{c['Reference'].to_s.strip.empty? ? '' : " · ref #{c['Reference']}"}"
      out << "Invoicing: created #{days.nil? ? '(not set)' : "#{days} day(s) before the period"} · " \
             "InvoiceDue setting #{c['InvoiceDue'].inspect} · " \
             "auto approve and send: #{c['AutoApproveAndSend'] ? 'YES' : 'no'}"
      contacts = Array(c['Contacts']).map { |x| x['Name'] }
      out << "Contacts: #{contacts.empty? ? '(none)' : contacts.join(', ')}"
      out << "Recurring: bills #{money(c['RecurringAmount'])} · cost #{money(c['RecurringCost'])} · " \
             "margin #{money(c['RecurringAmount'].to_f - c['RecurringCost'].to_f)} per period"
      if c['AutoApproveAndSend']
        flags << 'AUTO APPROVE AND SEND is on - invoices from this contract group are approved ' \
                 'and emailed with nobody reviewing them.'
      end

      lines = Array(c['ServiceLines'])
      flags << 'NO SERVICE LINES - an invoice container with nothing on it.' if lines.empty?
      lines.each do |l|
        detail = []
        detail << "auto-approve #{l.dig('UnlimitedHoursDetails', 'AutoApprove') ? 'yes' : 'no'}" if l['UnlimitedHoursDetails']
        %w[PerHourDetails LimitedHoursDetails].each do |k|
          rate = nested(l, k, 'RateType', 'Name')
          detail << "rate type #{rate}" if rate
        end
        if (b = l['BlockHoursDetails'])
          warn_at = b['WarningThreshold']
          detail << format('balance %.2fh · warn at %s · overrun at %s', b['Balance'].to_f,
                           warn_at.nil? ? '-' : format('%.2fh', warn_at),
                           b['OverrunThreshold'].nil? ? '-' : format('%.2fh', b['OverrunThreshold']))
          if !warn_at.nil? && b['Balance'].to_f <= warn_at.to_f
            flags << format('Block hours on "%s": balance %.2fh is at or under its warning threshold %.2fh.',
                            l['Name'], b['Balance'].to_f, warn_at.to_f)
          end
        end

        wt = Array(l['WorkTypes']).map { |x| x['Name'] }
        wr = Array(l['WorkRoles']).map { |x| x['Name'] }
        out << ''
        out << "↳ Service line #{l['Id']} - #{l['Name']}  (UI: contract)"
        out << "   Labour: #{([nested(l, 'LaborTerms', 'Name') || '(no labour terms)'] + detail).join(' · ')}"
        out << "   Work types: #{wt.empty? ? '(any)' : wt.join(', ')} · roles: #{wr.empty? ? '(any)' : wr.join(', ')}"
        out << "   Bills #{money(l['RecurringAmount'])} · cost #{money(l['RecurringCost'])} per period"

        items = Array(l['LineItems'])
        if items.empty?
          flags << "NO LINE ITEMS on service line #{l['Id']} \"#{l['Name']}\" - it bills nothing yet."
          next
        end
        out << "   #{'Qty'.rjust(7)}  #{pad('Item', 34)}#{'Unit'.rjust(10)}#{'Cost'.rjust(10)}" \
               "#{'Amount'.rjust(11)}  #{pad('Tax', 18)}Billable"
        items.each do |i|
          out << "   #{format('%7.2f', i['Quantity'].to_f)}  #{pad(i['Name'], 34)}" \
                 "#{money(i['UnitPrice']).rjust(10)}#{(i['Cost'].nil? ? '-' : money(i['Cost'])).rjust(10)}" \
                 "#{money(i['Amount']).rjust(11)}  #{pad(nested(i, 'Tax', 'Name'), 18)}" \
                 "#{nested(i, 'BillableStatus', 'Name')}"
        end
      end

      unless flags.empty?
        out << ''
        flags.each { |f| out << "⚠ #{f}" }
      end
      out.join("\n")
    end
  end
```

- [ ] **Step 7: Run the suite — verify it passes**

Expected: `… passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add lib/gorelo.rb lib/gorelo_billing_tools.rb test/mock_gorelo.py test/drive.py
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Add gorelo_get_contract: service lines, labour terms and line items" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `gorelo_list_items`

**Files:**
- Modify: `lib/gorelo.rb` (`taxes`, `tax_label`, `item_categories`, `category_label`)
- Modify: `lib/gorelo_billing_tools.rb` (`ITEM_TYPE`, `margin`, `find_item`, `item_detail`, `list_items`, register)
- Modify: `test/mock_gorelo.py` (categories, items, routes), `test/drive.py`

**Interfaces:**
- Consumes: `TAXES` (mock, Task 3), `money`, `pad`, `GUID`.
- Produces: `api.taxes`, `api.tax_label(tax_id) -> String|nil`, `api.item_categories`, `api.category_label(category_id, subcategory_id) -> String|nil`; `find_item(api, ref, active_only: false) -> [item_detail_hash|nil, why|nil]` (**used by Task 7**); `margin(price, cost) -> String`. Mock: `ITEMS`, `ITEM_SUBITEMS`, `ITEM_CATEGORIES`.

- [ ] **Step 1: Mock — catalogue fixtures**

Insert immediately above `POSTED = []`:

```python
# --- item catalogue (Gorelo, 25 Sep 2026) ---------------------------------
ITEM_CATEGORIES = [
    {"Id": 1, "Name": "Managed Services", "Description": None, "TaxId": 1,
     "Subcategories": [{"Id": 11, "Name": "Endpoints", "Description": None}]},
    {"Id": 2, "Name": "Licensing", "Description": None, "TaxId": 1,
     "Subcategories": [{"Id": 21, "Name": "Microsoft", "Description": None}]},
    # Subcategory ids are issued independently of category ids, so 11 names a
    # DIFFERENT subcategory here than under Managed Services.
    {"Id": 3, "Name": "Hardware", "Description": None, "TaxId": None,
     "Subcategories": [{"Id": 11, "Name": "Laptops", "Description": None}]},
]


def item(n, name, type_id, price, cost, cat=None, sub=None, sku=None, tax=1, status=1,
         client=None, vendor=None):
    return {"Id": "17e00000-0000-4000-8000-%012d" % n,
            "Type": {"Id": type_id, "Name": "Product" if type_id == 1 else "Bundle"},
            "Status": {"Id": status, "Name": "Active" if status == 1 else "Archived"},
            "Name": name, "Number": None, "Description": None, "CategoryId": cat,
            "SubcategoryId": sub, "ClientId": client, "LocationId": None, "Sku": sku,
            "PartNumber": None, "Manufacturer": None, "Vendor": vendor, "UnitCost": cost,
            "UnitPrice": price, "TaxId": tax, "ExternalProductId": None,
            "CreatedOn": ago(200), "UpdatedOn": None}


ITEMS = [
    item(1, "Managed desktop seat", 1, 85.00, 30.00, 1, 11, "MDS-01"),
    item(2, "Microsoft 365 Business Premium", 1, 36.30, 30.10, 2, 21, "M365-BP", vendor="Pax8"),
    item(3, "Dell Latitude 5450", 1, 1899.00, 1520.00, 3, 11, "LAT-5450"),
    item(4, "Legacy AV licence", 1, 5.00, 3.00, 2, None, "AV-OLD", status=2),
    item(5, "DR test day", 1, 1200.00, 1350.00, None, None, "DR-DAY", tax=3, client=11002),
    item(6, "New starter bundle", 2, 1900.00, 1550.10, 3, None, "NSB-01"),
]
ITEM_SUBITEMS = {ITEMS[5]["Id"]: [
    {"ItemId": ITEMS[2]["Id"], "Name": "Dell Latitude 5450", "Quantity": 1,
     "UnitCost": 1520.00, "UnitPrice": 1899.00},
    {"ItemId": ITEMS[1]["Id"], "Name": "Microsoft 365 Business Premium", "Quantity": 1,
     "UnitCost": 30.10, "UnitPrice": 36.30},
]}
```

- [ ] **Step 2: Mock — routes**

In `do_GET`, insert immediately above `if path == "/v1/time-entries/statuses":`:

```python
        if path == "/v1/taxes":
            return self.reply(200, env(TAXES))
        if path == "/v1/items/categories":
            return self.reply(200, env(ITEM_CATEGORIES))
        m = re.fullmatch(r"/v1/items/([^/]+)", path)
        if m:
            hit = next((i for i in ITEMS if i["Id"] == m.group(1)), None)
            if not hit:
                return self.reply(404, fail(404, "Item not found"))
            bundle = hit["Type"]["Id"] == 2
            d = dict(hit, SubItems=ITEM_SUBITEMS.get(hit["Id"], []) if bundle else None,
                     ShowSubItemsOnInvoice=True if bundle else None,
                     ShowSubItemDescriptionsOnInvoice=False if bundle else None)
            return self.reply(200, env(d))
        if path == "/v1/items":
            if page_too_big(q):
                return self.reply(400, fail(400, "PageSize must be 1-200"))
            rows = ITEMS
            for name, key in (("TypeIds", lambda i: i["Type"]["Id"]),
                              ("StatusIds", lambda i: i["Status"]["Id"]),
                              ("CategoryIds", lambda i: i["CategoryId"]),
                              ("ClientIds", lambda i: i["ClientId"])):
                want = q_ids(q, name)
                if want is not None:
                    rows = [i for i in rows if str(key(i)) in want]
            text = q.get("Query", [""])[0].lower()
            if text:
                rows = [i for i in rows
                        if text in (i["Name"] + " " + (i["Description"] or "")).lower()]
            rows, pag = paginate(rows, q)
            return self.reply(200, env(rows, pag))
```

- [ ] **Step 3: Drive — checks**

Change the tool count check to `20`. Insert immediately above `print("\nresponse times")`:

```python
    print("\nitem catalogue")
    it = s.call("gorelo_list_items")
    check("active items only by default, filtered in the API",
          "Legacy AV licence" not in it and "Managed desktop seat" in it
          and last_query("/v1/items").get("StatusIds") == "1", it[:600])
    lat = next((l for l in it.splitlines() if "Dell Latitude" in l), "")
    check("a subcategory is looked up inside its own category",
          "Hardware › Laptops" in lat and "Endpoints" not in lat, lat)
    dr = next((l for l in it.splitlines() if "DR test day" in l), "")
    check("a tax with components charges their sum", "HST 13%" in dr, dr)
    check("an item priced below cost is flagged",
          "SELLS BELOW COST" in it and "DR test day" in it.split("SELLS BELOW COST")[-1], it[-300:])
    bun = s.call("gorelo_list_items", type="bundle")
    check("a type filter is sent as TypeIds",
          "New starter bundle" in bun and "Managed desktop seat" not in bun
          and last_query("/v1/items").get("TypeIds") == "2", bun[:400])
    one = s.call("gorelo_list_items", item="new starter bundle")
    check("a bundle shows its parts and compares its price with them",
          "Bundle contents (2)" in one and "Sum of parts" in one and "BELOW its parts" in one, one)
    close = s.call("gorelo_list_items", item="Microsoft")
    check("a partial name is refused with candidates, never guessed",
          "is named exactly" in close and "Microsoft 365 Business Premium" in close, close)
    arch = s.call("gorelo_list_items", status="archived")
    check("archived items on request",
          "Legacy AV licence" in arch and "Managed desktop seat" not in arch, arch[:400])
```

- [ ] **Step 4: Run the suite — verify it fails**

Expected: FAIL on the tool count and every `item catalogue` check.

- [ ] **Step 5: Client — taxes and categories**

In `lib/gorelo.rb`, add after the `contracts` method:

```ruby
    def taxes
      @cache[:taxes] ||= Array(get('/v1/taxes')['Data'])
    end

    # "GST on Income 10%". A tax with SubTaxes charges the SUM of its
    # components, and its own Percentage is not applied on top (spec, /v1/taxes).
    def tax_label(tax_id)
      return nil if tax_id.nil?

      tax = taxes.find { |t| t['Id'].to_s == tax_id.to_s }
      return "tax #{tax_id}" unless tax

      subs = Array(tax['SubTaxes'])
      pct  = subs.empty? ? tax['Percentage'] : subs.sum { |s| s['Percentage'].to_f }
      pct.nil? ? tax['Name'] : "#{tax['Name']} #{format('%g', pct.to_f)}%"
    end

    def item_categories
      @cache[:item_categories] ||= Array(get('/v1/items/categories')['Data'])
    end

    # Subcategory ids are issued independently of category ids, and one number
    # can name a subcategory under two different categories - so a subcategory
    # is only ever looked up INSIDE its own category.
    def category_label(category_id, subcategory_id)
      return nil if category_id.nil?

      cat = item_categories.find { |c| c['Id'].to_s == category_id.to_s }
      return "category #{category_id}" unless cat

      sub = subcategory_id && Array(cat['Subcategories']).find { |s| s['Id'].to_s == subcategory_id.to_s }
      sub ? "#{cat['Name']} › #{sub['Name']}" : cat['Name']
    end
```

- [ ] **Step 6: Tool — `gorelo_list_items`**

In `lib/gorelo_billing_tools.rb`, add below `GUID = …`:

```ruby
  ITEM_TYPE   = { 'product' => 1, 'bundle' => 2 }.freeze
  ITEM_STATUS = { 'active' => 1, 'archived' => 2 }.freeze
```

Add `list_items(server, api)` to `register`, and add after `get_contract`:

```ruby
  # ---- item catalogue -----------------------------------------------------

  def margin(price, cost)
    return '-' if price.nil? || cost.nil? || price.to_f.zero?

    format('%d%%', (((price.to_f - cost.to_f) / price.to_f) * 100).round)
  end

  # An item by UUID, or by its EXACT name (case-insensitive). A partial or
  # repeated name is refused with the candidates: an invoice line must never
  # land on a guessed product. Returns the DETAIL record (with SubItems).
  def find_item(api, ref, active_only: false)
    ref  = ref.to_s.strip
    kind = active_only ? 'active item' : 'item'
    return [nil, 'Give an item id or its exact name.'] if ref.empty?

    if ref.match?(GUID)
      row = api.get("/v1/items/#{ref}")['Data']
      return [nil, "Item #{ref} (#{row['Name']}) is archived."] if active_only && nested(row, 'Status', 'Id') != 1

      return [row, nil]
    end

    query = { 'Query' => ref[0, 200] }
    query['StatusIds'] = ITEM_STATUS['active'] if active_only
    rows  = api.get_all('/v1/items', query)
    exact = rows.select { |i| i['Name'].to_s.strip.casecmp?(ref) }
    return [api.get("/v1/items/#{exact.first['Id']}")['Data'], nil] if exact.size == 1
    if exact.size > 1
      return [nil, "#{exact.size} #{kind}s are named exactly #{ref.inspect}: " \
                   "#{exact.map { |i| i['Id'] }.join(', ')}. Give the id."]
    end
    return [nil, "No #{kind} is named #{ref.inspect}."] if rows.empty?

    [nil, "No #{kind} is named exactly #{ref.inspect}. Close: " \
          "#{rows.first(8).map { |i| i['Name'] }.join(', ')}."]
  end

  def item_detail(api, ref)
    i, why = find_item(api, ref)
    return why unless i

    cost  = i['UnitCost'].nil? ? '-' : money(i['UnitCost'])
    price = i['UnitPrice'].nil? ? '-' : money(i['UnitPrice'])
    out = ["#{i['Name']}  (#{nested(i, 'Type', 'Name')}, #{nested(i, 'Status', 'Name')})  id #{i['Id']}"]
    out << "SKU #{i['Sku'] || '-'} · part #{i['PartNumber'] || '-'} · #{i['Manufacturer'] || '-'} · " \
           "vendor #{i['Vendor'] || '-'}"
    out << "Category: #{api.category_label(i['CategoryId'], i['SubcategoryId']) || '-'} · " \
           "tax #{api.tax_label(i['TaxId']) || '-'}"
    out << "Client: #{api.client_name(i['ClientId'])}" if i['ClientId']
    out << "Unit cost #{cost} · unit price #{price} · margin #{margin(i['UnitPrice'], i['UnitCost'])}"
    out << "Description: #{clip(i['Description'], 200)}" unless i['Description'].to_s.strip.empty?

    subs = i['SubItems']
    return out.join("\n") unless subs.is_a?(Array)

    part_cost  = subs.sum { |s| s['Quantity'].to_f * s['UnitCost'].to_f }
    part_price = subs.sum { |s| s['Quantity'].to_f * s['UnitPrice'].to_f }
    out << ''
    out << "Bundle contents (#{subs.size}):"
    subs.each do |s|
      out << "  #{format('%6.2f', s['Quantity'].to_f)} x #{pad(s['Name'], 34)}" \
             "cost #{money(s['UnitCost']).rjust(9)}   price #{money(s['UnitPrice']).rjust(9)}"
    end
    out << "Sum of parts: cost #{money(part_cost)} · price #{money(part_price)}. " \
           "Bundle: cost #{cost} (Gorelo derives it from the parts) · price #{price}."
    if !i['UnitPrice'].nil? && part_price.positive?
      diff = i['UnitPrice'].to_f - part_price
      out << if diff.negative?
               "The bundle sells #{money(-diff)} BELOW its parts bought separately."
             else
               "The bundle sells #{money(diff)} above its parts bought separately."
             end
    end
    out << "Sub-items on the invoice: #{i['ShowSubItemsOnInvoice'] ? 'shown' : 'hidden'}; " \
           "their descriptions: #{i['ShowSubItemDescriptionsOnInvoice'] ? 'shown' : 'hidden'}."
    out.join("\n")
  end

  def list_items(server, api)
    server.tool(
      name:  'gorelo_list_items',
      title: 'List the Gorelo product and bundle catalogue',
      description: <<~TEXT,
        The item catalogue: products and bundles with SKU, category, unit cost, unit price,
        margin and tax. Give `item` for one item in full - for a bundle, its component products
        and how the bundle's price compares with the sum of its parts.

        This is where to find the item an invoice line needs: gorelo_create_draft_invoice takes
        an item's id or exact name. Labour items are internal to contract pricing and never
        appear here. Default: active items only. Items priced below cost are flagged.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          query:    { type: 'string', description: 'Keyword matched against name and description.' },
          type:     { type: 'string', enum: %w[all product bundle], description: 'Default "all".' },
          category: { type: 'string', description: 'Category name fragment.' },
          client:   { type: 'string', description: 'Client name fragment or id: items specific to that client.' },
          status:   { type: 'string', enum: %w[active archived all], description: 'Default "active".' },
          item:     { type: 'string', description: 'One item by id or exact name, shown in full.' },
          limit:    { type: 'integer', description: 'Default 60.' }
        },
        additionalProperties: false
      }
    ) do |args|
      next item_detail(api, args['item']) unless args['item'].to_s.strip.empty?

      limit  = (args['limit'] || 60).to_i.clamp(1, 500)
      status = (args['status'] || 'active').to_s.downcase
      query  = { 'StatusIds' => ITEM_STATUS[status] }
      scope  = [status]

      type = args['type'].to_s.downcase
      if ITEM_TYPE.key?(type)
        query['TypeIds'] = ITEM_TYPE[type]
        scope << "#{type}s"
      end

      unless args['query'].to_s.strip.empty?
        query['Query'] = args['query'].to_s.strip[0, 200]
        scope << "matching #{args['query'].to_s.strip.inspect}"
      end

      unless args['category'].to_s.strip.empty?
        needle = args['category'].to_s.strip.downcase
        cats = api.item_categories.select { |c| c['Name'].to_s.downcase.include?(needle) }
        if cats.empty?
          next "No category matches #{args['category'].inspect}. Categories: " \
               "#{api.item_categories.map { |c| c['Name'] }.join(', ')}."
        end
        query['CategoryIds'] = cats.map { |c| c['Id'] }.join(',')
        scope << "category=#{cats.map { |c| c['Name'] }.join(' + ')}"
      end

      unless args['client'].to_s.strip.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?

        query['ClientIds'] = matched.map { |c| c['Id'] }.join(',')
        scope << "client=#{matched.map { |c| c['Name'] }.first(3).join(' + ')}"
      end

      rows = api.get_all('/v1/items', query)
      next "No items - #{scope.join(', ')}." if rows.empty?

      below = rows.select do |i|
        !i['UnitCost'].nil? && !i['UnitPrice'].nil? && i['UnitPrice'].to_f < i['UnitCost'].to_f
      end

      out = ["#{rows.size} item(s) - #{scope.join(', ')}."]
      out << ''
      out << "#{pad('Name', 34)}#{pad('Type', 8)}#{pad('SKU', 12)}#{pad('Category', 26)}" \
             "#{'Cost'.rjust(10)}#{'Price'.rjust(10)}#{'Margin'.rjust(8)}  Tax"
      out << ('-' * 124)
      rows.sort_by { |i| i['Name'].to_s.downcase }.first(limit).each do |i|
        out << "#{pad(i['Name'], 34)}#{pad(nested(i, 'Type', 'Name'), 8)}#{pad(i['Sku'], 12)}" \
               "#{pad(api.category_label(i['CategoryId'], i['SubcategoryId']) || '-', 26)}" \
               "#{(i['UnitCost'].nil? ? '-' : money(i['UnitCost'])).rjust(10)}" \
               "#{(i['UnitPrice'].nil? ? '-' : money(i['UnitPrice'])).rjust(10)}" \
               "#{margin(i['UnitPrice'], i['UnitCost']).rjust(8)}  #{api.tax_label(i['TaxId']) || '-'}"
      end
      out << "#{rows.size - limit} more not shown - raise limit." if rows.size > limit
      if below.any?
        out << ''
        out << "⚠ SELLS BELOW COST - #{below.size}: #{below.map { |i| i['Name'] }.first(12).join(', ')}"
      end
      out.join("\n")
    end
  end
```

- [ ] **Step 7: Run the suite — verify it passes**

Expected: `… passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add lib/gorelo.rb lib/gorelo_billing_tools.rb test/mock_gorelo.py test/drive.py
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Add gorelo_list_items: catalogue, bundle contents, tax and margin" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `gorelo_list_uptime` and the uptime-tools module

**Files:**
- Create: `lib/gorelo_uptime_tools.rb`
- Modify: `gorelo-mcp-server.rb` (require + register)
- Modify: `test/mock_gorelo.py` (uptime fixtures + GET routes), `test/drive.py`

**Interfaces:**
- Consumes: `GoreloTools` helpers, `api.get_all`, `api.resolve_clients`, `api.client_name`.
- Produces: `module GoreloUptimeTools` with `register`, `UPTIME_TYPE`, `STALE_WINDOW_DAYS = 7`, `target(check) -> String`, `maintenance(check, now = Time.now.utc) -> [in_maintenance(Boolean), text(String), flags(Array<String>)]` (**used by Task 6**). Mock: `UPTIME`, `uptime(...)`, `window(...)`.

- [ ] **Step 1: Mock — fixtures**

Insert immediately above `POSTED = []`:

```python
# --- uptime checks (Gorelo, 25 Sep 2026) ----------------------------------
UPTIME_TYPES = {1: "ICMP", 2: "HTTP", 3: "TCP"}
NO_WINDOW = {"Enabled": False, "StartDateTime": None, "DurationInMinutes": None, "Reason": None}


def window(days_ago, minutes, reason, hours_ago=0):
    return {"Enabled": True, "StartDateTime": ago(days_ago, hours_ago),
            "DurationInMinutes": minutes, "Reason": reason}


def uptime(n, desc, type_id, client, status, target, maint=None, created=100):
    return {"Id": "0b700000-0000-4000-8000-%012d" % n, "Description": desc,
            "Type": {"Id": type_id, "Name": UPTIME_TYPES[type_id]},
            "Target": dict({"Ip": None, "Port": None, "Url": None}, **target),
            "AdoptClientAssets": False, "ClientId": client, "LocationId": None,
            "Status": {"Id": 1 if status == "Up" else 2, "Name": status},
            "Frequency": 60, "NumberOfRetriesAfterFailure": 2, "RegionId": 1,
            "IspConnectionLink": None, "TagIds": [],
            "MaintenanceMode": dict(maint or NO_WINDOW),
            "CreatedOn": ago(created), "UpdatedOn": None}


UPTIME = [
    uptime(1, "Northwind - head office ping", 1, 11001, "Up", {"Ip": "203.0.113.10"}, created=10),
    uptime(2, "Contoso - client portal", 2, 11002, "Down",
           {"Url": "https://portal.contoso.example"},
           window(0, 240, "Portal migration", hours_ago=2), created=20),
    # Duration 0: the window never ends, and has been silencing alerts for 30 days.
    uptime(3, "Fabrikam - VPN", 3, 11003, "Up", {"Ip": "198.51.100.7", "Port": 443},
           window(30, 0, "Firewall replacement"), created=30),
    # A two-week window, nine days in.
    uptime(4, "Tailspin - website", 2, 11004, "Up", {"Url": "https://tailspin.example"},
           window(9, 20160, "Site rebuild"), created=40),
]
```

- [ ] **Step 2: Mock — GET routes**

In `do_GET`, insert immediately above `if path == "/v1/time-entries/statuses":`:

```python
        m = re.fullmatch(r"/v1/uptime/([^/]+)", path)
        if m:
            hit = next((c for c in UPTIME if c["Id"] == m.group(1)), None)
            if not hit:
                return self.reply(404, fail(404, "Uptime check not found"))
            return self.reply(200, env(hit))
        if path == "/v1/uptime":
            if page_too_big(q):
                return self.reply(400, fail(400, "PageSize must be 1-200"))
            rows = UPTIME
            for name, key in (("ClientIds", lambda c: c["ClientId"]),
                              ("TypeIds", lambda c: c["Type"]["Id"])):
                want = q_ids(q, name)
                if want is not None:
                    rows = [c for c in rows if str(key(c)) in want]
            text = q.get("Query", [""])[0].lower()
            if text:
                rows = [c for c in rows if text in (c["Description"] or "").lower()]
            rows = sorted(rows, key=lambda c: c["CreatedOn"], reverse=True)
            rows, pag = paginate(rows, q)
            return self.reply(200, env(rows, pag))
```

- [ ] **Step 3: Drive — checks**

Change the tool count check to `21`. Insert immediately above `print("\nresponse times")`:

```python
    print("\nuptime checks")
    up = s.call("gorelo_list_uptime")
    check("every check is listed with its target",
          "203.0.113.10" in up and "198.51.100.7:443" in up
          and "https://portal.contoso.example" in up, up[:900])
    check("a window with no duration never expires, and is flagged",
          "NEVER EXPIRES" in up and "Fabrikam - VPN: in maintenance with NO END" in up, up[-900:])
    check("a window running more than 7 days is flagged",
          "Tailspin - website: in maintenance since" in up, up[-900:])
    check("a short current window is not flagged",
          "Contoso - client portal:" not in up.split("⚠", 1)[-1], up[-900:])
    only = s.call("gorelo_list_uptime", maintenance="only")
    check("maintenance=only keeps only silenced checks",
          "Northwind - head office ping" not in only and "3 uptime check(s)" in only, only[:600])
    ce = s.call("gorelo_list_uptime", client="Contoso")
    check("a client filter is sent as ClientIds",
          "Contoso - client portal" in ce and "Tailspin" not in ce
          and last_query("/v1/uptime").get("ClientIds") == "11002", ce[:500])
```

- [ ] **Step 4: Run the suite — verify it fails**

Expected: FAIL on the tool count and every `uptime checks` check.

- [ ] **Step 5: Create `lib/gorelo_uptime_tools.rb`**

```ruby
# frozen_string_literal: true

# Uptime checks (Gorelo, 25 September 2026): what is being watched, and which
# checks are silenced by a maintenance window - including windows that never
# end, which is how a real outage goes unnoticed.

require 'time'
require_relative 'gorelo'
require_relative 'gorelo_tools'

module GoreloUptimeTools
  module_function

  def pad(...)    = GoreloTools.pad(...)
  def clip(...)   = GoreloTools.clip(...)
  def nested(...) = GoreloTools.nested(...)

  UPTIME_TYPE       = { 'icmp' => 1, 'http' => 2, 'tcp' => 3 }.freeze
  STALE_WINDOW_DAYS = 7

  def register(server, api)
    list_uptime(server, api)
  end

  def target(check)
    t = check['Target'] || {}
    return t['Url'] unless t['Url'].to_s.strip.empty?

    t['Port'] ? "#{t['Ip']}:#{t['Port']}" : t['Ip'].to_s
  end

  # [in_maintenance, text, flags]. A duration of 0 means the window never ends.
  def maintenance(check, now = Time.now.utc)
    m = check['MaintenanceMode'] || {}
    return [false, '-', []] unless m['Enabled']

    start  = begin
      Time.parse(m['StartDateTime'].to_s).utc
    rescue ArgumentError
      nil
    end
    reason = m['Reason'].to_s.strip.empty? ? 'no reason given' : m['Reason'].to_s.strip
    flags  = []

    if m['DurationInMinutes'].to_i.zero?
      text = "NEVER EXPIRES (#{reason})"
      flags << 'in maintenance with NO END - it stays silenced until someone ends it'
    else
      ends = start && start + (m['DurationInMinutes'].to_i * 60)
      text = if ends && ends < now
               "ENDED #{ends.strftime('%Y-%m-%d %H:%M UTC')} but still marked enabled (#{reason})"
             else
               "until #{ends ? ends.strftime('%Y-%m-%d %H:%M UTC') : '?'} (#{reason})"
             end
    end
    if start && start < now - (STALE_WINDOW_DAYS * 86_400)
      flags << "in maintenance since #{start.strftime('%Y-%m-%d')} - more than #{STALE_WINDOW_DAYS} days"
    end
    [true, text, flags]
  end

  def list_uptime(server, api)
    server.tool(
      name:  'gorelo_list_uptime',
      title: 'List Gorelo uptime checks',
      description: <<~TEXT,
        Uptime checks: what each one watches (ICMP host, HTTP URL or TCP port), for which
        client, its current status, and whether it is in a MAINTENANCE WINDOW - with when that
        window ends. A check in maintenance raises no alerts.

        Flagged by name: windows that never expire (duration 0) and windows that started more
        than 7 days ago. Both are how a real outage goes unnoticed.
      TEXT
      input_schema: {
        type: 'object',
        properties: {
          client:      { type: 'string', description: 'Client name fragment or id. Comma-separate several.' },
          type:        { type: 'string', enum: %w[all icmp http tcp], description: 'Default "all".' },
          query:       { type: 'string', description: 'Keyword matched against the check description.' },
          maintenance: { type: 'string', enum: %w[all only exclude], description: '"only": checks in maintenance. "exclude": checks not in it. Default "all".' },
          limit:       { type: 'integer', description: 'Default 100.' }
        },
        additionalProperties: false
      }
    ) do |args|
      limit = (args['limit'] || 100).to_i.clamp(1, 1000)
      query = {}
      scope = []

      unless args['client'].to_s.strip.empty?
        matched = api.resolve_clients(args['client'])
        next "No client matches #{args['client'].inspect}." if matched.empty?

        query['ClientIds'] = matched.map { |c| c['Id'] }.join(',')
        scope << "client=#{matched.map { |c| c['Name'] }.first(3).join(' + ')}"
      end

      type = args['type'].to_s.downcase
      if UPTIME_TYPE.key?(type)
        query['TypeIds'] = UPTIME_TYPE[type]
        scope << type.upcase
      end

      unless args['query'].to_s.strip.empty?
        query['Query'] = args['query'].to_s.strip[0, 200]
        scope << "matching #{args['query'].to_s.strip.inspect}"
      end

      all  = api.get_all('/v1/uptime', query)
      info = all.to_h { |c| [c['Id'], maintenance(c)] }
      rows = case args['maintenance'].to_s.downcase
             when 'only'
               scope << 'in maintenance'
               all.select { |c| info[c['Id']][0] }
             when 'exclude'
               scope << 'not in maintenance'
               all.reject { |c| info[c['Id']][0] }
             else
               all
             end

      scope_text = scope.empty? ? '' : " - #{scope.join(', ')}"
      next "No uptime checks#{scope_text}. #{all.size} matched before the maintenance filter." if rows.empty?

      in_maint = all.count { |c| info[c['Id']][0] }
      out = ["#{rows.size} uptime check(s)#{scope_text}. #{in_maint} of #{all.size} in maintenance."]
      out << ''
      out << "#{pad('Check', 32)}#{pad('Client', 22)}#{pad('Type', 6)}#{pad('Target', 30)}" \
             "#{pad('Status', 10)}Maintenance"
      out << ('-' * 130)
      rows.first(limit).each do |c|
        client = c['ClientId'] ? (api.client_name(c['ClientId']) || "client #{c['ClientId']}") : '(no client)'
        out << "#{pad(c['Description'] || c['Id'], 32)}#{pad(client, 22)}" \
               "#{pad(nested(c, 'Type', 'Name'), 6)}#{pad(target(c), 30)}" \
               "#{pad(nested(c, 'Status', 'Name'), 10)}#{info[c['Id']][1]}"
      end
      out << "#{rows.size - limit} more not shown - raise limit." if rows.size > limit

      flagged = rows.flat_map { |c| info[c['Id']][2].map { |f| "#{c['Description'] || c['Id']}: #{f}" } }
      unless flagged.empty?
        out << ''
        flagged.each { |f| out << "⚠ #{f}" }
      end
      out.join("\n")
    end
  end
end
```

- [ ] **Step 6: Register the module**

In `gorelo-mcp-server.rb`, after `require_relative 'lib/gorelo_billing_tools'` add `require_relative 'lib/gorelo_uptime_tools'`, and after `GoreloBillingTools.register(server, api)` add `GoreloUptimeTools.register(server, api)`.

- [ ] **Step 7: Run the suite — verify it passes**

Expected: `… passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add lib/gorelo_uptime_tools.rb gorelo-mcp-server.rb test/mock_gorelo.py test/drive.py
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Add gorelo_list_uptime; flag maintenance windows that never end" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `gorelo_set_uptime_maintenance` (write)

**Files:**
- Modify: `lib/gorelo_uptime_tools.rb` (`GUID`, `MAX_WINDOW_MINUTES`, `ATTRIBUTION`, `find_check`, tool, register)
- Modify: `test/mock_gorelo.py` (`LAST_BODY`, `/__debug/last-body`, `PATCH /v1/uptime/{id}`), `test/drive.py`

**Interfaces:**
- Consumes: `maintenance(check)` (Task 5), `api.patch`, `api.get`, `api.get_all`, `api.record_write`, `api.fingerprint`, `api.writes_allowed?`.
- Produces: `find_check(api, ref) -> [check|nil, why|nil]`. Mock: `LAST_BODY` dict (**also used by Tasks 7 and 8**), route `/__debug/last-body?path=`. Drive: `last_body(path) -> dict`.

- [ ] **Step 1: Mock — body recorder and PATCH route**

Below `LAST_QUERY = {}` add:

```python
# The JSON body each POST/PATCH path last received: /__debug/last-body?path=<path>.
LAST_BODY = {}
```

In `do_GET`'s debug block, add below the `last-query` line:

```python
            if d.path == "/__debug/last-body":
                return self.reply(200, LAST_BODY.get(want, {}))
```

In `do_PATCH`, replace:

```python
        path = urlparse(self.path).path
        m = re.fullmatch(r"/v1/tickets/([^/]+)", path)
```

with:

```python
        path = urlparse(self.path).path
        LAST_BODY[path] = body
        m = re.fullmatch(r"/v1/uptime/([^/]+)", path)
        if m:
            return self.patch_uptime(m.group(1), body)
        m = re.fullmatch(r"/v1/tickets/([^/]+)", path)
```

Add this method to `Handler`, directly after `do_PATCH`:

```python
    def patch_uptime(self, check_id, body):
        hit = next((c for c in UPTIME if c["Id"] == check_id), None)
        if not hit:
            return self.reply(404, fail(404, "Uptime check not found"))
        if not body:
            return self.reply(400, fail(400, "Nothing to update"))
        # This server has no business sending anything else, so the suite fails
        # if the tool's scope ever widens quietly.
        extra = set(body) - {"MaintenanceMode"}
        if extra:
            return self.reply(400, fail(400, "Unexpected fields: %s" % ", ".join(sorted(extra))))
        mm = body["MaintenanceMode"]
        unknown = set(mm) - {"Enabled", "StartDateTime", "DurationInMinutes", "Reason"}
        if unknown:
            return self.reply(400, fail(400, "Unknown MaintenanceMode fields: %s" % sorted(unknown)))
        if mm.get("Enabled") and (mm.get("StartDateTime") is None
                                  or mm.get("DurationInMinutes") is None or not mm.get("Reason")):
            return self.reply(400, fail(400, "Starting maintenance needs a start, a duration and a reason"))
        # Tailspin's check accepts the PATCH and IGNORES it, standing in for a
        # payload the API took and did not apply. Only a read-back catches that.
        if not hit["Description"].startswith("Tailspin"):
            hit["MaintenanceMode"] = (
                {k: mm.get(k) for k in ("Enabled", "StartDateTime", "DurationInMinutes", "Reason")}
                if mm.get("Enabled") else dict(NO_WINDOW))
        return self.reply(200, env({"Id": check_id}))
```

- [ ] **Step 2: Drive — helper and checks**

Below `te_query` add:

```python
def last_body(path):
    """The JSON body the mock last received for a POST or PATCH on `path`."""
    url = ENV["GORELO_BASE_URL"] + "/__debug/last-body?" + urllib.parse.urlencode({"path": path})
    with urllib.request.urlopen(url) as r:
        return json.load(r)
```

Change the tool count check to `22`, and replace the write-set check with:

```python
    check("exactly three tools write, and none can delete",
          sorted(t["name"] for t in tools if not t["annotations"]["readOnlyHint"])
          == ["gorelo_add_ticket_comment", "gorelo_set_uptime_maintenance",
              "gorelo_update_ticket"])
```

In the `write guards (writes disabled)` section add:

```python
    check("uptime maintenance refused when disabled",
          "Writes are disabled" in s.call("gorelo_set_uptime_maintenance", check="head office",
                                          action="start", minutes=60, reason="x", confirm=True))
```

Insert immediately above `s2.close()` (in the writes-ENABLED block):

```python
    print("\nuptime maintenance")
    U = "/v1/uptime/0b700000-0000-4000-8000-000000000001"
    check("confirm required", "confirm must be true" in
          s2.call("gorelo_set_uptime_maintenance", check="head office", action="start",
                  minutes=60, reason="x", confirm=False))
    check("a reason is required to start", "reason is required" in
          s2.call("gorelo_set_uptime_maintenance", check="head office", action="start",
                  minutes=60, confirm=True))
    b0 = last_body(U)
    zero = s2.call("gorelo_set_uptime_maintenance", check="head office", action="start",
                   minutes=0, reason="Router swap", confirm=True)
    check("zero minutes is refused - a never-ending window must be asked for by name",
          "indefinite: true" in zero and last_body(U) == b0, zero)
    amb = s2.call("gorelo_set_uptime_maintenance", check="-", action="end", confirm=True)
    check("a fragment matching several checks is refused, never guessed",
          "uptime checks match" in amb and last_body(U) == b0, amb)
    started = s2.call("gorelo_set_uptime_maintenance", check="head office", action="start",
                      minutes=60, reason="Router swap", confirm=True)
    sent = last_body(U)
    check("start is applied and verified by reading back",
          "Started maintenance" in started and "Verified" in started, started)
    check("only MaintenanceMode is sent", list(sent) == ["MaintenanceMode"], sent)
    check("the reason is attributed, since the API records no author",
          sent.get("MaintenanceMode", {}).get("Reason") == "[Gorelo MCP] Router swap", sent)
    check("the list now shows it in maintenance",
          "Router swap" in s2.call("gorelo_list_uptime", query="head office"))
    ended = s2.call("gorelo_set_uptime_maintenance", check="head office", action="end", confirm=True)
    check("end sends Enabled:false and nothing else",
          last_body(U) == {"MaintenanceMode": {"Enabled": False}} and "Ended maintenance" in ended,
          (ended, last_body(U)))
    check("ending a check that is not in maintenance writes nothing", "not in maintenance" in
          s2.call("gorelo_set_uptime_maintenance", check="head office", action="end", confirm=True))
    forever = s2.call("gorelo_set_uptime_maintenance", check="head office", action="start",
                      indefinite=True, reason="Awaiting decommission", confirm=True)
    check("indefinite sends a zero duration and says loudly that it never expires",
          last_body(U).get("MaintenanceMode", {}).get("DurationInMinutes") == 0
          and "NEVER EXPIRES" in forever, forever)
    s2.call("gorelo_set_uptime_maintenance", check="head office", action="end", confirm=True)
    ignored = s2.call("gorelo_set_uptime_maintenance", check="Tailspin", action="end", confirm=True)
    check("an accepted-but-ignored change is reported as FAILED",
          "DID NOT TAKE EFFECT" in ignored, ignored)
```

- [ ] **Step 3: Run the suite — verify it fails**

Expected: FAIL on the tool count, the write-set check, `uptime maintenance refused when disabled`, and every `uptime maintenance` check.

- [ ] **Step 4: Tool — `gorelo_set_uptime_maintenance`**

In `lib/gorelo_uptime_tools.rb`, add below `STALE_WINDOW_DAYS = 7`:

```ruby
  GUID               = Gorelo::Client::GUID
  MAX_WINDOW_MINUTES = 10_080 # a week. Longer should be a decision made in Gorelo.
  ATTRIBUTION        = '[Gorelo MCP] '
```

Add `set_uptime_maintenance(server, api)` to `register`, and add after `list_uptime`:

```ruby
  # One check by id, or by a description fragment matching EXACTLY one.
  def find_check(api, ref)
    ref = ref.to_s.strip
    return [nil, 'Give an uptime check id or a fragment of its description.'] if ref.empty?
    return [api.get("/v1/uptime/#{ref}")['Data'], nil] if ref.match?(GUID)

    hits = api.get_all('/v1/uptime', { 'Query' => ref[0, 200] })
              .select { |c| c['Description'].to_s.downcase.include?(ref.downcase) }
    return [nil, "No uptime check description contains #{ref.inspect}."] if hits.empty?
    if hits.size > 1
      return [nil, "#{hits.size} uptime checks match #{ref.inspect}: " \
                   "#{hits.first(10).map { |c| c['Description'] }.join('; ')}. Narrow it, or give the id."]
    end

    [hits.first, nil]
  end

  def set_uptime_maintenance(server, api)
    server.tool(
      name:  'gorelo_set_uptime_maintenance',
      title: 'Start or end maintenance on a Gorelo uptime check',
      description: <<~TEXT,
        Starts or ends a maintenance window on ONE uptime check. A check in maintenance raises
        no alerts, so a window nobody ends hides real outages.

        Safety:
          - disabled unless GORELO_ALLOW_WRITES=true; `confirm: true` required
          - sends ONLY MaintenanceMode - never the check's target, type, client or tags
          - `start` needs a reason and a duration in minutes (1-10080). A window that never
            expires needs `indefinite: true`; it never comes from a default or a zero
          - the reason is prefixed "[Gorelo MCP]", because the API records no author
          - the check is read back to confirm the change took effect
      TEXT
      read_only: false,
      input_schema: {
        type: 'object',
        properties: {
          check:      { type: 'string', description: 'Uptime check id, or a fragment of its description matching exactly one check.' },
          action:     { type: 'string', enum: %w[start end] },
          minutes:    { type: 'integer', description: 'Length of the window, 1-10080. Required to start, unless indefinite.' },
          indefinite: { type: 'boolean', description: 'true: the window never expires. Only to start, and only on purpose.' },
          reason:     { type: 'string', description: 'Why. Required to start.' },
          confirm:    { type: 'boolean', description: 'Must be true. Nothing is written without it.' }
        },
        required: %w[check action confirm],
        additionalProperties: false
      }
    ) do |args|
      next 'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart.' unless api.writes_allowed?
      next 'Refused: confirm must be true. Nothing was written.' unless args['confirm'] == true

      action = args['action'].to_s
      next 'Refused: action must be "start" or "end". Nothing was written.' unless %w[start end].include?(action)

      if action == 'start'
        reason = args['reason'].to_s.strip
        next 'Refused: a reason is required to start maintenance. Nothing was written.' if reason.empty?

        if args['indefinite'] == true
          unless args['minutes'].nil? || args['minutes'].to_i.zero?
            next 'Refused: give minutes OR indefinite: true, not both. Nothing was written.'
          end

          minutes = 0
        else
          minutes = args['minutes'].to_i
          unless minutes.between?(1, MAX_WINDOW_MINUTES)
            next "Refused: minutes must be 1-#{MAX_WINDOW_MINUTES}. A window that never ends needs " \
                 'indefinite: true. Nothing was written.'
          end
        end
        mode = { 'Enabled' => true, 'StartDateTime' => Time.now.utc.iso8601,
                 'DurationInMinutes' => minutes, 'Reason' => "#{ATTRIBUTION}#{reason}" }
      else
        mode = { 'Enabled' => false }
      end

      check, why = find_check(api, args['check'])
      next "#{why} Nothing was written." unless check

      label  = check['Description'] || check['Id']
      before = check['MaintenanceMode'] || {}
      next "#{label} is not in maintenance. Nothing was written." if action == 'end' && !before['Enabled']

      payload = { 'MaintenanceMode' => mode }
      begin
        api.patch("/v1/uptime/#{check['Id']}", payload)
      rescue Gorelo::Error => e
        next "Gorelo refused the change to #{label}: #{e.message}"
      end

      after = begin
        api.get("/v1/uptime/#{check['Id']}")['Data']
      rescue Gorelo::Error
        nil
      end
      unless after.is_a?(Hash)
        next "Sent the change to #{label} but could NOT read the check back to confirm it. Check in Gorelo."
      end

      now_mode = after['MaintenanceMode'] || {}
      took = now_mode['Enabled'] == mode['Enabled'] &&
             (action == 'end' || now_mode['DurationInMinutes'].to_i == mode['DurationInMinutes'])

      # Audit trail, as for gorelo_update_ticket. Re-applying a window is
      # harmless, so this records rather than refuses.
      api.record_write(api.fingerprint(check['Id'], payload.to_json),
                       "PATCH /v1/uptime/#{check['Id']} #{payload.to_json} → #{took ? 'applied' : 'NO EFFECT'}")

      unless took
        next "⚠ DID NOT TAKE EFFECT. Gorelo accepted the change to #{label}, but reading it back shows " \
             "MaintenanceMode #{now_mode.to_json}. The API ignores fields it doesn't recognise, so " \
             "the payload may be wrong. Sent: #{payload.to_json}"
      end

      if action == 'end'
        "Ended maintenance on #{label}. Verified by reading it back: alerts are live again."
      else
        had  = before['Enabled'] ? "It was already in maintenance (#{maintenance(check)[1]}); that window was replaced. " : ''
        text = "Started maintenance on #{label}: #{maintenance(after)[1]}. #{had}Verified by reading it back."
        text += "\n⚠ This window NEVER EXPIRES. The check raises no alerts until someone ends it." if mode['DurationInMinutes'].zero?
        text
      end
    end
  end
```

- [ ] **Step 5: Run the suite — verify it passes**

Expected: `… passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add lib/gorelo_uptime_tools.rb test/mock_gorelo.py test/drive.py
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Add gorelo_set_uptime_maintenance: MaintenanceMode only, verified by read-back" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `gorelo_create_draft_invoice` (write) and no retry of a POST after a 5xx

**Files:**
- Modify: `lib/gorelo.rb` (`AmbiguousWrite`, `request`, `handle`)
- Modify: `lib/gorelo_tools.rb` (`add_ticket_comment` handles `AmbiguousWrite`)
- Modify: `lib/gorelo_billing_tools.rb` (`MAX_LINES`, `one_client`, `parse_day`, tool, register)
- Modify: `test/mock_gorelo.py` (`HITS`, `/__debug/hits`, `POST /v1/invoices`, BOOM-500 on comments), `test/drive.py`

**Interfaces:**
- Consumes: `find_item(api, ref, active_only: true)` (Task 4), `money`, `pad`, `nested`, `STATUS_DRAFT`, `LAST_BODY` (Task 6), `TAXES`, `ITEMS`, `INVOICES`, `INVOICE_STATUS_NAMES`, `day`.
- Produces: `Gorelo::AmbiguousWrite < Gorelo::Error`; `handle(res, uri, raw: false, retry_5xx: true)`; `one_client(api, term) -> [client|nil, why|nil]`; `parse_day(value, label) -> [Date|nil, why|nil]`. Mock: `HITS` dict, route `/__debug/hits?path=`. Drive: `hits(path) -> int`.

- [ ] **Step 1: Mock — POST counter, invoice creation, a failing comment**

Add `import uuid` to the imports. Below `LAST_BODY = {}` add:

```python
# How many POSTs each path has received - proves a failed POST was not retried.
HITS = {}
```

In `do_GET`'s debug block, add:

```python
            if d.path == "/__debug/hits":
                return self.reply(200, {"count": HITS.get(want, 0)})
```

In `do_POST`, replace:

```python
        u = urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        m = re.fullmatch(r"/v1/tickets/([^/]+)/comments", u.path)
```

with:

```python
        u = urlparse(self.path)
        HITS[u.path] = HITS.get(u.path, 0) + 1
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        LAST_BODY[u.path] = body
        if u.path == "/v1/invoices":
            return self.post_invoice(body)
        m = re.fullmatch(r"/v1/tickets/([^/]+)/comments", u.path)
```

In the comments branch, replace:

```python
            POSTED.append({"ticket": m.group(1), "body": body})
```

with:

```python
            POSTED.append({"ticket": m.group(1), "body": body})
            # The comment IS stored, then the request fails: the case where a
            # retry would post it twice.
            if "BOOM-500" in body.get("Body", ""):
                return self.reply(500, fail(500, "Internal server error"))
```

Add this method to `Handler`, after `do_POST`:

```python
    INVOICE_FIELDS = {"ClientId", "StatusId", "InvoiceDate", "DueDate", "Reference",
                      "RecipientEmails", "LineItems"}
    LINE_FIELDS = {"ItemId", "Description", "Quantity", "UnitPrice", "UnitCost",
                   "DiscountPercent", "TaxId", "CoaCode", "BillableStatusId"}

    def post_invoice(self, body):
        unknown = set(body) - self.INVOICE_FIELDS
        if unknown:
            return self.reply(400, fail(400, "Unknown fields: %s" % sorted(unknown)))
        if not any(c["Id"] == body.get("ClientId") for c in CLIENTS):
            return self.reply(404, fail(404, "Client not found"))
        if body.get("StatusId") not in (None, 1, 5):
            return self.reply(400, fail(400, "StatusId must be 1 (Draft) or 5 (Approved)"))
        lines = body.get("LineItems") or []
        if not lines:
            return self.reply(400, fail(400, "At least one line item is required"))
        subtotal = tax = 0.0
        for l in lines:
            if set(l) - self.LINE_FIELDS:
                return self.reply(400, fail(400, "Unknown line fields: %s" % sorted(set(l) - self.LINE_FIELDS)))
            it = next((i for i in ITEMS if i["Id"] == l.get("ItemId")), None)
            if not it:
                return self.reply(400, fail(400, "Unknown ItemId %s" % l.get("ItemId")))
            if not (l.get("Quantity") or 0) > 0:
                return self.reply(400, fail(400, "Quantity must be greater than 0"))
            price = l["UnitPrice"] if l.get("UnitPrice") is not None else (it["UnitPrice"] or 0)
            amount = round(l["Quantity"] * price, 2)
            t = next((x for x in TAXES if x["Id"] == it["TaxId"]), None)
            pct = (sum(s["Percentage"] for s in t["SubTaxes"]) if t and t["SubTaxes"]
                   else ((t or {}).get("Percentage") or 0))
            subtotal += amount
            tax += round(amount * pct / 100, 2)
        n = max(i["Number"] for i in INVOICES) + 1
        status = body.get("StatusId") or 1
        date = (body.get("InvoiceDate") or day(0))[:10]
        total = round(subtotal + tax, 2)
        INVOICES.append({
            "Id": str(uuid.uuid4()), "Number": n, "DisplayNumber": "INV-%04d" % n,
            "ClientId": body["ClientId"], "ContractId": None,
            "Status": {"Id": status, "Name": INVOICE_STATUS_NAMES[status]},
            "InvoiceDate": date, "DueDate": (body.get("DueDate") or date)[:10],
            "SubTotal": round(subtotal, 2), "TotalDiscount": 0.0, "TotalTax": round(tax, 2),
            "Total": total, "AmountPaid": 0.0, "AmountDue": total,
            "Reference": body.get("Reference"), "ExternalId": None, "PaymentLink": None,
            "InvoiceTemplateId": None, "InvoiceEmailTemplateId": None, "BrandingThemeId": None,
            "IsEmailSent": False, "EmailSentOn": None,
            "CreatedOn": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "UpdatedOn": None})
        # BOOM-500: the invoice IS created, then the request fails - the case
        # where retrying the POST raises a second invoice.
        if body.get("Reference") == "BOOM-500":
            return self.reply(500, fail(500, "Internal server error"))
        return self.reply(200, env({"Id": INVOICES[-1]["Id"]}))
```

- [ ] **Step 2: Drive — helper and checks**

Below `last_body` add:

```python
def hits(path):
    """How many POSTs the mock has received on `path`."""
    url = ENV["GORELO_BASE_URL"] + "/__debug/hits?" + urllib.parse.urlencode({"path": path})
    with urllib.request.urlopen(url) as r:
        return json.load(r)["count"]
```

Change the tool count check to `23`, and replace the write-set check with:

```python
    check("exactly four tools write, and none can delete",
          sorted(t["name"] for t in tools if not t["annotations"]["readOnlyHint"])
          == ["gorelo_add_ticket_comment", "gorelo_create_draft_invoice",
              "gorelo_set_uptime_maintenance", "gorelo_update_ticket"])
    inv_props = next((t for t in tools if t["name"] == "gorelo_create_draft_invoice"),
                     {"inputSchema": {"properties": {"status": 1}}})["inputSchema"]["properties"]
    check("a draft invoice has no status parameter - approving stays a human action",
          not any(k.lower() in ("status", "statusid", "approve", "approved") for k in inv_props),
          sorted(inv_props))
    check("and no recipient-email parameter",
          not any("email" in k.lower() for k in inv_props), sorted(inv_props))
```

In the `write guards (writes disabled)` section add:

```python
    check("draft invoice refused when disabled",
          "Writes are disabled" in s.call("gorelo_create_draft_invoice", client="Fabrikam",
                                          lines=[{"item": "Managed desktop seat", "quantity": 1}],
                                          confirm=True))
```

Insert immediately above `s2.close()`:

```python
    print("\ndraft invoices")
    P = "/v1/invoices"
    LINES = [{"item": "Managed desktop seat", "quantity": 2},
             {"item": "New starter bundle", "quantity": 1, "unit_price": 1850}]
    check("confirm required", "confirm must be true" in
          s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES, confirm=False))
    amb = s2.call("gorelo_create_draft_invoice", client="a", lines=LINES, confirm=True)
    check("an ambiguous client is refused, never guessed",
          "clients match" in amb and "Nothing was created" in amb, amb)
    h0 = hits(P)
    bad = s2.call("gorelo_create_draft_invoice", client="Fabrikam",
                  lines=[{"item": "Managed desktop seat", "quantity": 0},
                         {"item": "Microsoft", "quantity": 1},
                         {"item": "Legacy AV licence", "quantity": 1}], confirm=True)
    check("every line is checked, and all problems reported, before anything is sent",
          "line 1: quantity" in bad and "line 2: No active item is named exactly" in bad
          and "line 3: No active item" in bad and hits(P) == h0, bad)
    made = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                   reference="MCP-TEST", confirm=True)
    sent = last_body(P)
    sent_lines = sent.get("LineItems") or [{}, {}]
    check("the invoice is created as a DRAFT and verified by reading back",
          "Created DRAFT invoice INV-" in made and "Verified" in made, made)
    check("StatusId 1 is always sent", sent.get("StatusId") == 1, sent)
    check("no recipient emails, and nothing the item should supply",
          "RecipientEmails" not in sent
          and all(set(l) <= {"ItemId", "Quantity", "UnitPrice", "Description"} for l in sent_lines),
          sent)
    check("a given unit price is sent; an omitted one is left to the item",
          "UnitPrice" not in sent_lines[0] and sent_lines[1].get("UnitPrice") == 1850, sent)
    check("the totals are Gorelo's, from the read-back", "total 2222.00" in made, made)
    again = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                    reference="MCP-TEST", confirm=True)
    check("an identical invoice within 24h is refused",
          "Refused" in again and "already raised" in again, again)
    h0 = hits(P)
    boom = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                   reference="BOOM-500", confirm=True)
    check("a server error after the POST is NOT retried", hits(P) == h0 + 1, (h0, hits(P)))
    check("and the reply says the invoice MAY exist", "MAY have been created" in boom, boom)
    check("and a repeat is refused", "Refused" in
          s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                  reference="BOOM-500", confirm=True))
    CP = "/v1/tickets/00000000-0000-0000-0000-000000001000/comments"
    h0 = hits(CP)
    maybe = s2.call("gorelo_add_ticket_comment", ticket="G-1000", body="BOOM-500 comment",
                    confirm=True)
    check("a comment that fails after the POST is not retried, and may exist",
          hits(CP) == h0 + 1 and "MAY have been posted" in maybe, maybe)
```

- [ ] **Step 3: Run the suite — verify it fails**

Expected: FAIL on the tool count, the write set, the schema checks, `draft invoice refused when disabled`, every `draft invoices` check. The BOOM checks fail because the old client retries the 500 (the POST count rises by 4, not 1).

- [ ] **Step 4: Client — never retry a POST after a 5xx**

In `lib/gorelo.rb`, below `class WritesDisabled < Error; end` add:

```ruby
  # A POST that failed with a server error. It MAY have been applied - a 5xx
  # says nothing either way - so it is never retried: retrying a POST that did
  # land raises a second invoice or posts a second comment.
  class AmbiguousWrite < Error; end
```

In `request`, replace `with_retry(path) { handle(http.request(req), uri, raw: raw) }` with:

```ruby
      with_retry(path) { handle(http.request(req), uri, raw: raw, retry_5xx: klass != Net::HTTP::Post) }
```

Change `def handle(res, uri, raw: false)` to `def handle(res, uri, raw: false, retry_5xx: true)`, and replace:

```ruby
        if code == 429 || code >= 500
```

with:

```ruby
        # A 429 was never processed, so it is always safe to retry. A 5xx on a
        # POST may have been processed, so it is not.
        if code >= 500 && !retry_5xx
          raise AmbiguousWrite, "#{message}\n  Not retried: this was a POST, and a server error " \
                                'does not say whether it was applied. Check Gorelo before trying again.'
        end

        if code == 429 || code >= 500
```

- [ ] **Step 5: Comment tool — handle `AmbiguousWrite`**

In `lib/gorelo_tools.rb` `add_ticket_comment`, replace:

```ruby
      rescue Gorelo::Error => e
        next "Nothing was posted. #{e.message}"
      end
```

with:

```ruby
      rescue Gorelo::AmbiguousWrite => e
        api.record_write(key, "#{t['DisplayNumber']} AMBIGUOUS ConversationTypeId=#{type_id}")
        next "⚠ Gorelo failed AFTER receiving the comment for #{t['DisplayNumber']}, so it MAY have " \
             'been posted. Check the ticket before posting again - a repeat within 24 hours will be ' \
             "refused.\n#{e.message}"
      rescue Gorelo::Error => e
        next "Nothing was posted. #{e.message}"
      end
```

- [ ] **Step 6: Tool — `gorelo_create_draft_invoice`**

In `lib/gorelo_billing_tools.rb`, add below `ITEM_STATUS = …`:

```ruby
  MAX_LINES = 100
```

Add `create_draft_invoice(server, api)` to `register`, and add after `list_items`:

```ruby
  # ---- draft invoices (write) ---------------------------------------------

  # A write needs exactly one client; a read can take several.
  def one_client(api, term)
    matched = api.resolve_clients(term)
    return [nil, "No client matches #{term.inspect}."] if matched.empty?
    if matched.size > 1
      return [nil, "#{matched.size} clients match #{term.inspect}: " \
                   "#{matched.first(8).map { |c| "#{c['Id']} #{c['Name']}" }.join(', ')}. Narrow it."]
    end

    [matched.first, nil]
  end

  def parse_day(value, label)
    return [nil, nil] if value.nil? || value.to_s.strip.empty?

    [Date.iso8601(value.to_s.strip), nil]
  rescue Date::Error
    [nil, "#{label} #{value.inspect} is not a date (YYYY-MM-DD)."]
  end

  def create_draft_invoice(server, api)
    server.tool(
      name:  'gorelo_create_draft_invoice',
      title: 'Raise a DRAFT invoice in Gorelo',
      description: <<~TEXT,
        Raises a manual invoice against one client, ALWAYS AS A DRAFT. A person approves it in
        Gorelo; approving is what pushes it to Xero/QuickBooks, and that is never done here.

        Each line names a catalogue item (its id or exact name - see gorelo_list_items) and a
        quantity. Price, cost, tax, account code and billable status come from the item unless
        unit_price is given. No recipient emails are sent.

        Safety:
          - disabled unless GORELO_ALLOW_WRITES=true; `confirm: true` required
          - StatusId is always 1 (Draft); there is no parameter to change it
          - every line is resolved and checked BEFORE anything is sent
          - an identical invoice within 24 hours is refused, so a retried call cannot raise two
          - a server error is never retried, because it may have created the invoice
          - the new invoice is read back, and its number, status and totals reported
      TEXT
      read_only: false,
      input_schema: {
        type: 'object',
        properties: {
          client: { type: 'string', description: 'Client name fragment or id. Must match exactly one client.' },
          lines:  {
            type: 'array', minItems: 1, maxItems: MAX_LINES,
            items: {
              type: 'object',
              properties: {
                item:        { type: 'string', description: 'Item id, or its exact name.' },
                quantity:    { type: 'number', description: 'Greater than 0.' },
                unit_price:  { type: 'number', description: "Optional. Defaults to the item's own price." },
                description: { type: 'string', description: "Optional. Defaults to the item's description." }
              },
              required: %w[item quantity],
              additionalProperties: false
            }
          },
          reference:    { type: 'string', description: 'Optional invoice reference, e.g. a PO number.' },
          invoice_date: { type: 'string', description: 'YYYY-MM-DD. Default today.' },
          due_date:     { type: 'string', description: 'YYYY-MM-DD. Default: the invoice date.' },
          confirm:      { type: 'boolean', description: 'Must be true. Nothing is created without it.' }
        },
        required: %w[client lines confirm],
        additionalProperties: false
      }
    ) do |args|
      next 'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart.' unless api.writes_allowed?
      next 'Refused: confirm must be true. Nothing was created.' unless args['confirm'] == true

      client, why = one_client(api, args['client'])
      next "#{why} Nothing was created." unless client

      raw = Array(args['lines'])
      next 'Refused: give at least one line. Nothing was created.' if raw.empty?
      next "Refused: at most #{MAX_LINES} lines. Nothing was created." if raw.size > MAX_LINES

      invoice_date, why = parse_day(args['invoice_date'], 'invoice_date')
      next "Refused: #{why} Nothing was created." if why

      due_date, why = parse_day(args['due_date'], 'due_date')
      next "Refused: #{why} Nothing was created." if why
      if due_date && due_date < (invoice_date || Date.today)
        next 'Refused: due_date is before the invoice date. Nothing was created.'
      end

      # Every line is resolved and checked before anything is sent, and every
      # problem is reported at once rather than one per attempt.
      problems = []
      lines = raw.each_with_index.filter_map do |l, n|
        where = "line #{n + 1}"
        unless l['quantity'].is_a?(Numeric) && l['quantity'].positive?
          problems << "#{where}: quantity must be greater than 0"
          next
        end
        unless l['unit_price'].nil? || (l['unit_price'].is_a?(Numeric) && l['unit_price'] >= 0)
          problems << "#{where}: unit_price must be 0 or more"
          next
        end
        item, item_why = find_item(api, l['item'], active_only: true)
        unless item
          problems << "#{where}: #{item_why}"
          next
        end
        { item: item, quantity: l['quantity'], unit_price: l['unit_price'], description: l['description'] }
      end
      next "Refused - nothing was created:\n  #{problems.join("\n  ")}" unless problems.empty?

      payload = {
        'ClientId'  => client['Id'],
        'StatusId'  => STATUS_DRAFT,
        'LineItems' => lines.map do |l|
          li = { 'ItemId' => l[:item]['Id'], 'Quantity' => l[:quantity] }
          li['UnitPrice']   = l[:unit_price] unless l[:unit_price].nil?
          li['Description'] = l[:description] unless l[:description].to_s.strip.empty?
          li
        end
      }
      payload['Reference']   = args['reference'].to_s.strip unless args['reference'].to_s.strip.empty?
      payload['InvoiceDate'] = invoice_date.iso8601 if invoice_date
      payload['DueDate']     = due_date.iso8601 if due_date
      # Deliberately absent: RecipientEmails (nothing is emailed from here), and
      # UnitCost, TaxId, CoaCode, BillableStatusId and DiscountPercent, which
      # fall back to the item's own values.

      key = api.fingerprint('invoice', payload.to_json)
      if api.write_fingerprint_seen?(key)
        next "Refused: an identical draft invoice for #{client['Name']} was already raised in the " \
             'last 24 hours. Nothing was created. Change the reference if a second one is really wanted.'
      end

      before = Time.now.utc - 120
      begin
        id = api.post('/v1/invoices', payload).dig('Data', 'Id')
      rescue Gorelo::AmbiguousWrite => e
        api.record_write(key, "POST /v1/invoices #{client['Name']} AMBIGUOUS")
        next "⚠ Gorelo failed AFTER receiving the invoice for #{client['Name']}, so it MAY have been " \
             "created. Check the client's draft invoices (gorelo_list_invoices) before trying again - " \
             "a repeat within 24 hours will be refused.\n#{e.message}"
      rescue Gorelo::Error => e
        next "Nothing was created. #{e.message}"
      end
      api.record_write(key, "POST /v1/invoices #{client['Name']} → #{id}")

      # There is no GET /v1/invoices/{id}, so the new invoice is found by listing
      # this client's invoices created since just before the POST.
      row = begin
        api.get_all('/v1/invoices', { 'ClientIds' => client['Id'], 'CreatedSince' => before.iso8601 })
           .find { |i| i['Id'].to_s == id.to_s }
      rescue Gorelo::Error
        nil
      end
      unless row
        next "⚠ Gorelo returned invoice id #{id} for #{client['Name']}, but it could NOT be read back. " \
             'Check in Gorelo before assuming it exists, or raising it again.'
      end

      draft = nested(row, 'Status', 'Id') == STATUS_DRAFT
      out = []
      out << if draft
               "Created DRAFT invoice #{row['DisplayNumber']} for #{client['Name']}. Verified by reading it back."
             else
               "⚠ Created invoice #{row['DisplayNumber']} for #{client['Name']}, but Gorelo reports it as " \
                 "#{nested(row, 'Status', 'Name').inspect}, NOT Draft. Check it in Gorelo now."
             end
      out << "Subtotal #{money(row['SubTotal'])} · tax #{money(row['TotalTax'])} · total #{money(row['Total'])} · " \
             "dated #{row['InvoiceDate'].to_s[0, 10]} · due #{row['DueDate'].to_s[0, 10]}"
      lines.each do |l|
        price = l[:unit_price].nil? ? l[:item]['UnitPrice'] : l[:unit_price]
        out << "  #{format('%7.2f', l[:quantity])} x #{pad(l[:item]['Name'], 36)}#{money(price).rjust(10)}" \
               "#{l[:unit_price].nil? ? '' : '  (price given)'}"
      end
      out << 'Not approved, not emailed, not sent to accounting. Review and approve it in Gorelo.' if draft
      out.join("\n")
    end
  end
```

- [ ] **Step 7: Run the suite — verify it passes**

Expected: `… passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add lib/gorelo.rb lib/gorelo_tools.rb lib/gorelo_billing_tools.rb test/mock_gorelo.py test/drive.py
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Add gorelo_create_draft_invoice; never retry a POST after a server error" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: File attachments on `gorelo_add_ticket_comment`

**Files:**
- Modify: `lib/gorelo.rb` (`require 'securerandom'`, `post_multipart`, `request` gains `raw_body:`/`content_type:`)
- Modify: `lib/gorelo_tools.rb` (`ATTACH_MAX_BYTES`, `attach_dir`, `attachment_path`, `orphans`, comment tool)
- Modify: `test/mock_gorelo.py` (`UPLOADS`, `ISSUED_URLS`, `/__debug/uploads`, multipart `POST /v1/attachments`, comment Attachments check), `test/drive.py`

**Interfaces:**
- Consumes: `api.fingerprint`, `api.write_fingerprint_seen?`, `find_ticket`, `LAST_BODY`, `HITS`.
- Produces: `api.post_multipart(path, fields_hash, file_path) -> parsed envelope`; `request(…, raw_body: nil, content_type: nil)`; `GoreloTools.attachment_path(name) -> [realpath|nil, why|nil]`. Mock: `UPLOADS` list; drive `uploads() -> list`.

- [ ] **Step 1: Mock — multipart upload endpoint**

Add to the imports:

```python
import email.policy
from email.parser import BytesParser
```

Below `HITS = {}` add:

```python
# Every file uploaded to /v1/attachments, and every URL handed back for one.
UPLOADS = []
ISSUED_URLS = set()
```

In `do_GET`'s debug block add:

```python
            if d.path == "/__debug/uploads":
                return self.reply(200, UPLOADS)
```

In `do_POST`, replace:

```python
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        LAST_BODY[u.path] = body
```

with:

```python
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        if u.path == "/v1/attachments":
            return self.post_attachment(raw)
        body = json.loads(raw or b"{}")
        LAST_BODY[u.path] = body
```

In the comments branch, directly after the `if body.get("ConversationTypeId") in (1, 2) and "ConversationId" in body:` check (and its `return`), add:

```python
            for a in body.get("Attachments") or []:
                if set(a) != {"Name", "Url"} or a["Url"] not in ISSUED_URLS:
                    return self.reply(400, fail(400, "Attachment not uploaded here: %s" % a))
```

Add this method to `Handler`:

```python
    def post_attachment(self, raw):
        ctype = self.headers.get("Content-Type", "")
        if not ctype.startswith("multipart/form-data"):
            return self.reply(415, fail(415, "multipart/form-data required"))
        msg = BytesParser(policy=email.policy.default).parsebytes(
            b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + raw)
        fields, upload = {}, None
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            data = part.get_payload(decode=True) or b""
            if part.get_filename() is not None:
                if name != "file":
                    return self.reply(400, fail(400, "The file part must be named 'file'"))
                upload = (part.get_filename(), data)
            else:
                fields[name] = data.decode()
        if upload is None:
            return self.reply(400, fail(400, "No file part"))
        if fields.get("itemType") not in ("Ticket", "Task", "Project"):
            return self.reply(400, fail(400, "itemType must be Ticket, Task or Project"))
        if fields["itemType"] == "Ticket" and not any(t["Id"] == fields.get("itemId") for t in TICKETS):
            return self.reply(404, fail(404, "Ticket not found"))
        url = "https://files.example.invalid/%s?token=t0k3n" % uuid.uuid4()
        ISSUED_URLS.add(url)
        UPLOADS.append({"itemType": fields["itemType"], "itemId": fields.get("itemId"),
                        "name": upload[0], "size": len(upload[1])})
        return self.reply(200, env({"Name": upload[0], "Url": url}))
```

- [ ] **Step 2: Drive — attach dir, helper and checks**

In `ENV.update({...})` add:

```python
    "GORELO_ATTACH_DIR": os.path.join(HERE, "_tmp_home", "gorelo-attachments"),
```

Below `hits` add:

```python
def uploads():
    with urllib.request.urlopen(ENV["GORELO_BASE_URL"] + "/__debug/uploads") as r:
        return json.load(r)
```

Insert immediately above `s2.close()`:

```python
    print("\ncomment attachments")
    ad = ENV["GORELO_ATTACH_DIR"]
    os.makedirs(ad, exist_ok=True)
    with open(os.path.join(ad, "notes.txt"), "w") as f:
        f.write("Firmware notes\n")
    with open(os.path.join(ad, "notes2.txt"), "w") as f:
        f.write("Other notes\n")
    with open(os.path.join(ad, "big.bin"), "wb") as f:
        f.truncate(44 * 1024 * 1024 + 1)
    link = os.path.join(ad, "escape.txt")
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(os.path.join(HERE, "drive.py"), link)

    n0 = len(uploads())
    for label, name in [("a .. path", "../../drive.py"),
                        ("a symlink pointing out of the folder", "escape.txt"),
                        ("an absolute path elsewhere", os.path.join(HERE, "drive.py")),
                        ("a home-relative path", "~/.gorelo-mcp-writes.jsonl"),
                        ("a file over 44 MB", "big.bin"),
                        ("a missing file", "missing.txt")]:
        r = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                    body="Attachment test: " + label, files=[name], confirm=True)
        check("refused before any upload: " + label,
              "Refused" in r and len(uploads()) == n0, r)
    att = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                  body="Firmware notes attached.", files=["notes.txt"], confirm=True)
    body = last_body(CP)
    check("a file in the folder is uploaded, then referenced by the comment",
          "Posted" in att and "notes.txt" in att and len(uploads()) == n0 + 1
          and [a.get("Name") for a in body.get("Attachments", [])] == ["notes.txt"], (att, body))
    last = (uploads() or [{}])[-1]
    check("the upload is filed against the ticket",
          last.get("itemType") == "Ticket"
          and last.get("itemId") == "00000000-0000-0000-0000-000000001000"
          and last.get("size") == 15, last)
    diff = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                   body="Firmware notes attached.", files=["notes2.txt"], confirm=True)
    check("the same text with a different file is not a duplicate", "Posted" in diff, diff)
    dup = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                  body="Firmware notes attached.", files=["notes.txt"], confirm=True)
    check("the same text with the same file is", "Refused" in dup, dup)
```

- [ ] **Step 3: Run the suite — verify it fails**

Expected: FAIL on every `comment attachments` check (`files` isn't in the schema yet, so each call is refused with an unknown-argument error or ignores the file).

- [ ] **Step 4: Client — `post_multipart`**

In `lib/gorelo.rb`, add `require 'securerandom'` to the requires. Add below `post`:

```ruby
    # multipart/form-data upload. The body is built in memory, so a request
    # retried after a 429 sends the same bytes again. Files are capped at
    # 44 MB before this is called.
    def post_multipart(path, fields, file_path)
      guard_writes!
      boundary = "gorelo-mcp-#{SecureRandom.hex(16)}"
      name     = File.basename(file_path).gsub(/["\r\n\\]/, '_')
      body     = String.new(encoding: Encoding::BINARY)
      fields.each do |k, v|
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n".b
      end
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{name}\"\r\n" \
              "Content-Type: application/octet-stream\r\n\r\n".b
      body << File.binread(file_path) << "\r\n--#{boundary}--\r\n".b
      request(Net::HTTP::Post, path, raw_body: body,
                                     content_type: "multipart/form-data; boundary=#{boundary}")
    end
```

Change `def request(klass, path, query: {}, body: nil, raw: false)` to `def request(klass, path, query: {}, body: nil, raw: false, raw_body: nil, content_type: nil)`, and replace:

```ruby
      if body
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end
```

with:

```ruby
      if raw_body
        req['Content-Type'] = content_type
        req.body = raw_body
      elsif body
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end
```

- [ ] **Step 5: Comment tool — `files`**

In `lib/gorelo_tools.rb`, add `require 'digest'` to the requires, and add directly above `def add_ticket_comment`:

```ruby
  ATTACH_MAX_BYTES = 44 * 1024 * 1024 # Gorelo's documented upload limit

  def attach_dir = File.expand_path(ENV['GORELO_ATTACH_DIR'] || '~/gorelo-attachments')

  # Only files a person deliberately put in GORELO_ATTACH_DIR can be attached.
  # Ticket text is untrusted input the assistant reads; without this, a crafted
  # ticket could talk it into attaching ~/.ssh/id_rsa or this project's .env to
  # a comment. realpath resolves `..`, `~` and symlinks BEFORE the containment
  # check, so none of them can step outside. Returns [path, nil] or [nil, why].
  def attachment_path(name)
    root = begin
      File.realpath(attach_dir)
    rescue SystemCallError
      return [nil, "the attachment folder #{attach_dir} does not exist - create it and put the file there"]
    end
    real = begin
      File.realpath(File.expand_path(name.to_s, root))
    rescue SystemCallError
      return [nil, "#{name}: no such file in #{root}"]
    end
    return [nil, "#{name}: outside #{root} - only files in that folder can be attached"] unless real.start_with?("#{root}/")
    return [nil, "#{name}: not a regular file"] unless File.file?(real)

    size = File.size(real)
    return [nil, "#{name}: the file is empty"] if size.zero?
    return [nil, "#{name}: #{(size / 1_048_576.0).round(1)} MB is over Gorelo's 44 MB limit"] if size > ATTACH_MAX_BYTES

    [real, nil]
  end

  def orphans(uploaded)
    return '' if uploaded.empty?

    "\n⚠ Already uploaded to the ticket and now referenced by nothing (the API has no way to " \
      "remove them): #{uploaded.map { |u| u['Name'] }.join(', ')}."
  end
```

In `add_ticket_comment`:

Replace the first line of the description, `Post a comment on a ticket. This is the ONLY tool that writes anything.`, with `Post a comment on a ticket, optionally with files attached.` and add to its `Safety:` list:

```
          - files are attached ONLY from GORELO_ATTACH_DIR (default ~/gorelo-attachments),
            max 44 MB each, and every file is checked before anything is uploaded
```

Add to `properties`:

```ruby
          files:      { type: 'array', items: { type: 'string' }, maxItems: 10,
                        description: 'Optional. Names of files in GORELO_ATTACH_DIR (default ~/gorelo-attachments) to attach. Nothing outside that folder can be attached.' },
```

Replace:

```ruby
      key = api.fingerprint(t['Id'], args['body'].strip, type_id)
```

with:

```ruby
      checked  = Array(args['files']).map { |f| attachment_path(f) }
      problems = checked.filter_map { |_, why| why }
      next "Refused - nothing was posted or uploaded:\n  #{problems.join("\n  ")}" unless problems.empty?

      paths = checked.map(&:first)
      # With no files this is the same fingerprint as before, so the 24-hour
      # duplicate guard carries on across the upgrade.
      key = api.fingerprint(t['Id'], args['body'].strip, type_id,
                            *paths.map { |p| Digest::SHA256.file(p).hexdigest })
```

Replace:

```ruby
      payload = { 'ConversationTypeId' => type_id, 'Body' => to_html(args['body']) }
```

with:

```ruby
      # Uploads first: the comment references what they return.
      uploaded = []
      failure  = nil
      paths.each do |p|
        d = api.post_multipart('/v1/attachments', { 'itemType' => 'Ticket', 'itemId' => t['Id'] }, p)['Data']
        uploaded << { 'Name' => d['Name'], 'Url' => d['Url'] }
      rescue Gorelo::Error => e
        failure = "Uploading #{File.basename(p)} failed: #{e.message}"
        break
      end
      next "Nothing was posted. #{failure}#{orphans(uploaded)}" if failure

      payload = { 'ConversationTypeId' => type_id, 'Body' => to_html(args['body']) }
      payload['Attachments'] = uploaded unless uploaded.empty?
```

In the rescue added in Task 7, change `next "Nothing was posted. #{e.message}"` to `next "Nothing was posted. #{e.message}#{orphans(uploaded)}"`.

Replace the success return:

```ruby
      "Posted #{internal ? 'a PRIVATE (internal) note' : 'a PUBLIC, client-visible comment'} " \
        "to #{t['DisplayNumber']} - #{t['Title']}."
```

with:

```ruby
      out = "Posted #{internal ? 'a PRIVATE (internal) note' : 'a PUBLIC, client-visible comment'} " \
            "to #{t['DisplayNumber']} - #{t['Title']}."
      unless uploaded.empty?
        out += "\nWith #{uploaded.size} attachment(s): #{uploaded.map { |u| u['Name'] }.join(', ')}."
        out += ' The client can see them.' unless internal
      end
      out
```

- [ ] **Step 6: Run the suite — verify it passes**

Expected: `… passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add lib/gorelo.rb lib/gorelo_tools.rb test/mock_gorelo.py test/drive.py
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Let gorelo_add_ticket_comment attach files - only from one folder" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Server instructions, `.env.example`, README, live smoke check

**Files:**
- Modify: `gorelo-mcp-server.rb`, `.env.example`, `README.md`

**Interfaces:**
- Consumes: everything above. Produces: documentation only.

- [ ] **Step 1: Server instructions**

In `gorelo-mcp-server.rb`, replace the header line `#   GORELO_ALLOW_WRITES  "true" enables the two write tools. Default off.` with:

```ruby
#   GORELO_ALLOW_WRITES  "true" enables the four write tools. Default off.
#   GORELO_DOWNLOAD_DIR  where invoice PDFs are saved. Default ~/gorelo-invoices
#   GORELO_ATTACH_DIR    the ONLY folder comment attachments come from.
#                        Default ~/gorelo-attachments
```

Change `VERSION = '1.0.0'` to `VERSION = '1.1.0'`. In the instructions heredoc, replace:

```
    Only gorelo_add_ticket_comment and gorelo_update_ticket write, and both are off
    unless explicitly enabled.
```

with:

```
    INVOICES created here are ALWAYS Drafts; approving one pushes it to the accounting
    system and is left to a person in Gorelo. Downloading an invoice PDF is recorded by
    Gorelo as an export event on that invoice, so do not download one just to read it.

    Four tools write - gorelo_add_ticket_comment, gorelo_update_ticket,
    gorelo_set_uptime_maintenance and gorelo_create_draft_invoice - and all are off
    unless explicitly enabled. Nothing here can delete anything.
```

- [ ] **Step 2: `.env.example`**

Replace `# When false, gorelo_add_ticket_comment and gorelo_update_ticket refuse every call.` with `# When false, every write tool refuses every call.` and append:

```
# Optional. Where gorelo_get_invoice_pdf saves PDFs. Default ~/gorelo-invoices
# GORELO_DOWNLOAD_DIR=

# Optional. The ONLY folder gorelo_add_ticket_comment can attach files from.
# Default ~/gorelo-attachments. Put a file here on purpose to attach it.
# GORELO_ATTACH_DIR=
```

- [ ] **Step 3: README**

Make each of these edits in `README.md`:

1. `**Sixteen tools, fourteen of them read-only.**` → `**Twenty-three tools, nineteen of them read-only.**`
2. Configuration table: `— only one tool writes.` → `— only four tools write.`; `` `true` enables the two write tools. Off by default. `` → `` `true` enables the four write tools. Off by default. ``; and add two rows:

```
| `GORELO_DOWNLOAD_DIR` | Where `gorelo_get_invoice_pdf` saves PDFs. Defaults to `~/gorelo-invoices`. |
| `GORELO_ATTACH_DIR` | The **only** folder comment attachments can come from. Defaults to `~/gorelo-attachments`. |
```

3. Tool table: after the `gorelo_work_types` row add:

```
| `gorelo_list_invoices` | | Invoices by client, status, contract or date — names the ones approved but never emailed, and the overdue |
| `gorelo_get_invoice_pdf` | | Saves an invoice PDF to a local folder. ⚠ Gorelo logs every download as an export event |
| `gorelo_get_contract` | | One contract group in full: schedule, service lines, labour terms, line items |
| `gorelo_list_items` | | The product and bundle catalogue with category, tax and margin; a bundle against its parts |
| `gorelo_list_uptime` | | Uptime checks and their maintenance windows — names the ones that never expire |
```

change the `gorelo_add_ticket_comment` row's text to `Adds a comment, optionally with files from one folder. Off by default.`, and after the `gorelo_update_ticket` row add:

```
| `gorelo_set_uptime_maintenance` | **yes** | Starts or ends a maintenance window on one check — nothing else. Off by default. |
| `gorelo_create_draft_invoice` | **yes** | Raises a manual invoice, always as a Draft. Off by default. |
```

4. Insert immediately above `### There is no DELETE, anywhere`:

````markdown
#### `gorelo_set_uptime_maintenance`

Starts or ends a maintenance window on **one** uptime check, and sends **only**
`MaintenanceMode` — never the target, type, client or tags. A check in maintenance raises no
alerts, so the risk here is silence, not damage:

- `start` needs a **reason** and a **duration** (1–10,080 minutes). A duration of `0` means the
  window never ends, so it can only be sent with **`indefinite: true`** — never from a default,
  a missing value or a typo.
- The PATCH has no "updated by" field, so the reason is prefixed **`[Gorelo MCP]`**.
- The check is read back, as `gorelo_update_ticket` does, because this API accepts and ignores
  fields it doesn't recognise.

`gorelo_list_uptime` names every window that never expires or has run more than seven days.

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
- The POST returns only an id and there is no `GET /v1/invoices/{id}`, so the tool lists that
  client's invoices created since just before the call and finds the id — then reports the
  number, status and totals as Gorelo computed them.

**A server error on a POST is never retried** — for invoices and comments alike. A 5xx says
nothing about whether the write was applied, and retrying a POST that *was* applied raises a
second invoice. The reply says it *may* exist, and the fingerprint is recorded so a repeat is
refused. A 429 is still retried: a rate-limited request was never processed.

#### Attachments on `gorelo_add_ticket_comment`

`files` attaches files to a comment, uploading them first with `POST /v1/attachments`. **Only
files in `GORELO_ATTACH_DIR`** (default `~/gorelo-attachments`) can be attached. Ticket text is
untrusted input the assistant reads; without a fixed folder, a crafted ticket could talk it
into attaching `~/.ssh/id_rsa` or this project's `.env` to a public comment. Paths are resolved
with `realpath` **before** the check, so `..`, `~` and symlinks can't step outside. Each file
must be under Gorelo's 44 MB limit, and every check runs before any upload.

If an upload or the comment fails after some files were uploaded, those files stay on the
ticket with nothing referencing them — the API has no way to remove them — and the reply names
them.

````

5. In `### There is no DELETE, anywhere`: change the first sentence's list to end `…private comments and time entries — and, since 25 September 2026, invoices, contracts, items and uptime checks.`; change `` `Gorelo::Client` has `get`, `post` and `patch` methods `` to `` `Gorelo::Client` has `get`, `get_binary`, `post`, `post_multipart` and `patch` methods ``; change `Leave both write tools off` to `Leave the write tools off`.
6. Endpoint list: after the `/v1/work-types` line add:

```
/v1/invoices                      GET, POST   ← since 2026-09-25. POST used for Drafts only
/v1/invoices/{id}/pdf             GET   ← since 2026-09-25. A file, not the envelope
/v1/contracts/{id}                GET   ← since 2026-09-25. Service lines with line items
/v1/items | /{id} | /categories   GET   ← since 2026-09-25
/v1/taxes                         GET   ← since 2026-09-25. Small, unpaginated
/v1/uptime | /{id}                GET, PATCH (MaintenanceMode only)  ← since 2026-09-25
```

7. In `### The 25 September 2026 release`, replace `The same release added invoices, the item catalogue, taxes, full contract detail, uptime checks and a general attachment upload. They aren't used by this server yet.` with:

```markdown
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
```

8. In `## Tests`, replace `104 assertions` with the pass count the suite prints now.

- [ ] **Step 4: Run the suite — verify it still passes**

Expected: `… passed, 0 failed`. Use that number in README edit 8.

- [ ] **Step 5: Live smoke check (read-only)**

Run each read tool once against the live tenant configured in `.env`, and eyeball the output:

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"gorelo_list_invoices","arguments":{"limit":5}}}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gorelo_list_items","arguments":{"limit":5}}}' \
 '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"gorelo_list_uptime","arguments":{"limit":5}}}' \
 '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"gorelo_list_contracts","arguments":{"limit":1}}}' \
 | ruby gorelo-mcp-server.rb 2>/dev/null | python3 -c "import json,sys; [print(json.loads(l)['result']['content'][0]['text'][:700], '\n---') for l in sys.stdin if '\"content\"' in l]"
```

Then run `gorelo_get_contract` with the first id printed by `gorelo_list_contracts`. **Do not** run `gorelo_get_invoice_pdf` or any write tool against the live tenant without asking the user first: a PDF download logs an export event on a real invoice.

Expected: each tool returns rows with no error. If the real field shapes differ from the mock (a missing key, an unexpected type), fix the tool, add a fixture reproducing the real shape to the mock, and rerun the suite.

- [ ] **Step 6: Commit**

```bash
git add gorelo-mcp-server.rb .env.example README.md
git -c user.name="Bryce" -c user.email="brycetelfer@gmail.com" commit -m "Document the 25 September tools, their guards, and what the release changed" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
