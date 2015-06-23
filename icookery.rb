#!/usr/bin/ruby
# coding: utf-8

require 'json'
require 'rbczmq'
require 'openssl'
require 'uuidtools'
require 'colored'
require 'awesome_print'

class ICookery
  @DELIMETER = '<IDS|MSG>'
  @l = Logger.new(STDOUT)

  class<< self
    attr_accessor :instance, :l, :DELIMETER
  end

  def initialize(connection_file)
    @session = UUIDTools::UUID.random_create.to_s
    config = JSON.load(File.read connection_file)
    @key = config['key']
    @execution_counter = 0

    ICookery.instance = self
    context = ZMQ::Context.new

    address = "#{config["transport"]}://#{config["ip"]}:%d"

    @iopub_socket       = context.socket(:PUB)
    @iopub_socket.connect(address % config['iopub_port'])
    @sockets = {:iopub_socket => @iopub_socket}
    send_status(:starting)

    # @control_socket_rcv = context.socket(:ROUTER)
    # @control_socket     = context.socket(:ROUTER)
    @shell_socket       = context.socket(:ROUTER)
    # @stdin_socket_rcv   = context.socket(:ROUTER)
    # @stdin_socket       = context.socket(:ROUTER)

    @sockets[:shell_socket] = @shell_socket

    # control_socket_rcv.bind(address + @@control_port.to_s)
    # control_socket.connect(address + @@control_port.to_s)
    @shell_socket.bind(address % config['shell_port'])
    # @stdin_socket.bind(address % config['stdin_port'])

    hb_thread = Thread.new do
      hb_socket = context.socket(:REP)
      hb_socket.bind(address % config['hb_port'])
      ZMQ.proxy(hb_socket, hb_socket)
    end

    @identities = []
    run_kernel
  end

  def message_header
    {'msg_id' => UUIDTools::UUID.random_create.to_s,
     'username' => ENV['USERNAME'],
     'session' => @session,
     'version' => '5.0'}
  end

  def recv_message(socket)
    message = socket.recv_message
    @sockets[:iopub_socket].send_message(message.clone)

    if message.nil?
      ICookery.l.warn "Message is nil on shell socket"
    end

    messages = message.to_a.map(&:data)

    ICookery.l.debug "Reaciving message:".magenta
    ICookery.l.ap messages, :debug

    uuid, delimeter, hmac, header, p_header, metadata, \
    content, blob, *rest = messages

    ICookery.l.warn "no uuid in the message" if uuid.nil?

    # ICookery.l.debug "uuid: "      + uuid.inspect
    # ICookery.l.debug "delimeter: " + delimeter.inspect
    # ICookery.l.debug "hmac: "      + hmac.inspect
    # ICookery.l.debug "header: "    + header.inspect
    # ICookery.l.debug "p_header: "  + p_header.inspect
    # ICookery.l.debug "metadata: "  + metadata.inspect
    ICookery.l.debug "content: "   + content.inspect
    # ICookery.l.debug "blob: "      + blob.inspect
    # ICookery.l.debug "rest: "      + rest.inspect

    @last_header = header

    if digest?(messages)
      ICookery.l.debug "HMAC OK!"
    else
      ICookery.l.error "HMAC NOT OK!"
    end

    @identities = messages.take_while { |i| i != ICookery.DELIMETER}
    ICookery.l.debug "Setting identities to: #{@identities.map(&:inspect).join(',')}".blue
    messages
  end

  def identities
    (@identities.nil? or @identities.empty?) ? nil : @identities.join(',')
  end

  def digest(message)
    digest = OpenSSL::Digest.new('sha256', @key)
    signature= OpenSSL::HMAC.new(@key, digest)
    signature << message[3]
    signature << (message[4] || "")
    signature << (message[5] || "")
    signature << (message[6] || "")
    signature.hexdigest
  end

  def digest!(message)
    message[2] = digest(message)
  end

  def digest?(message)
    message[2] == digest(message)
  end

  def send_message(socket, type, content, identity = nil)
    ICookery.l.debug "Sending message ".red +
                     type.underline.red + " on socket ".red +
                     socket.to_s.underline.red

    result = [identity || identities || type, #uuid
              ICookery.DELIMETER, #delimiter
              '', #hmac
              {'msg_type' => type}.merge(message_header), #header
              @last_header || '{}', #parent_header
              '{}', #metadata
              content, #content
              nil, #blob
             ]
    ICookery.l.ap result, :debug
    result[3] = JSON.dump(result[3])
    result[6] = JSON.dump(result[6])

    digest!(result)

    result.compact!
    result[0...-1].each { |r| @sockets[socket].sendm(r) }
    @sockets[socket].send(result[-1])
  end

  def kernel_info_reply(socket)
    send_message(socket, 'kernel_info_reply',
                 {'protocol_version' => '5.0',
                  'implementation' => 'icookery',
                  'implementation_version' => '1.0',
                  'language_info' => {
                    'name' => 'Cookery',
                    'version' => '1.0',
                    'mimetype' => 'text/plain',
                    'file_extension' => 'cookery',
                    # 'pygments_lexer' => str,
                    # 'codemirror_mode' => str or dict,
                    # 'nbconvert_exporter' => str,
                  },
                  'banner' => 'Cookery notebook',

                  # Optional: A list of dictionaries, each with keys 'text' and 'url'.
                  # These will be displayed in the help menu in the notebook UI.
                  'help_links' => [{'text' => "Cookery", 'url' => "http://github.com/mikolajb/cookery"}],

                 })
  end

  def connect_reply(socket)
    send_message(socket, 'connect_reply',
                 {'shell_port' => @@shell_port,
                  'iopub_port' => @@iopub_port,
                  'stdin_port' => @@stdin_port,
                  'hb_port' => @@hb_port})
  end

  def send_status(status)
    send_message(:iopub_socket, 'status',
                 {'execution_state': status},
                 'status')
  end

  def run_kernel
    while true
      send_status(:idle)

      ICookery.l.debug "waining for a shell message"

      messages = recv_message(@shell_socket)

      send_status(:busy)

      uuid, delimeter, hmac, header, p_header, metadata, \
      content, blob, *rest = messages

      break if uuid.nil?

      m = JSON.load(header)
      if m['msg_type'] == 'kernel_info_request'
        ICookery.l.debug "Sending kernel info reply"
        kernel_info_reply(:shell_socket)
        kernel_info_reply(:iopub_socket)
      elsif m['msg_type'] == 'connect_request'
        ICookery.l.debug "Sending connection reply"
        connect_strings(:shell_socket)
        connect_strings(:iopub_socket)
      elsif m['msg_type'] == 'execute_request'
        @execution_counter += 1
        ICookery.l.debug "Execution request:"
        content = JSON.load content
        ICookery.l.ap content, :debug
        # send_message(:iopub_socket, 'stream',
        #              {'name' => 'stdout',
        #               'text' => 'it works!'})
        send_message(:iopub_socket, 'execute_input',
                     {'code' => content['code'],
                      'execution_count' => @execution_counter})

        send_message(:shell_socket, 'execute_reply',
                     {'status' => 'ok',
                      'execution_count' => @execution_counter})

        send_message(:iopub_socket, 'execute_result',
                     {'execution_count' => @execution_counter,
                      'data' => {'text/plain' => 'to dziala do cholery!'},
                      'metadata' => {}
                     })
      end
    end

    config["signature_scheme"]
  end
end

if ARGV.empty?
  ICookery.l.warn "No command line arguments"
else
  ICookery.l.debug "Command line arguments: #{ARGV.inspect}"
  ICookery.new(ARGV[0])
end
