require "socket"

class SSH2::Session
  def initialize
    @handle = LibSSH2.session_init(nil, nil, nil, nil)
    raise SSH2Error.new "unable to initialize session" unless @handle
  end

  def self.open(host, port = 22)
    TCPSocket.open(host, port) do |socket|
      session = new
      session.handshake(socket)
      begin
        yield session
      ensure
        session.disconnect
      end
    end
  end

  # Begin transport layer protocol negotiation with the connected host.
  def handshake(@socket)
    ret = LibSSH2.session_handshake(@handle, @socket.not_nil!.fd)
    check_error(ret)
    @connected = true
  end

  # Login with username and password
  def login(username, password)
    ret = LibSSH2.userauth_password(self, username, username.bytesize, password, password.bytesize, nil)
    check_error(ret)
  end

  # Login with username using pub/priv key values
  def login_with(username, privkey, pubkey, passphrase = nil)
    ret = LibSSH2.userauth_publickey_frommemory(self, username, username.bytesize,
                                                pubkey, LibC::SizeT.cast(pubkey.bytesize),
                                                privkey, LibC::SizeT.cast(privkey.bytesize),
                                                passphrase)
    check_error(ret)
  end

  # Login with username using pub/priv key files
  def login_with_pubkey(username, privkey, pubkey = nil, passphrase = nil)
    ret = LibSSH2.userauth_publickey_fromfile(self, username, username.bytesize.to_u32, pubkey, privkey, passphrase)
    check_error(ret)
  end

  # Send a SSH_USERAUTH_NONE request to the remote host. Unless the remote host
  # is configured to accept none as a viable authentication scheme (unlikely),
  # it will return SSH_USERAUTH_FAILURE along with a listing of what
  # authentication schemes it does support. In the unlikely event that none
  # authentication succeeds, this method with return `nil`. This case may be
  # distinguished from a failing case by examining `authenticated?`.
  def login_with_noauth(username)
    handle = LibSSH2.userauth_list(self, username, username.bytesize)
    if handle
      String.new handle
    end
  end

  # Indicates whether or not the named session has been successfully authenticated.
  def authenticated?
    ret = LibSSH2.userauth_authenticated(self) == 1
  end

  # Returns the current session's host key
  def hashkey(type = LibSSH2::HashType::SHA1 : LibSSH2::HashType)
    handle = LibSSH2.hostkey_hash(self, type)
    return "" unless handle
    slice = Slice.new(handle, type == LibSSH2::HashType::SHA1 ? 20 : 16)
    String.build do |o|
      slice.each_with_index do |b, idx|
        o << b.to_s(16)
        o << ":" unless idx == length - 1
      end
    end
  end

  # Send a disconnect message to the remote host associated with session, along
  # with a description.
  def disconnect(reason = LibSSH2::DisconnectReason::BY_APPLICATION, description = "bye")
    return unless @connected
    ret = LibSSH2.session_disconnect(self, reason, description, "")
    @connected = false
    check_error(ret)
  end

  # Once the session has been setup and `handshake` has completed successfully,
  # this function can be used to get the server id from the banner each server
  # presents.
  def banner
    String.new LibSSH2.session_banner_get(self)
  end

  # Set the banner that will be sent to the remote host when the SSH session is
  # started with `handshake`. This is optional; a banner corresponding to the
  # protocol and libssh2 version will be sent by default.
  def banner=(value)
    ret = LibSSH2.session_banner_set(self, value)
    check_error(ret)
  end

  # Returns block direction flags
  def block_directions
    LibSSH2.session_block_directions(self)
  end

  # check whether the session is in blocking mode
  def blocking?
    LibSSH2.session_get_blocking(self) == 1
  end

  # Set or clear blocking mode on the selected on the session. This will
  # instantly affect any channels associated with this session. If a read is
  # performed on a session with no data currently available, a blocking session
  # will wait for data to arrive and return what it receives. A non-blocking
  # session will return immediately with an empty buffer. If a write is
  # performed on a session with no room for more data, a blocking session will
  # wait for room. A non-blocking session will return immediately without
  # writing anything.
  def blocking=(value)
    LibSSH2.session_set_blocking(self, value ? 1 : 0)
  end

  # Returns the timeout (in milliseconds) for how long a blocking the libssh2
  # function calls may wait until they consider the situation an error and
  # raise an exception
  def timeout
    LibSSH2.session_get_timeout(self)
  end

  # Set the timeout in milliseconds for how long a blocking the libssh2
  # function calls may wait until they consider the situation an error and
  # raise an exception.
  def timeout=(value)
    LibSSH2.session_set_timeout(self, value.to_i64)
  end

  # If set, libssh2 will not attempt to block SIGPIPEs but will let them trigger from the underlying socket layer.
  def set_enable_sigpipe(value)
    ret = LibSSH2.session_flag(self, LibSSH2::Flags::SIGPIPE, value ? 1 : 0)
    check_error(ret)
  end

  # If set - before the connection negotiation is performed - libssh2 will try
  # to negotiate compression enabling for this connection. By default libssh2
  # will not attempt to use compression.
  def set_enable_compression(value)
    ret = LibSSH2.session_flag(self, LibSSH2::Flags::COMPRESS, value ? 1 : 0)
    check_error(ret)
  end

  # Returns a tuple consisting of the computed digest of the remote system's
  # hostkey and its type.
  def hostkey
    handle = LibSSH2.session_hostkey(self, out len, out ty)
    return nil unless handle
    {Slice.new(handle, len), LibSSH2::HostKeyType.new(ty)}
  end

  # Set preferred methods to be negotiated. These preferences must be set prior
  # to calling `handshake`, as they are used during the protocol initiation
  # phase.
  def set_method_pref(method_type: LibSSH2::MethodType, value)
    ret = LibSSH2.session_method_pref(self, method_type, value)
    check_error(ret)
  end

  # Returns the actual method negotiated for a particular transport parameter.
  def method_pref(method_pref: LibSSH2::MethodType)
    handle = LibSSH2.session_methods(self, method_type)
    String.new handle unless handle
  end

  # Get a list of supported algorithms for the given method_type.
  def supported_algs(method_type: LibSSH2::MethodType)
    ret = [] of String
    if (count = LibSSH2.session_supported_algs(self, method_type, out algs)) > 0
      count.times do |i|
        ret << String.new(algs[i])
      end
    end
    ret
  end

  # Send a keepalive message if needed.
  # Return value indicates how many seconds you can sleep after this call
  # before you need to call it again.
  def send_keepalive
    ret = LibSSH2.keepalive_send(self, out seconds_to_next)
    check_error(ret)
    seconds_to_next
  end

  # Set how often keepalive messages should be sent.
  #
  # @param want_reply: indicates whether the keepalive messages should request
  # a response from the server.
  #
  # @param interval:  is number of seconds that can pass without any I/O, use 0
  # (the default) to disable keepalives. To avoid some busy-loop corner-cases,
  # if you specify an interval of 1 it will be treated as 2.
  def keepalive_config(want_reply, interval)
    LibSSH2.keepalive_config(self, want_reply, interval)
  end

  # Return `KnownHosts` object that allows managing known hosts
  def knownhosts
    KnownHosts.new(self)
  end

  # Instruct the remote SSH server to begin listening for inbound TCP/IP
  # connections. New connections will be queued by the library until accepted
  # by `Listener.accept`.
  def forward_listen(host, port, queue_maxsize = 16)
    handle = LibSSH2.channel_forward_listen(self, host, port, out bound_port, queue_maxsize)
    Listener.new(self, handle, bound_port)
  end

  # Allocate a new channel for exchanging data with the server.
  def open_channel(channel_type, window_size, packet_size, message)
    handle = LibSSH2.channel_open(self, channel_type, channel_type.bytesize.to_u32,
                                  window_size.to_u32, packet_size.to_u32,
                                  message, message ? message.bytesize.to_u32 : 0_u32)
    Channel.new self, handle
  end

  # Open new session channel
  def open_session
    open_channel("session", LibSSH2::CHANNEL_WINDOW_DEFAULT, LibSSH2::CHANNEL_PACKET_DEFAULT, nil)
  end

  def open_session
    channel = open_session
    begin
      yield channel
    ensure
      channel.close
    end
  end

  # Tunnel a TCP/IP connection through the SSH transport via the remote host to
  # a third party. Communication from the client to the SSH server remains
  # encrypted, communication from the server to the 3rd party host travels in
  # cleartext.
  def direct_tcpip(host, port, source_host, source_port)
    handle = LibSSH2.channel_direct_tcpip(self, host, port, source_host, source_port)
    Channel.new self, handle
  end

  def finalize
    disconnect if @connected
    LibSSH2.session_free(self)
  end

  private def check_error(code)
    SessionError.check_error(self, code)
  end

  def to_unsafe
    @handle
  end
end
