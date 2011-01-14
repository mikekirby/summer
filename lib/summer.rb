require 'socket'
require 'yaml'
require 'active_support/hash_with_indifferent_access'
require 'active_support/core_ext/object/try'

Dir[File.dirname(__FILE__) + '/ext/*.rb'].each { |f| require f }

require File.dirname(__FILE__) + "/summer/handlers"

module Summer
  class Connection
    include Handlers
    attr_accessor :connection, :ready, :started, :config, :server, :port
    def initialize(server, port=6667, dry=false)
      @ready = false
      @started = false

      @server = server
      @port = port

      @socket_mutex = Mutex.new

      load_config
      connect!
      
      unless dry
        loop do
          startup! if @ready && !@started
          parse(@connection.gets)
        end
      end
    end

    private

    def load_config
      @config = HashWithIndifferentAccess.new(YAML::load_file(File.dirname($0) + "/config/summer.yml"))
    end

    def connect!
      @connection = TCPSocket.open(server, port)      
      response("USER #{config[:nick]} #{config[:nick]} #{config[:nick]} #{config[:nick]}")
      response("NICK #{config[:nick]}")
    end


    # Will join channels specified in configuration.
    def startup!
      nickserv_identify if @config[:nickserv_password]
      (@config[:channels] << @config[:channel]).compact.each do |channel|
        join(channel)
      end
      @started = true
      really_try(:did_start_up) if respond_to?(:did_start_up)
    end
    
    def nickserv_identify
      privmsg("nickserv", "register #{@config[:nickserv_password]} #{@config[:nickserv_email]}")
      privmsg("nickserv", "identify #{@config[:nickserv_password]}")
    end
    # Go somewhere.
    def join(channel)
      response("JOIN #{channel}")
    end

    # Leave somewhere
    def part(channel)
      response("PART #{channel}")
    end

    # What did they say?
    def parse(message)
      puts "<< #{message.to_s.strip}"
      words = message.split(" ")
      sender = words[0]
      raw = words[1]
      channel = words[2]
      # Handling pings
      if /^PING (.*?)\s$/.match(message)
        response("PONG #{$1}")
      # Handling raws
      elsif /\d+/.match(raw)
        send("handle_#{raw}", message) if raws_to_handle.include?(raw)
      # Privmsgs
      elsif raw == "PRIVMSG"
        handle_privmsg(words[3..-1].clean, parse_sender(sender), channel)
      # Joins
      elsif raw == "JOIN"
        really_try(:joined, parse_sender(sender), channel.delete(":"))
      elsif raw == "PART"
        really_try(:part, parse_sender(sender), channel, words[3..-1].clean)
      elsif raw == "QUIT"
        really_try(:quit, parse_sender(sender), words[2..-1].clean)
      elsif raw == "KICK"
        really_try(:kick, parse_sender(sender), channel, words[3], words[4..-1].clean)
        join(channel) if words[3] == me && config[:auto_rejoin]
      elsif raw == "MODE"
        really_try(:mode, parse_sender(sender), channel, words[3], words[4..-1].clean)
      end
    end

    def handle_privmsg(message, sender, channel)
      if channel == me
        handle_msg_to_me(message, sender, sender[:nick])
      elsif message.include?(me)
        handle_msg_mentions_me(message, sender, channel)
      else
        really_try(:channel_message, sender, channel, message)
      end
    end

    def handle_msg_to_me(message, sender, channel)
      if /^!(\w+)\s*(.*)/.match(message)
        really_try("#{$1}_command", sender, channel, $2)
      else
        really_try(:private_message, sender, channel, message)
      end
    end

    def handle_msg_mentions_me(message, sender, channel)
      really_try(:mentions_me_message, sender, channel, message)
    end

    def parse_sender(sender)
      nick, hostname = sender.split("!")
      { :nick => nick.clean, :hostname => hostname }
    end

    # These are the raws we care about.
    def raws_to_handle
      ["422", "376"]
    end

    def privmsg(message, to)
      Thread.new {
        message.split("\n").each { |line| response("PRIVMSG #{to} :#{line}"); sleep(0.9) }
      }
    end

    # Output something to the console and to the socket.
    def response(message)
      @socket_mutex.synchronize do
        puts ">> #{message.strip}"
        @connection.puts(message)
     end
    end

    def me
      config[:nick]
    end
    
    def log(message)
      File.open(config[:log_file]) { |file| file.write(message) } if config[:log_file]
    end

  end

end
