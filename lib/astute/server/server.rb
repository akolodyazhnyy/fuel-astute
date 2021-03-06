#    Copyright 2013 Mirantis, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

require 'json'
require 'astute/server/task_queue'

module Astute
  module Server

    class Server
      def initialize(channel, exchange, delegate, producer, service_channel, service_exchange)
        @channel  = channel
        @exchange = exchange
        @delegate = delegate
        @producer = producer
        @service_channel = service_channel
        @service_exchange = service_exchange
      end

      def run
        @queue = @channel.queue(Astute.config.broker_queue, :durable => true).bind(@exchange)
        @service_queue = @service_channel.queue("", :exclusive => true, :auto_delete => true).bind(@service_exchange)

        @main_work_thread = nil
        @tasks_queue = TaskQueue.new

        Thread.new(&method(:register_callbacks))
        self
      end

    private

      def register_callbacks
        main_worker
        service_worker
      end

      def main_worker
        @consumer = AMQP::Consumer.new(@channel, @queue)
        @consumer.on_delivery do |metadata, payload|
          Astute.logger.debug "Process message from worker queue: #{payload.inspect}"
          perform_main_job(metadata, payload)
        end
        @consumer.consume
      end

      def service_worker
        @service_queue.subscribe do |_, payload|
          Astute.logger.debug "Process message from service queue: #{payload.inspect}"
          perform_service_job(nil, payload)
        end
      end

      def perform_main_job(metadata, payload)
        @main_work_thread = Thread.new do
          begin
            data = parse_data(payload)
            @tasks_queue = Astute::Server::TaskQueue.new

            @tasks_queue.add_task(data)
            dispatch(@tasks_queue)
          ensure
            metadata.ack
          end
        end
      end

      def perform_service_job(metadata, payload)
        Thread.new do
          service_data = {:main_work_thread => @main_work_thread, :tasks_queue => @tasks_queue}
          dispatch(parse_data(payload), service_data)
        end
      end

      def dispatch(data, service_data=nil)
        data.each_with_index do |message, i|
          begin
            dispatch_message message, service_data
          rescue StopIteration
            Astute.logger.debug "Dispatching aborted by #{message['method']}"
            abort_messages messages[(i + 1)..-1]
            break
          rescue => ex
            Astute.logger.error "Error running RPC method #{message['method']}: #{ex.message}, trace: #{ex.backtrace.inspect}"
            return_results message, {
              'status' => 'error',
              'error'  => "Error occurred while running method '#{message['method']}'. Inspect Orchestrator logs for the details."
            }
            break
          end
        end
      end

      def dispatch_message(data, service_data=nil)
        Astute.logger.debug "Dispatching message: #{data.inspect}"

        if Astute.config.fake_dispatch
          Astute.logger.debug "Fake dispatch"
          return
        end

        unless @delegate.respond_to?(data['method'])
          Astute.logger.error "Unsupported RPC call '#{data['method']}'"
          return_results data, {
            'status' => 'error',
            'error'  => "Unsupported method '#{data['method']}' called."
          }
          return
        end

        Astute.logger.debug "Main worker task id is #{@tasks_queue.current_task_id}" if service_data.nil?

        Astute.logger.info "Processing RPC call '#{data['method']}'"
        if !service_data
          @delegate.send(data['method'], data)
        else
          @delegate.send(data['method'], data, service_data)
        end
      end

      def return_results(message, results)
        if results.is_a?(Hash) && message['respond_to']
          reporter = Astute::Server::Reporter.new(@producer, message['respond_to'], message['args']['task_uuid'])
          reporter.report results
        end
      end

      def parse_data(data)
        Astute.logger.debug "Got message with payload #{data.inspect}"
        messages = nil
        begin
          messages = JSON.load(data)
        rescue => e
          Astute.logger.error "Error deserializing payload: #{e.message}, trace: #{e.backtrace.inspect}"
        end
        messages.is_a?(Array) ? messages : [messages]
      end

      def abort_messages(messages)
        return unless messages && messages.size > 0
        messages.each do |message|
          begin
            Astute.logger.debug "Aborting '#{message['method']}'"
            err_msg = {
              'status' => 'error',
              'error' => 'Task aborted',
              'progress' => 100
            }

            if message['args']['nodes'].instance_of?(Array)
              err_nodes = message['args']['nodes'].map do |node|
                {'uid' => node['uid'], 'status' => 'error', 'error_type' => 'provision', 'progress' => 0}
              end

              err_msg.merge!('nodes' => err_nodes)
            end

            return_results(message, err_msg)
          rescue => ex
            Astute.logger.debug "Failed to abort '#{message['method']}': #{ex.inspect}"
          end
        end
      end
    end

  end #Server
end #Astute
