require "time"
require "cgi"

Given(/^I've set max size to (\d+)$/) do |size|
  @server.opts[:max_size] = size.to_i
end

Given(/^I've set expiration time to (\d+) seconds?$/) do |seconds|
  @server.opts[:expiration_time] = seconds.to_i
end

Given(/^I've set disposition to "(.+)"$/) do |disposition|
  @server.opts[:disposition] = disposition
end

Given(/^I've registered an? (\w+) hook$/) do |hook|
  context = self
  @server.public_send(hook) do |uid, info|
    context.assert_instance_of String,    uid
    context.assert_instance_of Tus::Info, info
    context.assert_kind_of     Roda,      self

    context.instance_variable_set(:"@#{hook}_called", true)
  end
end

Given(/^a file$/) do |data|
  headers, input = data.split("\n\n")
  step "I've created a file", headers
  step "I append \"#{input}\" to the created file"
end

Given(/^I've created a file$/) do |data|
  data = ["Tus-Resumable: 1.0.0", data].join("\n")
  step "I make a POST request to /files", data
  assert_equal 201, @response.status, "file failed to be created"
  (@uids ||= []) << @response.location.split("/").last
end

Given(/^download URL is enabled$/) do
  @server.opts[:redirect_download] = true
  @server.opts[:storage].instance_eval do
    def file_url(uid, info, content_type:, content_disposition:)
      "https://example.org/file?content_type=#{CGI.escape(content_type)}&content_disposition=#{CGI.escape(content_disposition)}"
    end
  end
end

Given(/^download URL is defined$/) do
  @server.opts[:redirect_download] = lambda do |uid, info, content_type:, content_disposition:|
    "https://example.org/file?content_type=#{CGI.escape(content_type)}&content_disposition=#{CGI.escape(content_disposition)}"
  end
end

When(/^I create a file$/) do |data|
  step "I've created a file", data
end

When(/^I make an? (\w+) request to (\S+)$/) do |verb, path, data|
  headers, input = data.split("\n\n")
  headers = headers.to_s.split("\n").map { |line| line.split(": ", 2) }.to_h
  @response = request(verb, path, headers: headers, input: input)
end

When(/^I append "(.+)" to the created file$/) do |input|
  response = request(:head, "/files/#{@uids.last}", headers: { "Tus-Resumable" => "1.0.0" })
  offset   = response.headers["Upload-Offset"] || "0"

  step "I make a PATCH request to the created file", <<-EOS.chomp
Tus-Resumable: 1.0.0
Upload-Offset: #{offset}
Content-Type: application/offset+octet-stream

#{input}
  EOS
  assert_equal 204, @response.status, "failed to append to the file"
end

When(/^I send a concatenation request for the created files$/) do
  step "I make a POST request to /files", <<-EOS.chomp
Tus-Resumable: 1.0.0
Upload-Concat: final;#{@uids.map{|uid|"http://example.com/files/#{uid}"}.join(" ")}
  EOS
  @concatenated_uid = @response.location.split("/").last if @response.status == 201
end

When(/^I delete the created file$/) do
  step "I make a DELETE request to the created file", <<-EOS.chomp
Tus-Resumable: 1.0.0
  EOS
end

When(/^I make an? (\w+) request to the created file$/) do |verb, data|
  raise "no reference to the created file" if @uids.empty?
  step "I make a #{verb} request to /files/#{@uids.last}", data
end

When(/^I make an? (\w+) request to the concatenated file$/) do |verb, data|
  step "I make a #{verb} request to /files/#{@concatenated_uid}", data
end

Then(/^I should see response status "(\d+).*"$/) do |status|
  assert_equal status.to_i, @response.status
end

Then(/^I should see response headers$/) do |headers|
  response_headers = @response.headers.map { |name, value| "#{name}: #{value}" }.join("\n")
  assert_includes response_headers, headers
end

Then(/^I should not see "(\S+)" response header$/) do |name|
  refute_includes @response.headers.keys, name
end

Then(/^I should see "(.+)"$/) do |body|
  assert_equal body, @response.body_binary
end

Then(/^"(\S+)" response header should match "(.+)"$/) do |name, regex|
  assert_match Regexp.new(regex), @response.headers.fetch(name)
end

Then(/^the expiration date should be refreshed$/) do
  expiration = Time.parse(@response.headers["Upload-Expires"])
  assert_in_delta Time.now + @server.opts[:expiration_time], expiration, 1
end

Then(/^the (\w+) hook should have been called$/) do |hook|
  assert_equal true, instance_variable_get(:"@#{hook}_called")
end

Then(/^the (\w+) hook should not have been called$/) do |hook|
  assert_nil instance_variable_get(:"@#{hook}_called")
end
