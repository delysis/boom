#!/usr/bin/env ruby
# Build-only projection. YAML's actual quoted-scalar semantics are required;
# ad hoc line extraction would silently alter the user's supplied prompts.
require 'yaml'
require 'json'
require 'digest'
require 'tempfile'
manifest_path, source_path, destination = ARGV
abort 'Usage: blessenger-catalog.rb MANIFEST SOURCE OUTPUT' unless ARGV.length == 3
manifest = JSON.parse(File.binread(manifest_path))
bytes = File.binread(source_path)
abort 'Catalog source hash mismatch' unless Digest::SHA256.hexdigest(bytes) == manifest.fetch('sourceSHA256')
source = YAML.safe_load(bytes.force_encoding('UTF-8'), permitted_classes: [], permitted_symbols: [], aliases: false)
abort 'Invalid catalog' unless source.is_a?(Array) && source.length == 14
entries = manifest.fetch('entries').map do |entry|
  matches = source.select { |item| item.is_a?(Hash) && item['id'] == entry.fetch('sourceID') }
  abort 'Missing or ambiguous Contact' unless matches.length == 1
  item = matches.first
  prompt = item.fetch('system_prompt')
  abort 'Changed decoded prompt' unless prompt.is_a?(String) && Digest::SHA256.hexdigest(prompt) == entry.fetch('promptSHA256')
  abort 'Changed Contact name' unless item.fetch('name') == entry.fetch('name')
  entry.merge('instructions' => prompt)
end
result = {'sourceRevision' => manifest.fetch('sourceRevision'), 'sourceSHA256' => manifest.fetch('sourceSHA256'), 'entries' => entries}
stage = Tempfile.new('.blessenger-catalog-', File.dirname(destination))
begin
  stage.write(JSON.pretty_generate(result)); stage.write("\n"); stage.flush; stage.fsync; stage.close
  File.rename(stage.path, destination)
ensure
  stage.close! if File.exist?(stage.path.to_s)
end
