Dir[File.dirname(__FILE__) + '/ext/*.rb'].each { |f| require f }

require File.dirname(__FILE__) + "/summer/handlers"

module Summer
  class Connection
    include Handlers
    attr_accessor :connection, :ready, :started
    def initialize(connection, handler, config)
      @connection = connection
      @handler = handler
      @config = config
      @ready = false
      @started = false
      @socket_mutex = Mutex.new
      @runner = nil #Running thread
      @stop = false
    end

    def start
      @runner ||= Thread.new {
        until @stop
          begin
            run()
          rescue StandardError => e
            @runner = nil
            $stdout.puts $@
            $stdout.puts e
          end
          $stdout.puts "sleeping..."
          sleep 60
        end
        $stdout.puts "irc client exited."
      }
    end

    def stop
      @stop = true
    end

    def me
      @config[:nick]
    end

    private

    def run
      $stdout.puts "running irc client..."
      connect! if not @started #handlers set @ready
      until @stop
        startup! if @ready and not @started
        parse(@connection.gets)
      end
      $stdout.puts "stoping irc client..."
    end

    def connect!
      $stdout.puts "connecting irc client..."
      response("USER #{@config[:nick]} #{@config[:nick]} #{@config[:nick]} #{@config[:nick]}")
      response("NICK #{@config[:nick]}")
    end

    # Will join channels specified in configuration.
    def startup!
      $stdout.puts "starting up irc client..."
      nickserv_identify if @config[:nickserv_password]
      (@config[:channels] << @config[:channel]).compact.each do |channel|
        join(channel) unless channel.strip.empty?
      end
      @started = true
      @handler.did_startup
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
      elsif raw == "PRIVMSG" and channel == me
        s = parse_sender(sender)
        @handler.private_message(s, s[:nick], words[3..-1].clean)
      elsif raw == "PRIVMSG"
        @handler.channel_message(parse_sender(sender), channel, words[3..-1].clean)
      # Joins
      elsif raw == "JOIN"
        s = parse_sender(sender)
        @handler.joined(s, channel.delete(":")) unless (s[:nick] == me)
      elsif raw == "PART"
        #@handler.part(parse_sender(sender), channel, words[3..-1].clean)
        really_try(:part, parse_sender(sender), channel, words[3..-1].clean)
      elsif raw == "QUIT"
        #@handler.quit(parse_sender(sender), words[2..-1].clean)
        really_try(:quit, parse_sender(sender), words[2..-1].clean)
      elsif raw == "KICK"
        #@handler.kick(parse_sender(sender), channel, words[3], words[4..-1].clean)
        really_try(:kick, parse_sender(sender), channel, words[3], words[4..-1].clean)
        join(channel) if words[3] == me && @config[:auto_rejoin]
      elsif raw == "MODE"
        #@handler.mode(parse_sender(sender), channel, words[3], words[4..-1].clean)
        really_try(:mode, parse_sender(sender), channel, words[3], words[4..-1].clean)
      else
        $stdout.puts "(ignored)"
      end
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
      response("PRIVMSG #{to} :#{message}")
    end

    # Output something to the console and to the socket.
    def response(message)
      @socket_mutex.synchronize do
        $stdout.puts ">> #{message.strip}"
        @connection.puts(message)
      end
    end

    def log(message)
      File.open(@config[:log_file]) { |file| file.write(message) } if @config[:log_file]
    end

  end

end
