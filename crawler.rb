# frozen_string_literal: true

require 'net/http'
require 'nokogiri'
require 'relaton_bib'

def fetch_document(uri, attempts)
  begin
    resp = Net::HTTP.get uri
  rescue Net::OpenTimeout => e
    raise e if attempts <= 1

    resp = fetch_document uri, attempts - 1
  end
  resp
end

def get_document(ref)
  file = 'data/' + ref.split('/').last
  # if File.exist? file
  #   warn "File #{file} exist"
  #   return
  # end

  resp = fetch_document URI(ref), 3
  File.write file, resp # , encoding: 'UTF-8'
rescue => e # rubocop:disable Style/RescueStandardError
  warn "Fetching document error #{ref}"
  warn e.message
  warn e.backtrace
end

workers = RelatonBib::WorkersPool.new 10

workers.worker { |ref| get_document(ref) }
t1 = Time.now
puts "Started at: #{t1}"

%w[bibxml bibxml2 bibxml3 bibxml4 bibxml5 bibxml6 bibxml-rfcsubseries].each do |dir|
  url = "https://xml2rfc.tools.ietf.org/public/rfc/#{dir}/"
  resp = Net::HTTP.get URI(url)
  index = Nokogiri::HTML resp
  index.xpath('//a[starts-with(@href, "reference")]').each do |ref|
    workers << url + ref[:href]
  end
end

workers.end
workers.result

t2 = Time.now
puts "Stopped at: #{t2}"
puts "Done in: #{(t2 - t1).round} sec."
