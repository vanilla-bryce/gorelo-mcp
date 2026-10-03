#!/usr/bin/env python3
"""Drive the MCP server over real JSON-RPC frames on stdin/stdout.

Start the mock first, in another terminal:

    python3 mock_gorelo.py

Then:

    python3 drive.py                 # run the built-in checks
    python3 drive.py calls.json      # run a list of tool calls from a file

With no argument it runs an assertion suite covering the cases that have
actually broken: merged tickets, unlisted statuses, assisting assignees,
watchers, closed-ticket exclusion, ticket lookup by number, deleted comments,
the write guards, and the protocol edge cases.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "gorelo-mcp-server.rb")

ENV = dict(os.environ)
ENV.update({
    "GORELO_API_KEY": os.environ.get("KEY", "test-key-123"),
    "GORELO_BASE_URL": "http://127.0.0.1:8899",
    "GORELO_MY_EMAIL": "sam@example.com",
    "GORELO_ALLOW_WRITES": os.environ.get("WRITES", "false"),
    "GORELO_READ_TIMEOUT": "3",
    "HOME": os.path.join(HERE, "_tmp_home"),
    "GORELO_DOWNLOAD_DIR": os.path.join(HERE, "_tmp_home", "downloads"),
    "GORELO_ATTACH_DIR": os.path.join(HERE, "_tmp_home", "gorelo-attachments"),
})
os.makedirs(ENV["HOME"], exist_ok=True)
import shutil
shutil.rmtree(ENV["GORELO_DOWNLOAD_DIR"], ignore_errors=True)
WRITE_LOG = os.path.join(ENV["HOME"], ".gorelo-mcp-writes.jsonl")
if os.path.exists(WRITE_LOG):
    os.remove(WRITE_LOG)


class Server:
    def __init__(self):
        self.p = subprocess.Popen(
            ["ruby", SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=ENV, text=True, bufsize=1)
        self.n = 0
        self.rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "drive.py", "version": "1"}}})
        self.notify({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def rpc(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise SystemExit("server closed stdout - is the mock running?")
        return json.loads(line)

    def notify(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def call(self, name, **args):
        self.n += 1
        r = self.rpc({"jsonrpc": "2.0", "id": 100 + self.n, "method": "tools/call",
                      "params": {"name": name, "arguments": args}})
        return r["result"]["content"][0]["text"]

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=30)
        return self.p.stderr.read()


def last_query(path):
    """The query string the mock last received for a GET on `path`."""
    url = ENV["GORELO_BASE_URL"] + "/__debug/last-query?" + urllib.parse.urlencode({"path": path})
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def te_query():
    return last_query("/v1/time-entries")


def last_body(path):
    """The JSON body the mock last received for a POST or PATCH on `path`."""
    url = ENV["GORELO_BASE_URL"] + "/__debug/last-body?" + urllib.parse.urlencode({"path": path})
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def hits(path):
    """How many POSTs the mock has received on `path`."""
    url = ENV["GORELO_BASE_URL"] + "/__debug/hits?" + urllib.parse.urlencode({"path": path})
    with urllib.request.urlopen(url) as r:
        return json.load(r)["count"]


def debug(route, **params):
    url = ENV["GORELO_BASE_URL"] + "/__debug/" + route + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def uploads():
    with urllib.request.urlopen(ENV["GORELO_BASE_URL"] + "/__debug/uploads") as r:
        return json.load(r)


PASS, FAIL = 0, 0


def check(label, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("  ok   %s" % label)
    else:
        FAIL += 1
        print("  FAIL %s   %s" % (label, detail))


def run_suite():
    s = Server()

    tools = s.rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
    names = [t["name"] for t in tools]
    check("25 tools advertised", len(tools) == 25, names)
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
    check("exactly six tools write, and none can delete",
          sorted(t["name"] for t in tools if not t["annotations"]["readOnlyHint"])
          == ["gorelo_add_ticket_comment", "gorelo_create_draft_invoice",
              "gorelo_set_uptime_maintenance", "gorelo_update_ticket",
              "gorelo_update_time_entries", "gorelo_update_time_entry"])
    te_props = next(t for t in tools if t["name"] == "gorelo_update_time_entry")["inputSchema"]["properties"]
    check("the time entry tool exposes no hours, dates, user, role or ticket",
          sorted(te_props) == ["append_comment", "billable_status", "comment", "confirm",
                               "expected_updated_on", "id", "service_line_id", "work_type"],
          sorted(te_props))
    inv_props = next((t for t in tools if t["name"] == "gorelo_create_draft_invoice"),
                     {"inputSchema": {"properties": {"status": 1}}})["inputSchema"]["properties"]
    check("a draft invoice has no status parameter - approving stays a human action",
          not any(k.lower() in ("status", "statusid", "approve", "approved") for k in inv_props),
          sorted(inv_props))
    check("and no recipient-email parameter",
          not any("email" in k.lower() for k in inv_props), sorted(inv_props))

    print("\ncounting")
    everything = s.call("gorelo_list_tickets", status="all", limit=300)
    check("merged tickets excluded and named", "14 merged tickets excluded" in everything,
          everything.splitlines()[:4])
    check("unlisted status is reported, not dropped",
          "Waiting Vendor" in everything and "did not list" in everything)
    check("assisting assignees counted", "9 as assisting assignee" in everything)

    base_line = next((l for l in everything.splitlines() if l.startswith("Breakdown by base status")), "")
    check("statuses in the new BaseStatus {Id, Name} shape are understood (Gorelo, 3 Oct 2026)",
          "Closed" in base_line and "Open" in base_line, base_line)
    active = s.call("gorelo_list_tickets", status="active", limit=300)
    check("a status still in the old BaseStatusId shape is understood too",
          "Quote Required" in active, active[:600])
    watch = s.call("gorelo_list_tickets", status="open", limit=300)
    check("watcher-only ticket excluded", "Watching only" not in watch)
    check("closed-assist tickets excluded", "Closed assist" not in watch)

    closed = s.call("gorelo_list_tickets", status="closed", limit=5)
    check("closed view skips the assisting sweep", "as assisting assignee" not in closed)

    opted_out = s.call("gorelo_list_tickets", status="all", include_assisting=False, limit=5)
    check("include_assisting=false honoured", "as assisting assignee" not in opted_out)

    print("\nfiltering")
    solved = s.call("gorelo_list_tickets", status="solved", limit=50, include_reasons=True)
    check("solved base includes Billing and Standing",
          "Billing" in solved and "Standing Ticket" in solved)
    check("status reason JSON is unwrapped", "needs invoicing" in solved and
          '"updatedById"' not in solved)

    stale = s.call("gorelo_list_tickets", status="all", stale_days=1000, limit=5)
    check("stale_days filters everything out", "Showing 0 of 0" in stale)

    two_terms = s.call("gorelo_search_clients", term="adventure,awx")
    check("comma-separated client terms are OR-ed",
          "Adventure Works" in two_terms and "AWX Holdings" in two_terms)
    awx = s.call("gorelo_search_clients", term="AWX")
    check("an inactive client is found, and marked (inactive)",
          "AWX Holdings (inactive)" in awx and "Adventure Works (inactive)" not in two_terms, awx)
    check("clients are fetched with StatusIds including 2 (inactive)",
          "2" in last_query("/v1/clients").get("StatusIds", "").split(","), last_query("/v1/clients"))
    check("get_client marks an inactive client too",
          "AWX Holdings (inactive)" in s.call("gorelo_get_client", client="AWX", include_devices=False))

    print("\nticket lookup (no API support for number or search)")
    open_one = s.call("gorelo_get_ticket", ticket="G-1000")
    check("open ticket found by number", "Open work item 1" in open_one)
    check("comments render with author", "Dana Ellis" in open_one)
    check("private comment flagged", "PRIVATE" in open_one)
    check("gorelo truncation flagged", "TRUNCATED" in open_one)
    check("attachments counted", "1 attachment(s)" in open_one)
    check("DELETED comment body withheld",
          "SENSITIVE-MUST-NOT-BE-PRINTED" not in open_one and "deleted in Gorelo" in open_one)

    closed_one = s.call("gorelo_get_ticket", ticket="G-1060", include_comments=False)
    check("merged/other ticket found via widened index", "G-1060" in closed_one)

    missing = s.call("gorelo_get_ticket", ticket="G-999999", include_comments=False)
    check("unknown number fails clearly", "No ticket" in missing)

    print("\n2026-08-21 API changes")
    # Every one of these renames fails SILENTLY: the field simply vanishes and
    # nothing errors. That is the whole reason they are asserted rather than
    # trusted to the release notes.
    detail = s.call("gorelo_get_ticket", ticket="G-1000", include_comments=False)
    check("time breakdown surfaced from the new get-by-id",
          "1.75h recorded" in detail and "2.00h to invoice" in detail, detail[:600])
    check("billable split shown", "billable 2.00h" in detail, detail[:600])
    zero_time = s.call("gorelo_get_ticket", ticket="G-1060", include_comments=False)
    check("a ticket with NO time recorded is called out",
          "NO TIME RECORDED" in zero_time, zero_time[:600])
    check("WarrantyEndDate (renamed from WarrantyExpiryDate) still renders",
          "warranty/term ends 2026-09-30" in
          s.call("gorelo_list_assets", search="ContractEnd", limit=20))
    legacy = s.call("gorelo_list_assets", search="2027-01-15", limit=20)
    check("the PRE-rename WarrantyExpiryDate is still read as a fallback",
          "warranty/term ends 2027-01-15" in legacy, legacy[:400])
    filtered = s.call("gorelo_list_assets", client="Northwind", limit=50)
    check("assets are filtered by ClientIds server-side, not by paging the fleet",
          "client=Northwind" in filtered and "WS-011" not in filtered, filtered[:300])

    print("\nbilling review")
    review = s.call("gorelo_billing_review", status="Billing", assignee="anyone", limit=25)
    check("billable tickets separated from untimed ones",
          "READY TO INVOICE" in review and "NO TIME RECORDED" in review, review[:400])
    check("billable hours totalled", "2.00h billable" in review, review[:600])
    check("a zero-time ticket lands in the untimed group, not the invoice group",
          review.index("NO TIME RECORDED") < review.rindex("G-"), review[:200])
    check("the per-ticket request cost is stated",
          "extra request(s) for the time breakdown" in review, review[:200])
    none = s.call("gorelo_billing_review", status="NoSuchStatus")
    check("an unknown status names the real ones", "No Gorelo status matches" in none)

    print("\ntime report - rebuilt on /v1/time-entries (Gorelo, 4 Sep 2026)")
    tr = s.call("gorelo_time_report", assignee="anyone", days=400)
    check("recorded / invoiceable / billable totalled",
          "TOTAL" in tr and "realisation" in tr, tr[:400])
    # The tool used to print "Gorelo has NO per-user time API" on every run, and
    # to call per-person totals "indicative". Both were true until 4 Sep 2026 and
    # are false now. A corrected README beside a stale caveat is worse than
    # either alone, so the absence is asserted.
    check("the retired 'no per-user time API' caveat is gone",
          "no per-user time API" not in tr and "indicative" not in tr, tr[:1200])
    check("per-person figures are stated as exact, and why",
          "Per-person figures are EXACT" in tr and "assisting time lands on whoever" in tr,
          tr[:900])
    rows_returned = int(re.search(r"(\d+) time entry row\(s\) returned", tr).group(1))
    check("cursor pagination is exercised - more entries than one 200-row page",
          rows_returned > 200, rows_returned)
    check("both technicians appear, so assisting time is not booked to the lead",
          "Sam Rivers" in tr and "Alex Kim" in tr, tr[:900])
    check("every BillableStatus is shown with its hours, not just the billable one",
          "No charge" in tr and "Non-billable" in tr and "counted billable" in tr, tr[:1400])
    status_rows = {l.split("  ")[0].strip(): l for l in tr.splitlines() if "to invoice" in l and "entr(ies)" in l}
    check("Non-billable is NOT counted billable, though the word contains 'billable'",
          "Non-billable" in status_rows and status_rows["Non-billable"].rstrip().endswith("not billable")
          and "counted billable" not in status_rows["Non-billable"]
          and status_rows["Billable"].rstrip().endswith("counted billable"), status_rows)
    check("realisation is adjusted/actual, with the billable share as its own column",
          "Real." in tr and "Bill%" in tr, tr[:1200])
    check("non-billable hours are itemised, not just percentaged",
          "NON-BILLABLE" in tr, tr[-900:])
    check("the request cost is measured and is no longer one per ticket",
          "request(s) in total" in tr and
          "extra request(s) for the time breakdown" not in tr, tr[:400])

    # The reserved fixture client has three entries: 3.50h recorded, 3.70h to
    # invoice, 2.50h billable. One has AdjustedHours NULL - no rounding applied,
    # so it bills its ActualHours - and reading that null as zero was a bug.
    wing = s.call("gorelo_time_report", assignee="anyone", days=400, client="Wingtip")
    check("a client filter is sent as ClientIds, not resolved by sweeping tickets",
          "ClientIds" in wing and "sweep of /v1/tickets" not in wing
          and "ClientIds" in te_query(), wing[:700])
    check("per-client totals are exact",
          "3.50h recorded" in wing and "3.70h to invoice" in wing
          and "2.50h billable" in wing, wing[:900])
    check("a NULL AdjustedHours bills its ActualHours, not zero",
          "3.70h to invoice" in wing and "3.20h to invoice" not in wing, wing[:900])
    narrow = s.call("gorelo_time_report", assignee="anyone", days=3, client="Wingtip")
    sent = te_query()
    check("the window is sent as the documented StartedSince, not the old CreatedSince guess",
          "StartedSince" in sent and "CreatedSince" not in sent, sent)
    check("the window holds", "2.50h recorded" in narrow, narrow[:800])
    check("the retired 'unverified parameter' hedging is gone",
          "unverified" not in narrow and "IGNORED" not in narrow, narrow[:800])

    two = s.call("gorelo_time_report", assignee="anyone", days=400, client="Wingtip,Contoso",
                 group_by="client")
    tq = last_query("/v1/tickets")
    check("grouping several clients sweeps only THEIR tickets, not the whole tenant",
          set(tq.get("ClientIds", "").split(",")) == {"11002", "11006"}, tq)
    check("and every entry is resolved to one of them",
          "Contoso" in two and "Wingtip" in two and "CLIENT UNRESOLVED" not in two
          and "tickets of those 2 clients" in two, two[:1200])

    alex = s.call("gorelo_time_report", assignee="alex", days=400, group_by="technician")
    check("an assignee filter keeps only that technician's own entries",
          "Alex Kim" in alex and "Sam Rivers" not in alex, alex[:900])
    check("and is sent as UserIds rather than filtered locally",
          te_query().get("UserIds") == "3001", te_query())

    capped = s.call("gorelo_time_report", assignee="anyone", days=400, limit=2)
    check("an entry cap is stated loudly, not silently applied",
          "were NOT included" in capped, capped[-300:])

    print("\ncontracts - API and UI now use the same words")
    RENAME_NOTE = 'Gorelo renamed these on 3 Oct 2026: a contract was a "Contract Group" and a service line was a "Contract" on older screens and exports.'
    ct = s.call("gorelo_list_contracts")
    check("the 3 Oct rename is stated once, not per row",
          ct.count(RENAME_NOTE) == 1 and "INVERTED" not in ct and "UI:" not in ct, ct[:400])
    check("service lines are listed under their contract",
          "Managed Desktop - 42 seats" in ct and "Backup Monitoring" in ct, ct[:900])
    check("recurring amount, cost and margin are shown and totalled",
          "27140.00" in ct and "16440.00" in ct and "10700.00" in ct, ct[-300:])
    check("a contract with no service lines is flagged, not shown as normal",
          "NO SERVICE LINES" in ct, ct[:1200])
    one = s.call("gorelo_list_contracts", client="Contoso")
    check("contracts filter by client",
          "Contoso Backup and DR" in one and "Northwind" not in one, one[:400])
    expired = s.call("gorelo_list_contracts", status="expired")
    check("contracts filter on a status name fragment, locally",
          "Tailspin Hardware Lease" in expired and "5001" not in expired, expired[:400])

    print("\nbilling roles and work types")
    br = s.call("gorelo_billing_roles")
    check("billing roles carry the sell rate, COA code and tax",
          "Service Desk Engineer" in br and "165.00" in br and "GST on Income" in br, br)
    check("the rate is tied to ADJUSTED hours, not recorded ones", "ADJUSTED hours" in br, br)
    wt = s.call("gorelo_work_types")
    check("multiplier and per-entry minimum are both shown",
          "2.50x" in wt and "Min mins" in wt, wt[:600])
    check("the two fields that change the invoice are explained, not just printed",
          "change the invoice without changing the recorded hours" in wt
          and "15-minute floor per entry" in wt, wt[-500:])
    check("the out-of-hours default work type is identified",
          "After Hours" in wt and "YES" in wt, wt[:800])

    print("\nindividual time entries")
    te = s.call("gorelo_list_time_entries", ticket="G-1000", days=30)
    # The case the old report got wrong: two people logged time on one ticket,
    # and all of it used to be attributed to the lead assignee.
    check("two technicians on one ticket are listed separately",
          "Sam Rivers" in te and "Alex Kim" in te and "2 time entr(ies)" in te, te[:500])
    check("hours are per entry, not a per-ticket total",
          "1.75h  2.00h" in te and "0.50h  0.60h" in te, te[:1000])
    check("the technician's own comment survives", "Assisted with the mailbox" in te, te[:1000])
    check("service line is plain, with the rename note once",
          "service line (UI: contract)" not in te and "service line Managed Desktop" in te
          and te.count(RENAME_NOTE) == 1, te[:1000])
    check("a ticket filter is sent as TicketIds", "TicketIds" in te_query(), te_query())
    mine = s.call("gorelo_list_time_entries", ticket="G-1000", user="alex", days=30)
    check("a per-user filter works on a ticket led by somebody else",
          "Alex Kim" in mine and "Sam Rivers" not in mine, mine[:500])
    wt3 = s.call("gorelo_list_time_entries", client="Wingtip", days=3)
    check("entries filter by client",
          "2 time entr(ies)" in wt3 and "2.50h recorded, 2.50h to invoice" in wt3, wt3[:500])
    check("an unrounded entry shows its billed hours, not 0.00h",
          "0.50h  0.50h" in wt3 and "0.50h  0.00h" not in wt3, wt3[:900])
    nb = s.call("gorelo_list_time_entries", days=400, billable="other", limit=5)
    check("non-billable entries can be isolated",
          "non-billable only" in nb and "0.00h billable" in nb, nb[:400])
    nosuch = s.call("gorelo_list_time_entries", ticket="G-999999", days=30)
    check("an unknown ticket is named, not reported as zero hours",
          "No ticket matches" in nosuch, nosuch)
    empty = s.call("gorelo_list_time_entries", client="Wingtip", user="alex", days=3)
    check("an empty result says how many rows it looked at",
          "No time entries" in empty and "came back from /v1/time-entries" in empty, empty)

    # The API ignores names it does not recognise. If it ever stops honouring
    # UserIds or TicketIds, the rows are re-checked locally and the reply says so.
    def total_line(text):
        return next((l for l in text.splitlines() if l.startswith("TOTAL")), text[:300])
    base_rep = s.call("gorelo_time_report", assignee="alex", days=30)
    debug("ignore-filter", name="UserIds")
    try:
        mine2 = s.call("gorelo_list_time_entries", ticket="G-1000", user="alex", days=30)
        check("an ignored UserIds filter is re-applied locally, not trusted",
              "Alex Kim" in mine2 and "Sam Rivers" not in mine2, mine2[:600])
        check("and the reply names the filter the API did not honour",
              "do not match UserIds" in mine2, mine2[:600])
        rep2 = s.call("gorelo_time_report", assignee="alex", days=30)
        check("time_report re-applies an ignored UserIds too, and says so",
              total_line(rep2) == total_line(base_rep) and "do not match UserIds" in rep2,
              (total_line(base_rep), rep2[:900]))
    finally:
        debug("honour-filters")
    debug("ignore-filter", name="TicketIds")
    try:
        te2 = s.call("gorelo_list_time_entries", ticket="G-1000", days=30)
        check("an ignored TicketIds filter is re-applied locally, and named",
              "2 time entr(ies)" in te2 and "do not match TicketIds" in te2, te2[:600])
    finally:
        debug("honour-filters")

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
    one = s.call("gorelo_list_invoices", number="INV-1042")
    check("one invoice by number also shows its line items",
          "Line items" in one and "Managed desktop seat" in one and "Backup storage block" in one
          and "3570.00" in one, one)
    check("a multi-invoice listing does not fetch line items", "Line items" not in inv and "Line items" not in drafts, inv[:300])
    old = s.call("gorelo_list_invoices", number="INV-0901")
    check("a number finds an invoice outside the window",
          "INV-0901" in old and "InvoiceDateSince" not in last_query("/v1/invoices"), old[:400])
    ce = s.call("gorelo_list_invoices", client="Contoso")
    check("a client filter is sent as ClientIds",
          "INV-1043" in ce and "INV-1042" not in ce
          and last_query("/v1/invoices").get("ClientIds") == "11002", ce[:400])
    check("no match says so", "No invoices" in s.call("gorelo_list_invoices", number="INV-7777"))

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
    debug("ignore-filter", name="Number")
    try:
        loose = s.call("gorelo_get_invoice_pdf", invoice="INV-1042")
        check("an invoice number is matched exactly, even if Number is not honoured",
              "Saved INV-1042" in loose, loose)
        check("and a number nothing matches is still named, never the first row",
              "No invoice numbered 7777" in s.call("gorelo_get_invoice_pdf", invoice="INV-7777"))
    finally:
        debug("honour-filters")
    gone = s.call("gorelo_get_invoice_pdf", invoice="00000000-0000-4000-8000-000000000000")
    check("an unknown id surfaces Gorelo's 404, not an empty file", "404" in gone, gone)

    print("\ncontract detail")
    cd = s.call("gorelo_get_contract", contract="5001")
    check("the rename note is printed once, plain naming otherwise",
          cd.count(RENAME_NOTE) == 1 and "INVERTED" not in cd and "(UI: contract)" not in cd, cd[:400])
    check("line items are listed per service line",
          "Managed desktop seat" in cd and "3570.00" in cd, cd)
    check("automatic approve-and-send is flagged", "AUTO APPROVE AND SEND" in cd, cd[-900:])
    check("a block-hours balance at or under its warning threshold is flagged",
          "at or under its warning threshold" in cd, cd[-900:])
    check("a service line with no line items is flagged",
          "NO LINE ITEMS on service line 9003" in cd, cd[-900:])
    by_name = s.call("gorelo_get_contract", contract="contoso")
    check("a unique name fragment resolves", "Contract 5002" in by_name, by_name[:200])
    amb = s.call("gorelo_get_contract", contract="a")
    check("an ambiguous fragment lists candidates instead of guessing",
          "Give the id" in amb and "Contract 5" not in amb, amb)
    miss = s.call("gorelo_get_contract", contract="99999")
    check("an unknown id surfaces the 404", "404" in miss, miss)
    check("no tool description or contract output says INVERTED",
          not any("INVERTED" in t.get("description", "").upper() for t in tools)
          and not any("INVERTED" in x.upper() for x in (ct, cd, te, by_name, amb, miss)),
          [t["name"] for t in tools if "INVERTED" in t.get("description", "").upper()])

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
    kit = s.call("gorelo_list_items", item="Site survey kit")
    check("a bundle part with no price makes the sum unknown, never zero",
          "unknown (1 part(s) have no price)" in kit and "unknown (1 part(s) have no cost)" in kit
          and "BELOW its parts" not in kit and "above its parts" not in kit, kit)

    print("\nuptime checks")
    up = s.call("gorelo_list_uptime")
    blank = next((l for l in up.splitlines() if "192.0.2.55" in l), "")
    check("a check with no description is labelled by its target, not left blank",
          blank.startswith("192.0.2.55 (no description)"), blank)
    check("and its id is shown so it can always be selected",
          "0b700000-0000-4000-8000-000000000005" in up, up[-900:])
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

    print("\nresponse times")
    rr = s.call("gorelo_response_report", days=400, assignee="anyone", target_minutes=60)
    check("median, 90th and worst reported", "median" in rr and "90th pct" in rr, rr[:400])
    check("business minutes stated, not wall clock",
          "BUSINESS minutes" in rr and "weekends excluded" in rr, rr[:300])
    check("breaches named individually", "OVER TARGET" in rr, rr[-800:])
    # A ticket with no SLA node must be counted, not silently dropped - dropping
    # them would improve every other figure in the report.
    check("tickets with no first-response record are reported, not dropped",
          "NO FIRST-RESPONSE RECORD" in rr and "excluded from every figure" in rr, rr[-500:])
    by_group = s.call("gorelo_response_report", days=400, group_by="group")
    check("can split by group, which is how brands/desks are modelled",
          "Second Brand" in by_group and "By group" in by_group, by_group[:600])

    print("\nassets")
    assets = s.call("gorelo_list_assets", stale_days=100, limit=50)
    check("stale devices found", "WS-000" in assets)
    fresh = s.call("gorelo_list_assets", client="Northwind", limit=50)
    check("client filter applied locally", "WS-001" in fresh and "WS-011" not in fresh)
    contracts = s.call("gorelo_list_assets", search="ContractEnd", limit=20)
    check("Description is searchable and shown",
          "ContractEnd Sep2026" in contracts and "Term Concluded" in contracts,
          contracts[:400])
    check("warranty/term date surfaced", "warranty/term ends 2026-09-30" in contracts)

    print("\nwrite guards (writes disabled)")
    check("write refused when disabled",
          "Writes are disabled" in s.call("gorelo_add_ticket_comment",
                                          ticket="G-1000", body="x", confirm=True))
    check("update_ticket refused when disabled",
          "Writes are disabled" in s.call("gorelo_update_ticket",
                                          ticket="G-1000", status="Closed", confirm=True))
    check("uptime maintenance refused when disabled",
          "Writes are disabled" in s.call("gorelo_set_uptime_maintenance", check="head office",
                                          action="start", minutes=60, reason="x", confirm=True))
    check("draft invoice refused when disabled",
          "Writes are disabled" in s.call("gorelo_create_draft_invoice", client="Fabrikam",
                                          lines=[{"item": "Managed desktop seat", "quantity": 1}],
                                          confirm=True))

    print("\nprobe")
    # The 2026-08-21 release added DELETE endpoints for tickets, clients,
    # contacts, assets and private comments. This server must never reach them.
    check("probe is GET-only - no method parameter is even accepted",
          "method" not in next(t for t in tools
                               if t["name"] == "gorelo_api_probe")["inputSchema"]["properties"])
    # 404 = no such route. 405 = the route exists but not for GET. Conflating
    # them concluded that time entries could not be read at all - which was
    # never what a 405 on ONE path meant, and which /v1/time-entries disproved
    # on 2026-09-04. A 405 maps a path and a verb, never a capability.
    m405 = s.call("gorelo_api_probe",
                  path="/v1/tickets/00000000-0000-0000-0000-000000001000/time-entries/abc")
    check("405 is explained as 'route exists, wrong verb', not treated as absent",
          "PATH EXISTS" in m405 and "does not accept GET" in m405, m405[:300])
    check("probe refuses non-/v1 paths",
          "Refused" in s.call("gorelo_api_probe", path="/etc/passwd"))
    check("probe returns pagination",
          "Pagination" in s.call("gorelo_api_probe", path="/v1/tickets", chars=300))

    print("\nprotocol")
    check("ping", s.rpc({"jsonrpc": "2.0", "id": 900, "method": "ping"})["result"] == {})
    check("unknown method is -32601",
          s.rpc({"jsonrpc": "2.0", "id": 901,
                 "method": "no/such"})["error"]["code"] == -32601)
    check("unknown tool is an isError result, not a protocol error",
          s.rpc({"jsonrpc": "2.0", "id": 902, "method": "tools/call",
                 "params": {"name": "nope", "arguments": {}}})["result"]["isError"])
    s.notify({"jsonrpc": "2.0", "method": "notifications/something"})
    s.p.stdin.write("this is not json\n")
    s.p.stdin.flush()
    check("survives a malformed line",
          s.rpc({"jsonrpc": "2.0", "id": 903, "method": "ping"})["result"] == {})

    stderr = s.close()

    s0 = Server()  # writes still disabled
    dis = s0.call("gorelo_update_time_entry", id=880001, work_type="Peer Assist", confirm=True)
    check("time entry update refused when writes are disabled",
          "Writes are disabled" in dis and hits("/v1/time-entries/880001") == 0, dis)
    check("time entry preview also refused when writes are disabled",
          "Writes are disabled" in s0.call("gorelo_update_time_entry", id=880001, work_type="Peer Assist"))
    check("batch time entry update refused when writes are disabled",
          "Writes are disabled" in s0.call("gorelo_update_time_entries",
                                           entries=[{"id": 880001, "work_type": "Peer Assist"}], confirm=True))
    s0.close()

    print("\nwrites ENABLED")
    ENV["GORELO_ALLOW_WRITES"] = "true"
    s2 = Server()
    check("confirm is required",
          "confirm" in s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                               body="note", confirm=False))
    check("empty body refused",
          "empty" in s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                             body="   ", confirm=True))
    first = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                    body="Intake review note.\n\nSecond <para> & more.", confirm=True)
    check("internal comment posted as PRIVATE",
          "PRIVATE" in first and "Posted" in first, first)
    again = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                    body="Intake review note.\n\nSecond <para> & more.", confirm=True)
    check("duplicate within 24h refused", "Refused" in again)
    visible = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                      body="Client visible note.", visibility="client", confirm=True)
    check("client-visible comment is labelled loudly",
          "PUBLIC, client-visible" in visible, visible)
    # The mock rejects unknown fields and a ConversationId on Public/Private,
    # so these passing proves the payload matches the documented schema.
    check("payload matches CreatePublicCommentCommand", "Posted" in visible)

    print("\nupdate_ticket")
    check("confirm required", "confirm must be true" in
          s2.call("gorelo_update_ticket", ticket="G-1000", status="Closed", confirm=False))
    check("nothing to do when no field given",
          "Nothing to do" in s2.call("gorelo_update_ticket", ticket="G-1000", confirm=True))
    check("an unknown status lists the real ones",
          "No status matches" in s2.call("gorelo_update_ticket", ticket="G-1000",
                                         status="Wibble", confirm=True))
    ok = s2.call("gorelo_update_ticket", ticket="G-1000", client="Contoso", confirm=True)
    check("a client change is applied AND verified by reading back",
          "Updated:" in ok and "Verified by reading the ticket back" in ok and
          "Contoso" in ok, ok[:400])
    # G-1002 is wired to ignore StatusId, standing in for a wrong field name.
    # The API returns success and changes nothing - which must NOT read as a win.
    silent = s2.call("gorelo_update_ticket", ticket="G-1002", status="Closed", confirm=True)
    check("a silently-ignored field is reported as a FAILED write, not a success",
          "DID NOT TAKE EFFECT" in silent and "Updated:" not in silent, silent[:400])
    check("the change is attributed so an automated edit never looks human",
          "UpdatedByName" in ok or "Updated:" in ok, ok[:200])
    check("and it names the likely cause and the payload sent",
          "field name in the PATCH payload is wrong" in silent and "StatusId" in silent,
          silent[:600])

    print("\nuptime maintenance")
    B = "/v1/uptime/0b700000-0000-4000-8000-000000000005"
    by_target = s2.call("gorelo_set_uptime_maintenance", check="192.0.2.55", action="start",
                        minutes=5, reason="Target test", confirm=True)
    check("a check with no description can be selected by its target",
          "Started maintenance on 192.0.2.55 (no description)" in by_target
          and "MaintenanceMode" in last_body(B), by_target)
    by_id = s2.call("gorelo_set_uptime_maintenance", check="0b700000-0000-4000-8000-000000000005",
                    action="end", confirm=True)
    check("and ended by the id the list shows", "Ended maintenance on 192.0.2.55" in by_id, by_id)
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
    # 10080 (not the coordinator's literal 20160) - the fixture's stored duration is
    # now 10080, the max the tool's own MAX_WINDOW_MINUTES allows; 20160 would be
    # refused by that guard before ever reaching the read-back logic under test.
    replaced = s2.call("gorelo_set_uptime_maintenance", check="Tailspin", action="start",
                       minutes=10080, reason="Rebuild extended", confirm=True)
    check("an ignored replacement window is caught, not reported as verified",
          "DID NOT TAKE EFFECT" in replaced and "Verified" not in replaced, replaced)

    # Guards: each is refused before anything is sent.
    b0 = last_body(U)
    for label, kw in [("minutes over a week", dict(minutes=10081)),
                      ("minutes AND indefinite", dict(minutes=60, indefinite=True)),
                      ("an unknown action", dict(action="pause", minutes=60))]:
        a = dict(check="head office", action="start", reason="Guard test", confirm=True)
        a.update(kw)
        r = s2.call("gorelo_set_uptime_maintenance", **a)
        check("refused, nothing sent: " + label,
              "Refused" in r and "Nothing was written" in r and last_body(U) == b0, r)
    # Contoso's check APPLIES a BOOM-500 change, then answers 500. That is a
    # write that landed; it must never be reported as refused.
    boomu = s2.call("gorelo_set_uptime_maintenance", check="client portal", action="start",
                    minutes=30, reason="BOOM-500 test", confirm=True)
    check("a PATCH that errors after landing is reported as MAY-have-been-applied",
          "MAY have been applied" in boomu and "refused" not in boomu, boomu)
    check("and the read-back state is reported, and says it matches",
          "BOOM-500 test" in boomu and "shows the change in effect" in boomu, boomu)
    check("and it is in the audit log as UNVERIFIED",
          any("UNVERIFIED" in l and "PATCH error" in l for l in open(WRITE_LOG)), "")
    restored = s2.call("gorelo_set_uptime_maintenance", check="client portal", action="end",
                       confirm=True)
    check("and it can be ended again", "Ended maintenance" in restored, restored)

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
    mlines = made.splitlines()
    bi = next((n for n, l in enumerate(mlines) if "New starter bundle" in l), -1)
    check("the read-back shows each line item with quantity, unit price and amount",
          any("Managed desktop seat" in l and "2.00" in l and "85.00" in l and "170.00" in l
              for l in mlines)
          and bi >= 0 and "1850.00" in mlines[bi], made)
    check("a bundle line shows its parts indented underneath it",
          bi >= 0 and "Dell Latitude 5450" in mlines[bi + 1] and "Microsoft 365 Business Premium" in mlines[bi + 2]
          and mlines[bi + 1].startswith("      ") and mlines[bi + 1].startswith(mlines[bi][:2]),
          made)
    check("the read-back no longer lists invoices by CreatedSince",
          "CreatedSince" not in last_query(P), last_query(P))
    h0 = hits(P)
    gone = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                   reference="VANISH", confirm=True)
    check("a read-back that 404s is reported loudly, and the POST is not retried",
          "could NOT be read back" in gone and "check in Gorelo before assuming it exists" in gone.replace("Check", "check")
          and "Verified" not in gone and hits(P) == h0 + 1, (gone, h0, hits(P)))
    check("and a repeat of it is refused", "Refused" in
          s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                  reference="VANISH", confirm=True))
    again = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                    reference="MCP-TEST", confirm=True)
    check("an identical invoice within 24h is refused",
          "Refused" in again and "already raised" in again, again)
    h0 = hits(P)
    same = s2.call("gorelo_create_draft_invoice", client="Fabrikam",
                   lines=[{"item": "Managed desktop seat", "quantity": 2.0},
                          {"item": "New starter bundle", "quantity": 1.0, "unit_price": 1850.0}],
                   reference="MCP-TEST", confirm=True)
    check("2 and 2.0 are the same quantity - the repeat is still refused",
          "already raised" in same and hits(P) == h0, same)
    h0 = hits(P)
    boom = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                   reference="BOOM-500", confirm=True)
    check("a server error after the POST is NOT retried", hits(P) == h0 + 1, (h0, hits(P)))
    check("and the reply says the invoice MAY exist", "MAY have been created" in boom, boom)
    check("and a repeat is refused", "Refused" in
          s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                  reference="BOOM-500", confirm=True))
    h0 = hits(P)
    slow = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                   reference="SLOW-POST", confirm=True)
    check("a POST that times out is treated as MAY-exist, not 'nothing was created'",
          "MAY have been created" in slow and "Nothing was created" not in slow
          and hits(P) == h0 + 1, slow)
    check("and a repeat after a timeout is refused", "Refused" in
          s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                  reference="SLOW-POST", confirm=True))
    h0 = hits(P)
    drop = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                   reference="DROP-POST", confirm=True)
    check("a POST whose connection drops with no reply MAY have been created, and is not retried",
          "MAY have been created" in drop and "Nothing was created" not in drop
          and hits(P) == h0 + 1, (drop, h0, hits(P)))
    check("and a repeat after a dropped connection is refused", "Refused" in
          s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                  reference="DROP-POST", confirm=True))
    h0 = hits(P)
    garble = s2.call("gorelo_create_draft_invoice", client="Fabrikam", lines=LINES,
                     reference="GARBLE-POST", confirm=True)
    check("a 2xx POST whose reply cannot be read MAY have been created, never 'nothing was created'",
          "MAY have been created" in garble and "Nothing was created" not in garble
          and hits(P) == h0 + 1, garble)
    CP = "/v1/tickets/00000000-0000-0000-0000-000000001000/comments"
    h0 = hits(CP)
    dropc = s2.call("gorelo_add_ticket_comment", ticket="G-1000", body="DROP-POST comment",
                    confirm=True)
    check("a comment whose connection drops with no reply MAY have been posted",
          hits(CP) == h0 + 1 and "MAY have been posted" in dropc, dropc)
    h0 = hits(CP)
    maybe = s2.call("gorelo_add_ticket_comment", ticket="G-1000", body="BOOM-500 comment",
                    confirm=True)
    check("a comment that fails after the POST is not retried, and may exist",
          hits(CP) == h0 + 1 and "MAY have been posted" in maybe, maybe)

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

    with open(os.path.join(ad, "boom.txt"), "w") as f:
        f.write("boom\n")
    c0, n0 = hits(CP), len(uploads())
    orphan = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                     body="Orphan test.", files=["notes2.txt", "boom.txt"], confirm=True)
    check("a failed upload names what MAY be uploaded and what is now orphaned, and posts nothing",
          "boom.txt MAY have been uploaded" in orphan and "notes2.txt" in orphan.split("referenced by nothing")[-1]
          and hits(CP) == c0 and len(uploads()) == n0 + 2, orphan)
    order1 = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                     body="Two files.", files=["notes.txt", "notes2.txt"], confirm=True)
    order2 = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                     body="Two files.", files=["notes2.txt", "notes.txt"], confirm=True)
    check("the same files in a different order are still a duplicate",
          "Posted" in order1 and "Refused" in order2, (order1, order2))
    check("more than 10 files is refused", "at most 10 files" in
          s2.call("gorelo_add_ticket_comment", ticket="G-1000", body="Too many.",
                  files=["notes.txt"] + ["x%d.txt" % i for i in range(10)], confirm=True))

    print("\ntime entry updates")
    E1 = "/v1/time-entries/880001"
    prev = s2.call("gorelo_update_time_entry", id=880001, work_type="Peer Assist",
                   billable_status="No charge")
    check("preview shows ticket, Brisbane date, tech, hours and current -> new",
          "PREVIEW ONLY" in prev and "G-1000" in prev and "Alex Kim" in prev and "1.00h" in prev
          and "Wed 30 Sep 2026 00:30 AEST" in prev
          and "Remote Support → Peer Assist" in prev and "Billable → No charge" in prev, prev)
    check("preview warns about re-pricing and prints expected_updated_on",
          "RE-PRICES" in prev and "expected_updated_on: 2026-09-30T01:00:00Z" in prev, prev)
    check("preview makes no PATCH", hits(E1) == 0, hits(E1))
    check("an unchanged value is not previewed as a change",
          "No change" in s2.call("gorelo_update_time_entry", id=880001, work_type="Remote Support"))
    for label, args in [("hours", {"hours": 2}), ("started_on", {"started_on": "2026-01-01"}),
                        ("user", {"user": "Sam"}), ("billing_role", {"billing_role": "Project Consultant"}),
                        ("ticket", {"ticket": "G-1000"}), ("TicketId", {"TicketId": "x"})]:
        r = s2.call("gorelo_update_time_entry", id=880001, work_type="Peer Assist", confirm=True, **args)
        check("disallowed key %s is refused with nothing written" % label,
              "Refused" in r and label in r and hits(E1) == 0, r)
    check("nothing to change is refused", "Nothing to do" in s2.call("gorelo_update_time_entry", id=880001, confirm=True))
    check("a non-numeric id is refused", "must be a time entry id" in
          s2.call("gorelo_update_time_entry", id="te-00001", work_type="Peer Assist", confirm=True))
    check("an unknown entry is reported", "No time entry 424242" in
          s2.call("gorelo_update_time_entry", id=424242, work_type="Peer Assist"))
    check("an unknown work type lists the available ones", "Available" in
          s2.call("gorelo_update_time_entry", id=880001, work_type="Nonsense"))
    check("an unknown billable status is refused", "No billable status matches" in
          s2.call("gorelo_update_time_entry", id=880001, billable_status="Free"))
    stale = s2.call("gorelo_update_time_entry", id=880001, work_type="Peer Assist", confirm=True,
                    expected_updated_on="2026-09-30T00:00:00Z")
    check("an expected_updated_on mismatch refuses and writes nothing",
          "changed since the preview" in stale and hits(E1) == 0, stale)
    both = s2.call("gorelo_update_time_entry", id=880001, comment="a", append_comment="b", confirm=True)
    check("comment and append_comment together are refused", "not both" in both and hits(E1) == 0, both)
    done = s2.call("gorelo_update_time_entry", id=880001, work_type="peer assist",
                   billable_status="no charge", confirm=True,
                   expected_updated_on="2026-09-30T01:00:00Z")
    check("confirm PATCHes once, with only the changed fields, resolving the name Peer Assist",
          hits(E1) == 1 and last_body(E1) == {"WorkTypeId": 6, "BillableStatusId": 2}, last_body(E1))
    check("the returned entry's new values are printed",
          "Updated." in done and "work type:       Peer Assist" in done
          and "billable status: No charge" in done and "2026-10-01T02:00:00Z" in done, done)
    again = s2.call("gorelo_update_time_entry", id=880001, work_type="Peer Assist", confirm=True)
    check("confirming an already-applied change sends nothing", "No change" in again and hits(E1) == 1, again)
    sl = s2.call("gorelo_update_time_entry", id=880001, service_line_id=9010, append_comment="Recoded to fixed labour.", confirm=True)
    check("service line and appended comment: only those fields sent",
          last_body(E1) == {"ServiceLineId": 9010, "Comment": "Assisted Sam with the switch.\nRecoded to fixed labour."}
          and "Offsite Backup - 2 TB" in sl, (last_body(E1), sl))
    E2 = "/v1/time-entries/880002"
    s2.call("gorelo_update_time_entry", id=880002, append_comment="Recoded <ok>", confirm=True)
    check("an HTML comment is appended as an escaped paragraph",
          last_body(E2) == {"Comment": "<p>Assisted Sam on site.</p><p>Recoded &lt;ok&gt;</p>"}, last_body(E2))
    inv = s2.call("gorelo_update_time_entry", id=880003, work_type="Peer Assist", confirm=True)
    check("Gorelo's 409 on an invoiced entry is reported, not hidden",
          "refused" in inv and "cannot be changed" in inv, inv)
    check("a WORKED write is in the audit log",
          "/v1/time-entries/880001" in open(WRITE_LOG).read())

    print("\nbatch time entry updates")
    E3 = "/v1/time-entries/880003"
    bp = s2.call("gorelo_update_time_entries", entries=[
        {"id": 880002, "work_type": "Peer Assist"}, {"id": 880001, "billable_status": "Void"}])
    check("batch preview lists every entry and writes nothing",
          "PREVIEW ONLY" in bp and "880002" in bp and "880001" in bp and hits(E2) == 1, bp)
    bad = s2.call("gorelo_update_time_entries", confirm=True, entries=[
        {"id": 880002, "work_type": "Peer Assist"}, {"id": 880001, "hours": 3}])
    check("one invalid entry refuses the whole batch", "nothing was written" in bad and hits(E2) == 1, bad)
    stop = s2.call("gorelo_update_time_entries", confirm=True, entries=[
        {"id": 880002, "work_type": "Peer Assist"}, {"id": 880003, "work_type": "Peer Assist"},
        {"id": 880001, "billable_status": "Void"}])
    check("batch applies in order and stops at the first error",
          "STOPPED at entry 880003" in stop and "Applied before it: 880002" in stop
          and "Not attempted: 880001" in stop and hits(E2) == 2 and hits(E3) == 2, stop)
    okb = s2.call("gorelo_update_time_entries", confirm=True, entries=[{"id": 880001, "billable_status": "Void"}])
    check("a clean batch reports what it applied", "Applied all 1 entry: 880001" in okb, okb)
    s2.close()
    ENV["GORELO_ALLOW_WRITES"] = "false"

    print("\n%d passed, %d failed" % (PASS, FAIL))
    if FAIL:
        print("\nserver stderr:\n" + stderr[-2000:])
    return 1 if FAIL else 0


def run_file(path):
    s = Server()
    for call in json.load(open(path)):
        print("\n" + "=" * 78)
        print("%s %s" % (call["name"], json.dumps(call.get("arguments", {}))))
        print("=" * 78)
        print(s.call(call["name"], **call.get("arguments", {})))
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(run_file(sys.argv[1]) if len(sys.argv) > 1 else run_suite())
