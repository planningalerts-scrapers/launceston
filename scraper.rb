require "scraperwiki"
require "mechanize"
require "date"

agent = Mechanize.new

if ENV["MORPH_AUSTRALIAN_PROXY"]
  # On morph.io set the environment variable MORPH_AUSTRALIAN_PROXY to
  # http://morph:password@au.proxy.oaf.org.au:8888 replacing password with
  # the real password.
  puts "Using Australian proxy..."
  agent.agent.set_proxy(ENV["MORPH_AUSTRALIAN_PROXY"])
end

base_url = "https://onlineservice.launceston.tas.gov.au/eProperty/P1/PublicNotices/PublicNoticeDetails.aspx"
public_notices_url = base_url + "?r=P1.LCC.WEBGUEST&f=%24P1.ESB.PUBNOTAL.ENQ"
public_notice_details_url = base_url + "?r=P1.LCC.WEBGUEST&f=%24P1.ESB.PUBNOT.VIW&rf=%24P1.ESB.PUBNOTAL.ENQ&ApplicationId="

puts "Fetching public notices list from: #{public_notices_url}"
page = agent.get(public_notices_url)

records = []

# Find all grid tables and extract basic information
page.search("table.grid").each do |table|
  record = {
    "date_scraped" => Date.today.to_s,
  }

  table.search("tr").each do |tr|
    header_cell = tr.at("td.headerColumn")
    next unless header_cell

    header = header_cell.inner_text.strip
    next if header.empty?

    value_cell = header_cell.next_element
    next unless value_cell

    case header
    when "Application ID"
      link = value_cell.at("a")
      next unless link

      record["council_reference"] = link.inner_text.strip
      record["info_url"] = public_notice_details_url + URI.encode_www_form_component(record["council_reference"])
    when "Application Description"
      record["description"] = value_cell.inner_text.strip
    when "Property Address"
      # Clean up address format to match Python version
      address = value_cell.inner_text.strip
      record["address"] = address.gsub(/\sTAS\s+(7\d{3})$/, ', TAS, \1')
    end
  end

  records << record if record["council_reference"]
end

puts "Found #{records.length} public notices"

# Process each record to get detailed information
records.each do |record|
  # Check if we already have this record
  begin
    existing = ScraperWiki.select("* from data where council_reference = ?", record["council_reference"])
    if existing && existing.length > 0
      puts "Skipping existing record: #{record['council_reference']}"
      next
    end
  rescue StandardError => e
    # Table doesn't exist yet - this is fine for the first run
    raise e unless e.message.include?("no such table")
  end

  puts "Scraping Public Notice - Application Details for #{record['council_reference']}"

  begin
    detail_page = agent.get(record["info_url"])

    # Extract additional details from the detail page
    detail_page.search("table.grid").each do |table|
      table.search("tr").each do |tr|
        header_cell = tr.at("td.headerColumn")
        next unless header_cell

        header = header_cell.inner_text.strip
        next if header.empty?

        value_cell = header_cell.next_element
        next unless value_cell

        value = value_cell.inner_text.strip
        # Skip empty cells (containing only &nbsp; or similar)
        next if value == "\u00A0" || value.empty?

        case header
        when "Property Legal Description"
          record["legal_description"] = value
        when "Application Received"
          begin
            record["date_received"] = Date.strptime(value, "%d/%m/%Y").to_s
          rescue Date::Error => e
            puts "Warning: Could not parse date '#{value}' for Application Received: #{e.message}"
          end
        when "Advertised On"
          begin
            record["on_notice_from"] = Date.strptime(value, "%d/%m/%Y").to_s
          rescue Date::Error => e
            puts "Warning: Could not parse date '#{value}' for Advertised On: #{e.message}"
          end
        when "Advertised Close"
          begin
            record["on_notice_to"] = Date.strptime(value, "%d/%m/%Y").to_s
          rescue Date::Error => e
            puts "Warning: Could not parse date '#{value}' for Advertised Close: #{e.message}"
          end
        end
      end
    end

    # Save the record
    ScraperWiki.save_sqlite(["council_reference"], record)
    puts "Saved record for #{record['council_reference']}"
  rescue StandardError => e
    puts "Error processing #{record['council_reference']}: #{e.message}"
    raise e
  end
end

puts "Scraping complete"
