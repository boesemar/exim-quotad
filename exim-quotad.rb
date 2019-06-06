#!/usr/bin/env ruby



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

# Do not apply quota if sender matches this REGEX
WHITELIST_SENDER_REGEX = /mailprovider-123.xyz$/

# Define the warning email. You can use %used% , %limit% and %email% placeholders
WARNING_EMAIL_SUBJECT = "Warning: Quota Exceeded"
WARNING_EMAIL_FROM = "Email Service <noreply@mailprovider-123.xyz>"
WARNING_EMAIL_BODY = <<-TEND
This is an automated message from your friendly email service provider.

You have exceeded your Mailbox quote for Email %email% .

You are using %used%.
Your limit is %limit%.

Please delete old emails from the server! At this moment no new email
can be received.

We recommend to setup your email client to delete emails from the server
at least after 14 days once they are downloaded. Please refer to the
settings of your email client how this can be done.

Any questions, please give us a call at 123132123

Email: support@mailprovider-123.xyz

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
# if a user account has no quote we'll send a warning email
# and remember that we are in warning state by creating one
# file in the in_warning directory.
#
def warning_file(email)
  "#{DIRECTORY}/in_warning/#{email}"
end

def in_warning?(email)
  return File.exist?(warning_file(email))
end

def enter_warning(email)
  File.open(warning_file(email),'w') do |f|
    f << Time.now.to_s
  end
end

def leave_warning(email)
  fn = warning_file(email)
  File.unlink(fn) if File.exist?(fn)
end

def bytes2gb(bytes)
  "%.2f GB" % (bytes.to_f / (1000 * 1000 * 1000))
end

# This will deliver the warning email if not yet done.
def check_warning(email)
  return if in_warning?(email)

  used = check_size(email2directory(email),1_000_000_000_000)
  limit = get_limit_for_domain(email.split('@').last)

  message = WARNING_EMAIL_BODY

  message = message.gsub('%limit%', bytes2gb(limit))
  message = message.gsub('%used%', bytes2gb(used))
  message = message.gsub('%email%', email)

  log "#{email} - Sending warning: \n #{message}"

  IO.popen(["mail", "-s", WARNING_EMAIL_SUBJECT, "-a",
            "from: #{WARNING_EMAIL_FROM}", email],"r+") do |io|
     io.write message
     io.close_write
     io.close

     if $?.to_i != 0 then
       log "#{email} - Error sending email - mail command failed"
     end
  end

  enter_warning(email)
end

class Memcache
  require 'dalli'
  def initialize
    @dalli = Dalli::Client.new('localhost:11211:10', :threadsafe => true)
  end

  def set(key,value,ttl=300)
    begin
      @dalli.set(key, value, ttl)
    rescue Dalli::RingError => e
      return false
    end
  end

  def get(key)
    begin
      @dalli.get(key)
    rescue Dalli::RingError => e
      return nil
    end
  end

  def value(key,ttl=300,&block)
    old_value = get(key)
    return old_value unless old_value.nil?
    new_value = block.call
    if !set(key,new_value, ttl) then
      new_value
    end
    new_value
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

# returns true or false weather user has quota or not
def check_quota(email)
  u, d = email.split('@').map { |x| x.downcase }
  defined_quota = get_limit_for_domain(d)
  log "#{email} - Limit for #{d} = #{bytes2gb(defined_quota)}"
  dir = email2directory(email)
  log "#{email} - directory is: #{dir}"
  if !File.directory?(dir) then
    raise QuotaError, "Can't find user directory #{dir}"
  end
  begin
    size = check_size(dir, defined_quota)
    log "#{email} - using #{bytes2gb(size)} - OK"
  rescue QuotaExceeded => e
    log "#{email} - check_quota: Quota Exceeded"
    return false
  end
  true
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

loop do
  Thread.fork(server.accept) do |client|
#  begin
#    client = server.accept
    mc = Memcache.new


    command = client.gets.strip.downcase
    if command =~ /^check_quota\s(.*)/ then
      email_and_sender = $1.strip

      email = email_and_sender.split(' ')[0]
      sender = email_and_sender.split(' ')[1]

      whitelist = false

      if sender.to_s =~ WHITELIST_SENDER_REGEX then
        log "#{email} Whitelist sender: #{sender}"
        quota = true
      else
        log "#{email} - Checking Quota"
        quota = mc.value(email, CACHE_TIME) do
          log "#{email} - Recalculating..."
          result  = begin
             check_quota(email)
          rescue QuotaError => e
             log "#{email} - Error: #{e}"
             true
          end
          result
        end

        if !quota then
          check_warning(email)
        else
          leave_warning(email)
        end
      end

      log "#{email} Result: #{quota ? 'GOOD' : 'QUOTA-EXCEEDED'}"
      client.print quota ? "0" : "1"	# 0 == OK, 1 = NO QUOTA
    elsif command =~ /^ping/i then
      client.puts "pong!"
    else
      client.puts "Unknown command"
    end
    client.close
  end
end
