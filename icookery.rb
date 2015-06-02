require 'json'
require 'ffi-rzmq'
require 'openssl'
require 'uuidtools'

class ICookery
  def self.message_header
    {'msg_id' => UUIDTools::UUID.random_create.to_s,
     'username' => ENV['USERNAME'],
     'session' => "session1",
     'version' => '5.0'}
  end

  def self.send_message(socket, uuid, type, content)
    result = [uuid , #uuid
              '<IDS|MSG>', #delimiter
              '', #hmac
              JSON.dump({'msg_type' => type}.merge(message_header)), #header
              '{}', #parent_header
              '{}', #metadata
              JSON.dump(content), #content
              nil, #blob
             ]
    result[2] = digest(result)
    puts "SENDING MESSAGE"
    result.each do |i|
      puts i == '' ? ':empty:' : i
    end
    r = socket.send_strings(result)
    puts "Message sent, result: #{r.inspect}"
    p ZMQ::Util.errno
  end

  def self.digest(message)
    digest = OpenSSL::Digest.new('sha256', @@key)
    signature= OpenSSL::HMAC.new(@@key, digest)
    signature << message[3]
    signature << (message[4] || "")
    signature << (message[5] || "")
    signature << (message[6] || "")
    signature.hexdigest
  end

  def self.kernel_info_reply(socket, uuid = '')
    send_message(socket, uuid, 'kernel_info_reply',
                 {'protocol_version' => '1.0',
                  'implementation' => 'cookery',
                  'implementation_version' => '1.0',
                  'language_info' => {
                    'name' => 'Ruby',
                    'version' => '2.0',
                    'mimetype' => 'text',
                    'file_extension' => 'cookery',
                    # 'pygments_lexer' => str,
                    # 'codemirror_mode' => str or dict,
                    # 'nbconvert_exporter' => str,
                  },
                  'banner' => 'Cookery notebook',

                  # Optional: A list of dictionaries, each with keys 'text' and 'url'.
                  # These will be displayed in the help menu in the notebook UI.
                  # 'help_links' => [{'text' => str, 'url' => str}],

                 })
  end

  def self.connect_reply(socket, uuid = '')
    send_message(socket, uuid, 'connect_reply',
                 {'shell_port' => @@shell_port,
                  'iopub_port' => @@iopub_port,
                  'stdin_port' => @@stdin_port,
                  'hb_port' => @@hb_port})
  end

  def self.run_kernel(connection_file)
    config = JSON.load(File.read connection_file)
    context = ZMQ::Context.create

    control_socket = context.socket(ZMQ::ROUTER)
    shell_socket   = context.socket(ZMQ::ROUTER)
    stdin_socket   = context.socket(ZMQ::ROUTER)
    hb_socket      = context.socket(ZMQ::REP)
    iopub_socket   = context.socket(ZMQ::PUB)

    @@control_port = config["control_port"]
    @@shell_port = config["shell_port"]
    @@stdin_port = config["stdin_port"]
    @@hb_port = config["hb_port"]
    @@iopub_port = config["iopub_port"]
    @@key = config["key"]
    puts "KEY is:"
    p @@key

    address = "#{config["transport"]}://#{config["ip"]}:"
    control_socket.bind(address + @@control_port.to_s)
    shell_socket.bind(address + @@shell_port.to_s)
    stdin_socket.bind(address + @@stdin_port.to_s)
    hb_socket.bind(address + @@hb_port.to_s)
    iopub_socket.bind(address + @@iopub_port.to_s)

    hb_thread = Thread.new(hb_socket) do |s|
      puts "Starting HB"
      message = ZMQ::Message.new
      while true do
        s.recvmsg(message)
        puts "got HB #{message.inspect}"
        s.sendmsg(message)
      end
    end

    while true
      messages = []

      while true
        status = control_socket.recv_strings(messages, ZMQ::DONTWAIT)
        break if messages.empty?
        puts "reaciving control"
        p messages

        messages.each do |m|
          p m
        end
        break
      end

      while true
        status = shell_socket.recv_strings(messages, ZMQ::DONTWAIT)
        break if messages.empty?
        puts "reaciving shell"
        p messages

        uuid, delimeter, hmac, header, p_header, metadata, \
        content, blob, *rest = messages

        break if uuid.nil?

        puts "uuid: " + uuid.inspect
        puts "delimeter: " + delimeter.inspect
        puts "hmac: " + hmac.inspect
        puts "header: " + header.inspect
        puts "p_header: " + p_header.inspect
        puts "metadata: " + metadata.inspect
        puts "content: " + content.inspect
        puts "blob: " + blob.inspect
        puts "rest: " + rest.inspect

        if digest(messages) == hmac
          puts "HMAC OK!"
        else
          warn "HMAC NOT OK!"
          break
        end

        m = JSON.load(header)
        if m['msg_type'] == 'kernel_info_request'
          kernel_info_reply(shell_socket, uuid)
        elsif m['msg_type'] == 'connect_request'
          send_strings(shell_socket, uuid)
        elsif m['msg_type'] == 'execute_request'

        end

        break
      end
      # puts "reaciving stdin"
      # p stdin_socket.recvmsg(message)
      # p message
      # puts "reaciving iopub"
      # p iopub_socket.recvmsg(message)
      # p message
      sleep 1
    end

    config["signature_scheme"]
  end
end

p ARGV
if ARGV.empty?
  warn "no arguments"
else
  ICookery.run_kernel(ARGV[0])
end
