# frozen_string_literal: true

require 'net/http'
require 'nokogiri'
require 'rbconfig'
require 'relaton'

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
  # Skip the write when the bytes are unchanged, so a corpus that is
  # re-downloaded daily produces no git churn.
  File.write file, resp if !File.exist?(file) || File.binread(file) != resp
rescue => e # rubocop:disable Style/RescueStandardError
  warn "Fetching document error #{ref}"
  warn e.message
  warn e.backtrace
end

workers = Relaton::Core::WorkersPool.new 10

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

# Keep the YAML siblings in step with the (possibly updated) corpus so
# the Pages index build has relaton YAML to read.
system(RbConfig.ruby, File.expand_path('bibxml_to_yaml.rb', __dir__))

t2 = Time.now
puts "Stopped at: #{t2}"
puts "Done in: #{(t2 - t1).round} sec."
