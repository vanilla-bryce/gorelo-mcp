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
  GUID = Gorelo::Client::GUID

  def register(server, api)
    list_invoices(server, api)
    get_invoice_pdf(server, api)
    get_contract(server, api)
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
end
