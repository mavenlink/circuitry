require 'retries'
require 'timeout'
require 'circuitry/concerns/async'
require 'circuitry/services/sqs'
require 'circuitry/message'
require 'circuitry/queue'

module Circuitry
  class SubscribeError < StandardError; end

  class Subscriber
    include Concerns::Async
    include Services::SQS

    attr_reader :queue, :timeout, :wait_time, :batch_size, :lock, :ignore_visibility_timeout, :auto_delete, :before_message

    DEFAULT_OPTIONS = {
      lock: true,
      async: false,
      timeout: 15,
      wait_time: 10,
      batch_size: 10,
      ignore_visibility_timeout: false,
      auto_delete: true,
    }.freeze

    CONNECTION_ERRORS = [
      Aws::SQS::Errors::ServiceError
    ].freeze

    def initialize(options = {})
      options = DEFAULT_OPTIONS.merge(options)

      self.subscribed = false
      self.queue = Queue.find(Circuitry.subscriber_config.queue_name).url

      %i[lock async timeout wait_time batch_size ignore_visibility_timeout auto_delete before_message].each do |sym|
        send(:"#{sym}=", options[sym])
      end

      trap_signals
    end

    def subscribe(&block)
      raise ArgumentError, 'block required' if block.nil?
      raise SubscribeError, 'AWS configuration is not set' unless can_subscribe?

      logger.info("Subscribing to queue: #{queue}")

      self.subscribed = true
      poll(&block)
      self.subscribed = false

      logger.info("Unsubscribed from queue: #{queue}")
    rescue *CONNECTION_ERRORS => e
      logger.error("Connection error to queue: #{queue}: #{e}")
      raise SubscribeError, e.message
    end

    def subscribed?
      subscribed
    end

    def self.async_strategies
      super - [:batch]
    end

    def self.default_async_strategy
      Circuitry.subscriber_config.async_strategy
    end

    def change_message_visibility(message, timeout = 0)
      logger.info("Retrying message now by making the 'visiblity_timeout' #{timeout} seconds for message #{message.id}")
      sqs.change_message_visibility(queue_url: queue, receipt_handle: message.receipt_handle, visibility_timeout: timeout)
    end

    def delete_messages(message_entries)
      logger.info("Removing messages [#{message_entries.map { |entry| entry[:id] }.join(', ') }] from queue")
      sqs.delete_message_batch(queue_url: queue, entries: message_entries)
    end

    protected

    attr_writer :queue, :timeout, :wait_time, :batch_size, :ignore_visibility_timeout, :auto_delete, :before_message
    attr_accessor :subscribed

    def lock=(value)
      value = case value
                when true then Circuitry.subscriber_config.lock_strategy
                when false then Circuitry::Locks::NOOP.new
                when Circuitry::Locks::Base then value
                else raise ArgumentError, lock_value_error(value)
              end

      @lock = value
    end

    private

    def lock_value_error(value)
      opts = Circuitry::Locks::Base
      "Invalid value `#{value}`, must be one of `true`, `false`, or instance of `#{opts}`"
    end

    def trap_signals
      trap('INT') do
        self.subscribed = false
      end

      trap('TERM') do
        self.subscribed = false
      end
    end

    def poll(&block)
      poller = Aws::SQS::QueuePoller.new(queue, client: sqs)

      poller.before_request do |_stats|
        if !subscribed?
          logger.info('Interrupt received, unsubscribing from queue...')
          throw :stop_polling
        end
      end

      poller.poll(max_number_of_messages: batch_size, wait_time_seconds: wait_time, skip_delete: true) do |messages|
        messages = [messages] unless messages.is_a?(Array)
        process_messages(Array(messages), &block)
        Circuitry.flush
      end
    end

    def process_messages(messages, &block)
      if async?
        process_messages_asynchronously(messages, &block)
      else
        process_messages_synchronously(messages, &block)
      end
    end

    def process_messages_asynchronously(messages, &block)
      messages.each { |message| process_asynchronously { process_message(message, &block) } }
    end

    def process_messages_synchronously(messages, &block)
      messages.each { |message| process_message(message, &block) }
    end

    def process_message(message, &block)
      message = Message.new(message)

      logger.info("Processing message #{message.id}")

      handled = try_with_lock(message.id) do
        handle_message_with_middleware(message, &block)
      end

      logger.info("Ignoring duplicate message #{message.id}") unless handled
    rescue => e
      change_message_visibility(message) if ignore_visibility_timeout
      logger.error("Error processing message #{message.id}: #{e}")

      error_handler.call(e) if error_handler
    end

    def handle_message_with_middleware(message, &block)
      middleware.invoke(message.topic.name, message.body) do
        handle_message(message, &block)
        delete_message(message) if auto_delete
      end
    end

    def try_with_lock(id)
      if lock.soft_lock(id)
        begin
          yield
        rescue => e
          lock.unlock(id)
          raise e
        end

        lock.hard_lock(id)
        true
      else
        false
      end
    end

    # TODO: Don't use ruby timeout.
    # http://www.mikeperham.com/2015/05/08/timeout-rubys-most-dangerous-api/
    def handle_message(message, &block)
      Timeout.timeout(timeout) do
        before_message.call(message) if before_message
        if auto_delete
          block.call(message.body, message.topic.name)
        else
          block.call(message.body, message.topic.name, message_entry(message))
        end
      end
    rescue => e
      logger.error("Error handling message #{message.id}: #{e}")
      raise e
    end

    def message_entry(message)
      { id: message.id, receipt_handle: message.receipt_handle }
    end

    def delete_message(message)
      logger.info("Removing message #{message.id} from queue")
      sqs.delete_message(queue_url: queue, receipt_handle: message.receipt_handle)
    end

    def logger
      Circuitry.subscriber_config.logger
    end

    def error_handler
      Circuitry.subscriber_config.error_handler
    end

    def can_subscribe?
      Circuitry.subscriber_config.aws_options.values.all? do |value|
        !value.nil? && !value.empty?
      end
    end

    def middleware
      Circuitry.subscriber_config.middleware
    end
  end
end
