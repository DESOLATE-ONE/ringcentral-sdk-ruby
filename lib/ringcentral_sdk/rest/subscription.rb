require 'base64'
require 'logger'
require 'multi_json'
require 'observer'
require 'openssl'
require 'pubnub'
require 'timers'

module RingCentralSdk::REST
  class Subscription
    include Observable

    RENEW_HANDICAP = 60

    attr_reader :event_filters

    def initialize(client)
      @_client = client
      @event_filters = []
      @_timeout = nil
      @_subscription = nil_subscription()
      @_pubnub = nil
    end

    def nil_subscription()
      subscription        =  {
        'eventFilters'    => [],
        'expirationTime'  => '', # 2014-03-12T19:54:35.613Z
        'expiresIn'       => 0,
        'deliveryMode'    => {
          'transportType' => 'PubNub',
          'encryption'    => false,
          'address'       => '',
          'subscriberKey' => '',
          'secretKey'     => ''
        },
        'id'              => '',
        'creationTime'    => '', # 2014-03-12T19:54:35.613Z
        'status'          => '', # Active
        'uri'             => ''
      }
      return subscription
    end

    def pubnub()
      return @_pubnub
    end

    def register(events = nil)
      return alive?() ? renew(events) : subscribe(events)
    end

    def add_events(events)
      unless events.is_a?(Array)
        raise 'Events is not an array.'
      end
      @event_filters.push(events) if events.length > 0
    end

    def set_events(events)
      unless events.is_a?(Array)
        raise 'Events is not an array.'
      end
      @event_filters = events
    end

    def subscribe(events=nil)
      set_events(events) if events.is_a?(Array)

      if !@event_filters.is_a?(Array) || @event_filters.length == 0
        raise 'Events are undefined'
      end

      begin
        response = @_client.http.post do |req|
          req.url 'subscription'
          req.body = {
            eventFilters: @_client.create_urls(@event_filters),
            deliveryMode: {
              transportType: 'PubNub'
            }
          }
        end
        set_subscription(response.body)
        _subscribe_at_pubnub()
        changed
        notify_observers(response)
        return response
      rescue StandardError => e
        reset()
        changed
        notify_observers(e)
        raise 'Subscribe HTTP Request Error: ' + e.to_s
      end
    end

    def renew(events = nil)
      set_events(events) if events.is_a?(Array)

      unless alive?()
        raise 'Subscription is not alive'
      end

      if !@event_filters.is_a?(Array) || @event_filters.length ==0
        raise 'Events are undefined'
      end
 
      _clear_timeout()

      begin
        response = @_client.http.put do |req|
          req.url 'subscription/' + @_subscription['id'].to_s
          req.body = {
            eventFilters: @_client.create_urls(@event_filters)
          }
        end

        set_subscription(response.body)
        changed
        notify_observers(response)
        return response
      rescue StandardError => e
        reset()
        changed
        notify_observers(e)
        raise 'Renew HTTP Request Error'
      end
    end

    def remove()
      unless alive?()
        raise 'Subscription is not alive'
      end

      begin
        response = @_client.http.delete do |req|
          req.url 'subscription/' + @_subscription['id'].to_s
        end
        reset()
        changed
        notify_observers(response.body)
        return response
      rescue StandardError => e
        reset()
        changed
        notify_observers(e)
      end
    end

    def alive?()
      s = @_subscription
      return (s.has_key?('deliveryMode') && s['deliveryMode']) && \
        (s['deliveryMode'].has_key?('subscriberKey') && s['deliveryMode']['subscriberKey']) && \
        (
          s['deliveryMode'].has_key?('address') && s['deliveryMode']['address'] && \
          s['deliveryMode']['address'].length>0) \
        ? true : false
    end

    def subscription()
      return @_subscription
    end

    def set_subscription(data)
      _clear_timeout()
      @_subscription = data
      _set_timeout()
    end

    def reset()
      _clear_timeout()
      _unsubscribe_at_pubnub()
      @_subscription = nil_subscription()
    end

    def destroy()
      reset()
    end

    def _subscribe_at_pubnub()
      if ! alive?()
        raise 'Subscription is not alive'
      end

      s_key = @_subscription['deliveryMode']['subscriberKey']

      @_pubnub = new_pubnub(s_key, false, '')

      callback = lambda { |envelope|
      	_notify(envelope.msg)
      	changed
        #notify_observers {}
      	#notify_observers('GOT_PUBNUB_MESSAGE_NOTIFY')
      }

      @_pubnub.subscribe(
        channel:    @_subscription['deliveryMode']['address'],
        callback:   callback,
        error:      lambda { |envelope| puts('ERROR: ' + envelope.msg.to_s) },
        connect:    lambda { |envelope| puts('CONNECTED') },
        reconnect:  lambda { |envelope| puts('RECONNECTED') },
        disconnect: lambda { |envelope| puts('DISCONNECTED') }
      )
    end

    def _notify(message)
      message = _decrypt(message)
      changed
      notify_observers(message)
    end

    def _decrypt(message)
      unless alive?()
        raise 'Subscription is not alive'
      end

      if _encrypted?()
        delivery_mode = @_subscription['deliveryMode']

        cipher = OpenSSL::Cipher::AES.new(128, :ECB)
        cipher.decrypt
        cipher.key = Base64.decode64(delivery_mode['encryptionKey'].to_s)

        ciphertext = Base64.decode64(message)
        plaintext = cipher.update(ciphertext) + cipher.final

        message = MultiJson.decode(plaintext, :symbolize_keys=>false)
      end

      return message
    end

    def _encrypted?()
      delivery_mode = @_subscription['deliveryMode']
      is_encrypted  = delivery_mode.has_key?('encryption') && \
        delivery_mode['encryption']                        && \
        delivery_mode.has_key?('encryptionKey')            && \
        delivery_mode['encryptionKey']
      return is_encrypted
    end

    def _unsubscribe_at_pubnub()
      if @_pubnub && alive?()
        @_pubnub.unsubscribe(channel: @_subscription['deliveryMode']['address']) do |envelope|
          # puts envelope.message
        end
      end
    end

    def _set_timeout()
      time_to_expiration = @_subscription['expiresIn'] - RENEW_HANDICAP
      @_timeout = Timers::Group.new
      @_timeout.after(time_to_expiration) do
        renew()
      end
    end

    def _clear_timeout()
      if @_timeout.is_a? Timers::Group
        @_timeout.cancel()
      end
    end

    def new_pubnub(subscribe_key='', ssl_on=false, publish_key='', my_logger=nil)
      my_logger = Logger.new(STDOUT) if my_logger.nil?

      return Pubnub.new(
        subscribe_key: subscribe_key.to_s,
        publish_key: publish_key.to_s,
        error_callback: lambda { |msg|
          puts "Error callback says: #{msg.inspect}"
        },
        connect_callback: lambda { |msg|
          puts "CONNECTED: #{msg.inspect}"
        },
        logger: my_logger
      )
    end
  end
end
