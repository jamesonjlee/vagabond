#encoding: utf-8

require 'vagabond/constants'
require 'etc'

module Vagabond
  module Helpers

    module Base

      SSH_KEY_BASE = '/opt/hw-lxc-config/id_rsa'

      def base_setup(*args)
        @options = Mash.new(@options.dup)
        @vagabondfile = Vagabondfile.new(options[:vagabond_file], :allow_missing)
        Lxc.use_sudo = sudo
        options[:sudo] = sudo
        setup_ui(*args)
        config_args = args.detect{|i| i.is_a?(Hash) && i[:config]} || {}
        @internal_config = InternalConfiguration.new(@vagabondfile, ui, options, config_args[:config] || {})
        configure(:allow_missing) unless args.include?(:no_configure)
        validate_if_required unless args.include?(:no_validate)
        Chef::Log.init('/dev/null') unless options[:debug]
        Settings[:ssh_key] = setup_key!
      end

      def setup_key!
        path = "/tmp/.#{ENV['USER']}_id_rsa"
        unless(File.exists?(path))
          [
            "cp #{SSH_KEY_BASE} #{path}",
            "chown #{ENV['USER']} #{path}",
            "chmod 600 #{path}"
          ].each do |com|
            cmd = build_command(com, :sudo => true)
            cmd.run_command
            cmd.error!
          end
        end
        path
      end

      def configure(*args)
        @config ||= Mash.new
        @config.merge!(vagabondfile.for_node(name, *args))
        @lxc = Lxc.new(internal_config[mappings_key][name] || '____nonreal____')
        if(options[:local_server] && vagabondfile.local_chef_server? && lxc_installed?)
          proto = vagabondfile[:local_chef_server][:zero] ? 'http' : 'https'
          srv_name = internal_config[:mappings][:server] || '____nonreal____'
          srv = Lxc.new(srv_name)
          if(srv.running?)
            knife_config :server_url => "#{proto}://#{srv.container_ip(10, true)}"
          else
            unless(action.to_s == 'status' || name.to_s =='server')
              ui.warn 'Local chef server is not currently running!'
            end
          end
        end
      end

      def validate_if_required
        if(respond_to?(check = "#{action}_validate?".to_sym))
          validate! if send(check)
        else
          validate!
        end
      end

      def sudo
        sudo_val = vagabondfile[:sudo]
        if(sudo_val.nil? || sudo_val.to_s == 'smart')
          if(ENV['rvm_bin_path'] && RbConfig::CONFIG['bindir'].include?(File.dirname(ENV['rvm_bin_path'])))
            sudo_val = 'rvmsudo'
          elsif(Etc.getpwuid.uid == 0)
            sudo_val = false
          else
            sudo_val = true
          end
        end
        case sudo_val
        when FalseClass
          ''
        when String
          "#{sudo_val} "
        else
          'sudo '
        end
      end

      def debug(s)
        ui.info "#{ui.color('DEBUG:', :red, :bold)} #{s}" if options[:debug] && ui
      end

      def setup_ui(*args)
        unless(@ui)
          unless(args.first.is_a?(Chef::Knife::UI))
            Chef::Config[:color] = options[:color].nil? ? true : options[:color]
            @ui = Chef::Knife::UI.new(STDOUT, STDERR, STDIN, {})
          else
            @ui = args.first
          end
          options[:debug] = STDOUT if options[:debug]
          self.class.ui = @ui unless args.include?(:no_class_set)
        end
        @ui
      end

      def execute
        if(public_methods.include?(@action.to_sym))
          send(@action)
        else
          ui.error "Invalid action received: #{@action}"
          raise VagabondError::InvalidAction.new(@action)
        end
      end

      def lxc_installed?
        system('which lxc-info > /dev/null')
      end

      class << self
        def included(klass)
          klass.class_eval do
            class << self
              attr_accessor :ui
            end
            attr_accessor :vagabondfile, :internal_config, :name, :ui, :options, :leftover_args
          end
        end
      end

    end
  end
end
