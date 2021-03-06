# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/
require 'net/imap'

class Channel::Driver::Imap < Channel::EmailParser

  def fetchable?(_channel)
    true
  end

=begin

fetch emails from IMAP account

  instance = Channel::Driver::Imap.new
  result = instance.fetch(params[:inbound][:options], channel, 'verify', subject_looking_for)

returns

  {
    result: 'ok',
    fetched: 123,
    notice: 'e. g. message about to big emails in mailbox',
  }

check if connect to IMAP account is possible, return count of mails in mailbox

  instance = Channel::Driver::Imap.new
  result = instance.fetch(params[:inbound][:options], channel, 'check')

returns

  {
    result: 'ok',
    content_messages: 123,
  }

verify IMAP account, check if search email is in there

  instance = Channel::Driver::Imap.new
  result = instance.fetch(params[:inbound][:options], channel, 'verify', subject_looking_for)

returns

  {
    result: 'ok', # 'verify not ok'
  }

example

  params = {
    host: 'outlook.office365.com',
    user: 'xxx@znuny.onmicrosoft.com',
    password: 'xxx',
    keep_on_server: true,
  }
  channel = Channel.last
  instance = Channel::Driver::Imap.new
  result = instance.fetch(params, channel, 'verify')

=end

  def fetch(options, channel, check_type = '', verify_string = '')
    ssl            = true
    starttls       = false
    port           = 993
    keep_on_server = false
    folder         = 'INBOX'
    if options[:keep_on_server] == true || options[:keep_on_server] == 'true'
      keep_on_server = true
    end

    if options.key?(:ssl) && options[:ssl] == false
      ssl  = false
      port = 143
    end

    port = if options.key?(:port) && options[:port].present?
             options[:port].to_i
           elsif ssl == true
             993
           else
             143
           end

    if ssl == true && port != 993
      ssl = false
      starttls = true
    end

    if options[:folder].present?
      folder = options[:folder]
    end

    Rails.logger.info "fetching imap (#{options[:host]}/#{options[:user]} port=#{port},ssl=#{ssl},starttls=#{starttls},folder=#{folder},keep_on_server=#{keep_on_server})"

    # on check, reduce open_timeout to have faster probing
    check_type_timeout = 45
    if check_type == 'check'
      check_type_timeout = 6
    end

    timeout(check_type_timeout) do
      @imap = ::Net::IMAP.new(options[:host], port, ssl, nil, false)
      if starttls
        @imap.starttls()
      end
    end

    timeout(check_type_timeout) do
      @imap.login(options[:user], options[:password])
    end

    timeout(check_type_timeout) do
      # select folder
      @imap.select(folder)
    end

    # sort messages by date on server (if not supported), if not fetch messages via search (first in, first out)
    filter = ['ALL']
    if keep_on_server && check_type != 'check' && check_type != 'verify'
      filter = %w[NOT SEEN]
    end

    message_ids = nil
    timeout(6.minutes) do
      begin
        message_ids = @imap.sort(['DATE'], filter, 'US-ASCII')
      rescue
        message_ids = @imap.search(filter)
      end
    end

    # check mode only
    if check_type == 'check'
      Rails.logger.info 'check only mode, fetch no emails'
      content_max_check = 2
      content_messages  = 0

      # check messages
      message_ids.each do |message_id|

        message_meta = nil
        timeout(1.minute) do
          message_meta = @imap.fetch(message_id, ['RFC822.HEADER'])[0].attr
        end

        # check how many content messages we have, for notice used
        headers = parse_headers(message_meta['RFC822.HEADER'])
        next if messages_is_verify_message?(headers)
        next if messages_is_ignore_message?(headers)

        content_messages += 1
        break if content_max_check < content_messages
      end
      if content_messages >= content_max_check
        content_messages = message_ids.count
      end
      disconnect
      return {
        result:           'ok',
        content_messages: content_messages,
      }
    end

    # reverse message order to increase performance
    if check_type == 'verify'
      Rails.logger.info "verify mode, fetch no emails #{verify_string}"
      message_ids.reverse!

      # check for verify message
      message_ids.each do |message_id|

        message_meta = nil
        timeout(1.minute) do
          message_meta = @imap.fetch(message_id, ['ENVELOPE'])[0].attr
        end

        # check if verify message exists
        subject = message_meta['ENVELOPE'].subject
        next if !subject
        next if subject !~ /#{verify_string}/

        Rails.logger.info " - verify email #{verify_string} found"
        timeout(600) do
          @imap.store(message_id, '+FLAGS', [:Deleted])
          @imap.expunge()
        end
        disconnect
        return {
          result: 'ok',
        }
      end

      disconnect
      return {
        result: 'verify not ok',
      }
    end

    # fetch regular messages
    count_all     = message_ids.count
    count         = 0
    count_fetched = 0
    notice        = ''
    message_ids.each do |message_id|
      count += 1
      Rails.logger.info " - message #{count}/#{count_all}"

      message_meta = nil
      timeout(1.minute) do
        message_meta = @imap.fetch(message_id, ['RFC822.SIZE', 'ENVELOPE', 'FLAGS', 'INTERNALDATE', 'RFC822.HEADER'])[0]
      end

      # ignore verify messages
      next if !messages_is_too_old_verify?(message_meta, count, count_all)

      # ignore to big messages
      info = too_big?(message_meta, count, count_all)
      if info
        notice += "#{info}\n"
        next
      end

      # ignore deleted messages
      next if deleted?(message_meta, count, count_all)

      # ignore already imported
      next if already_imported?(message_id, message_meta, count, count_all, keep_on_server, channel)

      # delete email from server after article was created
      msg = nil
      timeout(1.minute) do
        msg = @imap.fetch(message_id, 'RFC822')[0].attr['RFC822']
      end
      next if !msg

      process(channel, msg, false)

      timeout(1.minute) do
        if !keep_on_server
          @imap.store(message_id, '+FLAGS', [:Deleted])
        else
          @imap.store(message_id, '+FLAGS', [:Seen])
        end
      end
      count_fetched += 1
    end

    if !keep_on_server
      timeout(10.minutes) do
        @imap.expunge()
      end
    end
    disconnect
    if count.zero?
      Rails.logger.info ' - no message'
    end
    Rails.logger.info 'done'
    {
      result:  'ok',
      fetched: count_fetched,
      notice:  notice,
    }
  end

  def disconnect
    return if !@imap

    timeout(1.minute) do
      @imap.disconnect()
    end
  end

=begin

  Channel::Driver::Imap.streamable?

returns

  true|false

=end

  def self.streamable?
    false
  end

  private

  def messages_is_too_old_verify?(message_meta, count, count_all)
    headers = parse_headers(message_meta.attr['RFC822.HEADER'])
    return true if !messages_is_verify_message?(headers)
    return true if headers['X-Zammad-Verify-Time'].blank?

    begin
      verify_time = Time.zone.parse(headers['X-Zammad-Verify-Time'])
    rescue => e
      Rails.logger.error e
      return true
    end
    return true if verify_time < Time.zone.now - 30.minutes

    Rails.logger.info "  - ignore message #{count}/#{count_all} - because message has a verify message"

    false
  end

  def messages_is_verify_message?(headers)
    return true if headers['X-Zammad-Verify'] == 'true'

    false
  end

  def messages_is_ignore_message?(headers)
    return true if headers['X-Zammad-Ignore'] == 'true'

    false
  end

  def parse_headers(string)
    return {} if string.blank?

    headers = {}
    headers_pairs = string.split("\r\n")
    headers_pairs.each do |pair|
      key_value = pair.split(': ')
      next if key_value[0].blank?

      headers[key_value[0]] = key_value[1]
    end
    headers
  end

  # rubocop:disable Metrics/ParameterLists
  def already_imported?(message_id, message_meta, count, count_all, keep_on_server, channel)
    # rubocop:enable Metrics/ParameterLists
    return false if !keep_on_server
    return false if !message_meta.attr
    return false if !message_meta.attr['ENVELOPE']

    local_message_id = message_meta.attr['ENVELOPE'].message_id
    return false if local_message_id.blank?

    local_message_id_md5 = Digest::MD5.hexdigest(local_message_id)
    article = Ticket::Article.where(message_id_md5: local_message_id_md5).order('created_at DESC, id DESC').limit(1).first
    return false if !article

    # verify if message is already imported via same channel, if not, import it again
    ticket = article.ticket
    if ticket&.preferences && ticket.preferences[:channel_id].present? && channel.present?
      return false if ticket.preferences[:channel_id] != channel[:id]
    end

    timeout(1.minute) do
      @imap.store(message_id, '+FLAGS', [:Seen])
    end
    Rails.logger.info "  - ignore message #{count}/#{count_all} - because message message id already imported"
    true
  end

  def deleted?(message_meta, count, count_all)
    return false if !message_meta.attr['FLAGS'].include?(:Deleted)

    Rails.logger.info "  - ignore message #{count}/#{count_all} - because message has already delete flag"
    true
  end

  def too_big?(message_meta, count, count_all)
    max_message_size = Setting.get('postmaster_max_size').to_f
    real_message_size = message_meta.attr['RFC822.SIZE'].to_f / 1024 / 1024
    if real_message_size > max_message_size
      info = "  - ignore message #{count}/#{count_all} - because message is too big (is:#{real_message_size} MB/max:#{max_message_size} MB)"
      Rails.logger.info info
      return info
    end
    false
  end

  def timeout(seconds)
    Timeout.timeout(seconds) do
      yield
    end
  end

end
