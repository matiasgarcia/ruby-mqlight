# @(#) MQMBID sn=mqkoa-L160208.09 su=_Zdh2gM49EeWAYJom138ZUQ pn=appmsging/ruby/mqlight/lib/mqlight/command.rb
#
# <copyright
# notice="lm-source-program"
# pids="5725-P60"
# years="2013,2015"
# crc="3568777996" >
# Licensed Materials - Property of IBM
#
# 5725-P60
#
# (C) Copyright IBM Corp. 2013, 2015
#
# US Government Users Restricted Rights - Use, duplication or
# disclosure restricted by GSA ADP Schedule Contract with
# IBM Corp.
# </copyright>

module Mqlight
  # This class handles the inter-communication between the threads
  # @private
  class Command
    include Qpid::Proton::Util::ErrorHandler
    include Mqlight::Logging

    attr_reader :request_queue
    attr_reader :request_queue_mutex
    attr_reader :request_queue_resource

    #
    #
    #
    def initialize(args)
      @id = args[:id]
      @thread_vars = args[:thread_vars]

      # Setup queue for sending request to the command thread
      @request_queue = Queue.new
      @request_queue_mutex = Mutex.new
      @request_queue_resource = ConditionVariable.new
      @shutdown = false
    end

    def started?
      @thread_vars.state == :started
    end

    #
    def stopped?
      @thread_vars.state == :stopped
    end

    #
    def retrying?
      @thread_vars.state == :retrying
    end

    #
    def starting?
      @thread_vars.state == :starting
    end

    # @private
    def process_queued_send(msg, qos)
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      @thread_vars.proton.put_message(msg, qos)

      sleep(0.02) while @thread_vars.proton.outbound_pending?

      # Push back a message: nil if no problem detected otherwise an exception
      # describing the issue.
      exception = nil
      status = @thread_vars.proton.tracker_status
      while status == Cproton::PN_STATUS_PENDING && started?
        sleep(0.02)
        status = @thread_vars.proton.tracker_status
      end
      fail RetryError,'Change of state from started detected' unless started?

      case status
      when Cproton::PN_STATUS_ACCEPTED
        # No action
      when Cproton::PN_STATUS_SETTLED
        # No action
      when Cproton::PN_STATUS_REJECTED
        reject_msg = @thread_vars.proton.tracker_condition_description(
          'send failed - message was rejected')
        exception  = Mqlight::ExceptionContainer.new(
          RangeError.new(reject_msg))
      when Cproton::PN_STATUS_RELEASED
        exception = Mqlight::ExceptionContainer.new(
          Mqlight::InternalError.new(
            'send failed - message was released'))
      when Cproton::PN_STATUS_MODIFIED
        exception = Mqlight::ExceptionContainer.new(
          Mqlight::InternalError.new(
            'send failed - message was modified'))
      when Cproton::PN_STATUS_ABORTED
        # An abortion is assumed to be a lost of disconnect
        # and therefore mark the request as a retry,
        fail Mqlight::NetworkError, 'send failed - message was aborted'
      when Cproton::PN_STATUS_PENDING
        # No action
      when 0
        # ignoring these as appear to be
        # generated by 'rspec'
      else
        exception = Mqlight::ExceptionContainer.new(
          Mqlight::InternalError.new(
            "send failed - unknown status #{status}"))
      end
      @thread_vars.reply_queue.push(exception)
      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    rescue Qpid::Proton::TimeoutError
      # Specific capture of the QPid timeout condition
      # Reply back to user with TimeoutError.
      @thread_vars.reply_queue.push(
        TimeoutError.new(
          'Send request did not complete within the requested period'))
    rescue Qpid::Proton::ProtonError => error
      @thread_vars.reply_queue.push(
        Mqlight::ExceptionContainer.new(
          Mqlight::InternalError.new(error)))
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # @private
    def process_queued_subscription(destination)
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      link = @thread_vars.proton.create_subscription destination

      # block until link is active or error condition detected
      exception = nil
      begin
        until @thread_vars.proton.link_up?(link)
          # Short pause
          sleep 0.1
        end
      rescue StandardError => e
        exception = e
      end

      # Return the acknowledgement
      @thread_vars.reply_queue.push(exception)

      @thread_vars.destinations.push(destination)
      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # @private
    def process_queued_unsubscribe(destination, ttl)
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      # find and close the link
      @thread_vars.proton.close_link(destination, ttl)

      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    # @private
    def check_for_messages(destination, timeout = nil)
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      @thread_vars.proton.check_for_out_of_sequence_messages
      link = @thread_vars.proton.open_for_message(destination)
      fail Mqlight::InternalError,
           'No link for ' + destination.to_s + ' could be found' if link.nil?

      message_present = false
      unless link.nil?
        begin
          Timeout.timeout(timeout) do
            sleep(0.1) until @thread_vars.proton.message? || !started?
            message_present = true if started?
          end
        rescue Timeout::Error
          logger.data(@id, 'Timeout received inside checking_for_messages') do
            self.class.to_s + '#' + __method__.to_s
          end
          message_present = @thread_vars.proton.drain_message(link) if started?
        end
      end

      unless message_present
        @thread_vars.reply_queue.push(nil)
        logger.exit(@id, 'none') { self.class.to_s + '#' + __method__.to_s }
        return
      end

      # Collect the message
      msg = @thread_vars.proton.collect_message
      message = Mqlight::Delivery.new(msg, destination, @thread_vars)

      @thread_vars.reply_queue.push(message)

      # QoS 0
      @thread_vars.proton.accept(link) if destination.qos == QOS_AT_MOST_ONCE

      # QoS 1 / auto-confirm
      @thread_vars.proton.settle(link) if
        destination.qos == QOS_AT_LEAST_ONCE &&
        destination.auto_confirm

      logger.exit(@id, 'Present') { self.class.to_s + '#' + __method__.to_s }
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    #
    # Generates and starts the command thread.
    #
    def start_thread
      # Command handle thread.
      @command_thread = Thread.new do
        Thread.current['name'] = 'command_thread'
        begin
          command_loop
          logger.data(@id, 'Command loop terminating') do
            self.class.to_s + '#' + __method__.to_s
          end
        rescue => e
          logger.ffdc(self.class.to_s + '#' + __method__.to_s,
                      'ffdc002', self, 'Uncaught exception', e)
        end
      end
    end

    #
    # Blocks until the command thread has terminated.
    #
    def join
      @request_queue_mutex.synchronize do
        @request_queue_resource.signal
      end

      Timeout.timeout(5) do
        @command_thread.join
      end
    rescue Timeout::Error
      @command_thread.kill
    end

    #
    # Process all the requests on the queue.
    #
    def process_request_queue
      @thread_vars.processing_command = true
      op = @request_queue.pop(true)
      timeout = op[:timeout]
      # Receive timeout handled inside 'check_for_messages'
      timeout = nil if op[:action] == 'receive'
      Timeout.timeout(timeout) do
        until op.nil?
          begin
            # Waiting while proton thread is trying to
            # recover the connection.
            @thread_vars.wait_for_state_change(nil) while retrying? || starting?
            return if stopped?

            # Process request
            case op[:action]
            when 'send'
              process_queued_send op[:params], op[:qos]
            when 'subscribe'
              process_queued_subscription op[:params]
            when 'unsubscribe'
              process_queued_unsubscribe op[:params], op[:ttl]
            when 'receive'
              check_for_messages(op[:destination], op[:timeout])
            end

            # Request has been completed.
            op = nil

          rescue Mqlight::NetworkError
            # The request has failed due to the connection
            # to the server failing. Change the state to
            # :retrying in case the proton thread hasn't
            # work it out yet.
            @thread_vars.change_state(:retrying)
          rescue Qpid::Proton::StateError
            # The request has failed due to the connection
            # to the server failing. Change the state to
            # :retrying in case the proton thread hasn't
            # work it out yet.
            @thread_vars.proton.check_for_out_of_sequence_messages
          rescue RetryError
            # No action as the default will be to wait for connect
            # and retry.
            logger.data(@id, "Retry error detected") do
              self.class.to_s + '#' + __method__.to_s
            end
          end
        end
      end
    rescue Timeout::Error
      logger.data(@id, "Request #{op[:action]} terminated by timeout") do
        self.class.to_s + '#' + __method__.to_s
      end
      # The command request has timed out, report back to
      # outer thread.
      @thread_vars.reply_queue.push(
        Mqlight::ExceptionContainer.new(
          Mqlight::TimeoutError.new('Command timeout has expired')))
    rescue => e
      # A catch all for reporting to a FFDC
      logger.ffdc(self.class.to_s + '#' + __method__.to_s,
                  'ffdc001', self, 'Uncaught exception', e)
      @thread_vars.reply_queue.push(Mqlight::ExceptionContainer.new(e))
    ensure
      @thread_vars.processing_command = false
    end

    #
    # The request processing loop for the command thread.
    # This method loops awaiting for requests to be process
    # Should there be a request present but the link is in
    # the retry state this method will wait notification
    # of when the link is reinstate.
    # If the link is closed (stopped) then this method returns,
    # then the thread dies.
    #
    def command_loop
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }

      shutting_down = false
      until shutting_down
        @request_queue_mutex.synchronize do
          # Wait for a command request
          while @request_queue.empty?
            logger.data(@id,
                        'Command loop waiting for command') do
              self.class.to_s + '#' + __method__.to_s
            end
            # Wait for a trigger from the outer thread(Blocking_client).
            @request_queue_resource.wait(@request_queue_mutex)
            return if stopped?
          end

          # Process all the requests on the queue.
          process_request_queue unless @request_queue.empty?

          # Signal client command completed.
          @request_queue_resource.signal

          if stopped? then
            shutting_down = true
            @shutdown = true
          end
        end
      end

      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    rescue StandardError => e
      logger.throw(@id, e) { self.class.to_s + '#' + __method__.to_s }
      raise e
    end

    #
    # Pushes the specified request onto the request queue and
    # waits for it to be sent.
    #
    def push_request(hash)
      logger.entry(@id) { self.class.to_s + '#' + __method__.to_s }
      parms = Hash[method(__method__).parameters.map do |parm|
        [parm[1], eval(parm[1].to_s)]
      end]
      logger.parms(@id, parms) { self.class.to_s + '#' + __method__.to_s }

      @request_queue_mutex.synchronize do
        if @shutdown then
          fail Mqlight::StoppedError, 'Client in stopped state'
        end

        @request_queue.push(hash)
        @request_queue_resource.signal
        # Wait for the command to be taken.
        until @request_queue.empty?
          @request_queue_resource.wait(@request_queue_mutex)
        end
        @request_queue_resource.signal
      end

      logger.exit(@id) { self.class.to_s + '#' + __method__.to_s }
    end

    #
    #
    #
    def error
      @thread_vars.proton.error
    end
    # End of class
  end
end