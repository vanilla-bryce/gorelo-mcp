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
end
