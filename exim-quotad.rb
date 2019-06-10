#!/usr/bin/env ruby

# Documentation:
# https://github.com/boesemar/exim-quotad

###################################################################
#####################   CUSTOMIZE HERE    #########################
###################################################################

DIRECTORY = '/var/exim-quotad'
EMAIL_DIRECTORY = "/var/vmail/%domain%/%local_part%/"
DEFAULT_QUOTA = 5000 * 1000 * 1000  # 5 GB
QUOTA_DIRECTORY = '/etc/exim4/quota-per-domain'
LISTEN_PORT = 2626
LISTEN_PORT_DEBUG = 2627   # if called with -d

CACHE_TIME = 300	# how long to keep quota before re-calculating

WARNING_LIMIT = 0.9	# If quota is > that availabel one this will send the warning email

# Do not apply quota if sender matches this REGEX
WHITELIST_SENDER_REGEX = /mailprovider-123.xyz$/


# Define the blocked email, telling a customer that we don't accept more email.
#  You can use %used% , %limit%, %percent% and %email% placeholders
BLOCKED_EMAIL_SUBJECT = "URGENT: Quota Exceeded"
BLOCKED_EMAIL_FROM = "Email Service <noreply@mailprovider-123.xyz>"
BLOCKED_EMAIL_BODY = <<-TEND

This is an automated message by your email provider.

You have exceeded your Mailbox quote for Email %email% .

You are using %used%.
Your limit is %limit%.

Please delete old emails from the server! At this moment no new email
can be received.

We recommend to setup your email client to delete emails from the server
at least after 14 days once they are downloaded. Please refer to the
settings of your email client how this can be done.

TEND



# Define the warning email. You can use %used% , %limit%, %percent% and %email% placeholders
WARNING_EMAIL_SUBJECT = "WARNING: Low storage for your email"
WARNING_EMAIL_FROM = "Email Service <noreply@mailprovider-123.xyz>"
WARNING_EMAIL_BODY = <<-TEND
This is an automated message by the ITA email service.

You are running low on storage for your email %email% .

You are currently using %percent% of your available storage space of %limit%.

Please ugently delete old emails from the server - once the limit is reached
we will not be able to accept new email.

We recommend to setup your email client to delete emails from the server
at least after 60 days once they are downloaded. Please refer to the
settings of your email client how this can be done.

TEND


###################################################################
##################### DON'T CHANGE BELOW  #########################
###################################################################

require 'socket'

$debug = ARGV.include?('-d')

def log(txt)
  File.open("#{DIRECTORY}/exim-quotad.log", 'a') do |file|
    file << "#{Time.now.to_s} : #{txt}\n"
  end
  if $debug then
    STDOUT.puts(txt)
    STDOUT.flush
  end
end

############### Warning stuff ######################
def state_file(email, type='warning')
 "#{DIRECTORY}/in_#{type}/#{email}"
end

def in_state?(email, type='warning')
  return File.exist?(state_file(email, type))
end

def enter_state(email,type)
  File.open(state_file(email, type),'w') do |f|
    f << Time.now.to_s
  end
end

def leave_state(email, type)
  fn = state_file(email, type)
  File.unlink(fn) if File.exist?(fn)
end

def bytes2gb(bytes)
  "%.2f GB" % (bytes.to_f / (1000 * 1000 * 1000))
end

# This will deliver one email using the mail command
def send_email(to, from, subject, body, variables)
  m = body
  s = subject
  variables.each do |k,v|
    m = m.gsub("%#{k}%", v)
    s = s.gsub("%#{k}%", v)
  end

  log "#{to} - Sending email '#{s}'\n#{m}"

  IO.popen(["mail", "-s", s, "-a",
            "From: #{from}", to],"r+") do |io|
     io.write m
     io.close_write
     io.close

     if $?.to_i != 0 then
       log "#{to} - Error sending email - mail command failed"
     end
  end
end


def send_blocked_email(email, used, limit)
  return if in_state?(email, 'blocked')

  used = check_size(email2directory(email),1_000_000_000_000)

  send_email(email, BLOCKED_EMAIL_FROM, BLOCKED_EMAIL_SUBJECT, BLOCKED_EMAIL_BODY,
     { 'limit' => bytes2gb(limit),
       'used'  => bytes2gb(used),
       'percent' => ("%.2f" % (used.to_f/limit)),
       'email' => email
     })
end

# this will send the warning email
def send_warning_email(email, used, limit)
  return if in_state?(email, 'warning')
  rate = (used.to_f / limit)

  send_email(email, WARNING_EMAIL_FROM, WARNING_EMAIL_SUBJECT, WARNING_EMAIL_BODY,
     {
       'limit' => bytes2gb(limit),
       'used' => bytes2gb(used),
       'percent' => ("%.2f%" % (rate*100)),
       'email' => email
     })
end


class Memcache
  def initialize
    @data = {}
  end

  def value(key, ttl = 300, &block)
    v = @data[key] || {:ttl=>0,:val => nil}

    if (v[:ttl] < Time.now.to_i) then
      new_value = block.call
      @data[key] = { :ttl=>(Time.now.to_i + ttl), :val => new_value }
    end
    @data[key][:val]
  end
end

class QuotaError < StandardError; end
class QuotaExceeded < StandardError; end

# walking directory, checking size, until max
def check_size(directory, max, total_counted=0)
  cur_size = 0

  Dir.foreach(directory).each do |last_part|

    next if last_part == '.'
    next if last_part == '..'

    f = directory + '/' + last_part
    if File.directory?(f) then
      cur_size += check_size(f, max, total_counted + cur_size)
    else
      cur_size += File.size(f)
    end

    if (total_counted + cur_size) > max then
      raise QuotaExceeded, "Limit reached, stopped counting at: #{total_counted + cur_size}"
    end
  end
  cur_size
end

# returns the data directory for one email account
def email2directory(email)
  u, d = email.split('@').map { |x| x.downcase }
  ed = EMAIL_DIRECTORY
  ed = ed.gsub('%domain%', d)
  ed = ed.gsub('%local_part%', u)
  ed
end

# expect a file "quota-per-domain" that looks like:
#  domaina.com:2000		# 2GB for domaina.com
#  domainb.com:1000
def get_limit_for_domain(domain)
  File.read(QUOTA_DIRECTORY).split(/\n/).each do |line|
     line = line.strip
     next if line.strip[0] == '#'
     line = line.split('#').first		# allow comments
     next if line.empty?
     if line =~ /^(.*):(\d+)/ then
       d = $1
       q = $2
       if d.strip.downcase == domain.downcase then
         return q.to_i * (1000 * 1000)
       end
     end
  end
  return DEFAULT_QUOTA
end


begin
  if $debug then
    server = TCPServer.open(LISTEN_PORT_DEBUG)
    puts "Listening on #{LISTEN_PORT_DEBUG} for debug purpose"
  else
    server = TCPServer.open(LISTEN_PORT)
  end
rescue => e
  STDERR.puts " Can't open socket"
  exit
end

mc = Memcache.new
loop do
  Thread.fork(server.accept) do |client|
#  begin
#    client = server.accept

    command = client.gets.strip.downcase
    if command =~ /^check_quota\s(.*)/ then
      email_and_sender = $1.strip

      email = email_and_sender.split(' ')[0]
      sender = email_and_sender.split(' ')[1]

      if sender.to_s =~ WHITELIST_SENDER_REGEX then
        log "#{email} Whitelist sender: #{sender}"
        quota = {:defined_quota => nil, :used => 0, :result => :whitelist }
      else
        log "#{email} - Checking Quota"


        quota = mc.value(email, CACHE_TIME) do
          result = {:defined_quota => nil, :used => 0, :result => :undefined }

          log "#{email} - Recalculating..."
          u, d = email.split('@').map { |x| x.downcase }
          defined_quota = get_limit_for_domain(d)
          result[:defined_quota] =  defined_quota

          log "#{email} - Limit for #{d} = #{bytes2gb(defined_quota)}"
          dir = email2directory(email)
          log "#{email} - directory is: #{dir}"
          if !File.directory?(dir) then
            log  "#{email} - Can't find user directory #{dir}"
            next result
          end

          size = 0
          begin
            size = check_size(dir, defined_quota)		# check size raises QuotaExceed if counting is above defined_quota
            result[:used] = size
            if (size.to_f / defined_quota) > WARNING_LIMIT then
              result[:result] = :warn
            else
              result[:result] = :good
            end
          rescue QuotaExceeded => e
            result[:used] = result[:defined_quota]
            result[:result] = :block
          end
          result
        end

        log "#{email} - #{bytes2gb(quota[:used])}/#{bytes2gb(quota[:defined_quota])} - #{quota[:result].inspect}"
        case quota[:result]
        when :good then
          leave_state(email, 'warning')
          leave_state(email, 'blocked')
        when :warn then
          send_warning_email(email, quota[:used], quota[:defined_quota])
          leave_state(email, 'blocked')
          enter_state(email, 'warning')
        when :block then
          send_blocked_email(email, quota[:used], quota[:defined_quota])
          enter_state(email, 'blocked')
          leave_state(email, 'warning')
        end

      end # if whitelist

      log "#{email} Result: #{quota[:result] == :block ? 'BLOCK' : 'ACCEPT'}"
      client.print quota[:result] == :block ? "1" : "0"	# 0 == OK, 1 = NO QUOTA
    elsif command =~ /^ping/i then
      client.puts "pong!"
    else
      client.puts "Unknown command"
    end
    client.close
  end
end
