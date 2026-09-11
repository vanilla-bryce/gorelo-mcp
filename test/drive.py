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

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "gorelo-mcp-server.rb")

ENV = dict(os.environ)
ENV.update({
    "GORELO_API_KEY": os.environ.get("KEY", "test-key-123"),
    "GORELO_BASE_URL": "http://127.0.0.1:8899",
    "GORELO_MY_EMAIL": "sam@example.com",
    "GORELO_ALLOW_WRITES": os.environ.get("WRITES", "false"),
    "HOME": os.path.join(HERE, "_tmp_home"),
})
os.makedirs(ENV["HOME"], exist_ok=True)
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
    check("16 tools advertised", len(tools) == 16, names)
    check("exactly two tools write, and neither can delete",
          sorted(t["name"] for t in tools if not t["annotations"]["readOnlyHint"])
          == ["gorelo_add_ticket_comment", "gorelo_update_ticket"])

    print("\ncounting")
    everything = s.call("gorelo_list_tickets", status="all", limit=300)
    check("merged tickets excluded and named", "14 merged tickets excluded" in everything,
          everything.splitlines()[:4])
    check("unlisted status is reported, not dropped",
          "Waiting Vendor" in everything and "did not list" in everything)
    check("assisting assignees counted", "9 as assisting assignee" in everything)

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
          "No Charge" in tr and "Not Billable" in tr and "counted billable" in tr, tr[:1400])
    check("realisation is adjusted/actual, with the billable share as its own column",
          "Real." in tr and "Bill%" in tr, tr[:1200])
    check("non-billable hours are itemised, not just percentaged",
          "NON-BILLABLE" in tr, tr[-900:])
    check("the request cost is measured and is no longer one per ticket",
          "request(s) in total" in tr and
          "extra request(s) for the time breakdown" not in tr, tr[:400])

    # An entry carries Ticket {Id, Number, Title} and NO client at all, so a
    # per-client figure has to resolve the ticket. The reserved fixture client
    # has exactly two entries: 3.00h recorded, 3.20h to invoice, 2.00h billable.
    wing = s.call("gorelo_time_report", assignee="anyone", days=400, client="Wingtip")
    check("the client resolution is named, and costs one sweep rather than N fetches",
          "Entries carry no client" in wing and "ClientIds" in wing, wing[:700])
    check("per-client totals are exact",
          "3.00h recorded" in wing and "3.20h to invoice" in wing
          and "2.00h billable" in wing, wing[:900])
    narrow = s.call("gorelo_time_report", assignee="anyone", days=3, client="Wingtip")
    check("the window is enforced locally, because the endpoint ignores the filter",
          "2.00h recorded" in narrow and "IGNORED" in narrow, narrow[:800])
    check("the unverified window parameter says so rather than pretending",
          "unverified" in narrow, narrow[:800])

    alex = s.call("gorelo_time_report", assignee="alex", days=400, group_by="technician")
    check("an assignee filter keeps only that technician's own entries",
          "Alex Kim" in alex and "Sam Rivers" not in alex, alex[:900])

    capped = s.call("gorelo_time_report", assignee="anyone", days=400, limit=2)
    check("an entry cap is stated loudly, not silently applied",
          "were NOT included" in capped, capped[-300:])

    print("\ncontracts - API 'contract' is the UI's 'Contract Group'")
    ct = s.call("gorelo_list_contracts")
    check("the API/UI terminology inversion is stated on every run",
          'API "contract" = UI "Contract Group"' in ct
          and 'API "ServiceLine" = UI "Contract"' in ct, ct[:400])
    check("service lines are listed under their contract group",
          "Managed Desktop - 42 seats" in ct and "Backup Monitoring" in ct, ct[:900])
    check("recurring amount, cost and margin are shown and totalled",
          "27140.00" in ct and "16440.00" in ct and "10700.00" in ct, ct[-300:])
    check("a contract group with no service lines is flagged, not shown as normal",
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
    check("service line is labelled with the UI's word for it too",
          "service line (UI: contract)" in te, te[:1000])
    mine = s.call("gorelo_list_time_entries", ticket="G-1000", user="alex", days=30)
    check("a per-user filter works on a ticket led by somebody else",
          "Alex Kim" in mine and "Sam Rivers" not in mine, mine[:500])
    nb = s.call("gorelo_list_time_entries", days=400, billable="other", limit=5)
    check("non-billable entries can be isolated",
          "non-billable only" in nb and "0.00h billable" in nb, nb[:400])
    empty = s.call("gorelo_list_time_entries", ticket="G-999999", days=30)
    check("an empty result says how many rows it looked at",
          "No time entries" in empty and "came back from /v1/time-entries" in empty, empty)

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
