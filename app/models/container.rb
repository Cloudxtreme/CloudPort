class Container < ActiveRecord::Base

  belongs_to :build

  has_many :connections, dependent: :delete_all

  before_create :create_docker_container
  after_destroy :delete_docker_container

  SSH_PORT = 22

  # Get reference to a Docker container serving build
  #
  # return [Docker::Container] a reference to Docker container
  def docker_container
    @docker_container ||= Docker::Container.get(docker_container_id)
  end

  # Get container's connection remote addresses (and is connection forwarded or direct)
  #
  # return [Hash] remote connection address/type in form { 'addr:port' => true|false }
  def remotes
    remotes = {}

    probe_remote_connections.each do |l, r|
      remotes[r] = !!!l.match(%r{^[0-9\.]+:#{SSH_PORT}$})
    end

    remotes
  end

  # Synchronize connection records in database with reality
  #
  # return [ActiveRecord::Associations::CollectionProxy] actual connections
  def synchronize_connections!
    connections = self.connections

    connections.each do |c|
      c.disconnect! unless remotes.include?(c.remote)
    end

    remotes.each do |r, f|
      unless self.connections.find_by_remote(r)
        self.connections.build(remote: r, is_forwarded: f).save
      end
    end

    self.connections.reset
  end

  # return [String] direct remote connection address, if any
  def direct_remote
    return nil unless self.connections.direct.first

    self.connections.direct.first.remote
  end

  # return [Array] forwarded [tunneled] remote connection addresses, if any
  def forwarded_remotes
    return nil if self.connections.forwarded.empty?

    self.connections.forwarded.map { |c| c.remote }
  end

  private

  def create_docker_container
    guest_ssh_port     = "#{SSH_PORT}/tcp"
    host_ssh_port      = build.ssh_server_port.to_s
    guest_exposed_port = "#{build.exposed_port.to_s}/tcp"
    host_exposed_port  = build.exposed_port.to_s

    container = Docker::Container.create(
      'Image'        => CloudPort::Application.config.docker_image,
      'ExposedPorts' => {
        guest_ssh_port => {}, guest_exposed_port => {},
      },
      'PortBindings' => {
        guest_ssh_port      => [{ 'HostPort' => host_ssh_port }],
        guest_exposed_port  => [{ 'HostPort' => host_exposed_port }],
      },
      'name' => build.ptu_build_id,
    )

    container.start

    container.exec(
      ['passwd', 'root'],
      stdin: StringIO.new("#{build.ssh_password}\n#{build.ssh_password}")
    )

    container.exec(
      ['bash', '-c', 'echo GatewayPorts yes >>/etc/ssh/sshd_config']
    )

    container.exec(
      ['kill', '-HUP', '1']
    )

    self.docker_container_id = container.id
  end

  def delete_docker_container
    container = docker_container

    container.stop if container.info['State']['Running']
    container.delete
  end

  def remote_connection_filter_regex
    %r{\s+[0-9\.]+:(#{SSH_PORT}|#{build.exposed_port.to_s})\s+[0-9\.]+:[0-9]+\s+ESTABLISHED$}
  end

  def netstat
    docker_container.exec(['netstat', '-n', '|', 'grep '])[0][0].split(%r{\n}).grep(remote_connection_filter_regex)
  end

  def probe_remote_connections
    netstat.map { |l| [l.split[3], l.split[4]] }
  end

end