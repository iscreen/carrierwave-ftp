require 'carrierwave'
require 'carrierwave/storage/ftp/ex_ftp'
require 'carrierwave/storage/ftp/ex_ftptls'

module CarrierWave
  module Storage
    class FTP < Abstract
      def store!(file)
        ftp_file(uploader.store_path).tap { |f| f.store(file) }
      end

      def retrieve!(identifier)
        ftp_file(uploader.store_path(identifier))
      end

      def cache!(new_file)
        new_file.move_to(::File.expand_path(uploader.cache_path, uploader.root), uploader.permissions, uploader.directory_permissions, true)
      rescue Errno::EMLINK, Errno::ENOSPC => e
        raise(e) if @cache_called
        @cache_called = true

        # NOTE: Remove cached files older than 10 minutes
        clean_cache!(600)

        cache!(new_file)
      end

      def retrieve_from_cache!(identifier)
        CarrierWave::SanitizedFile.new(::File.expand_path(uploader.cache_path(identifier), uploader.root))
      end

      def delete_dir!(path)
        if path
          begin
            Dir.rmdir(::File.expand_path(path, uploader.root))
          rescue Errno::ENOENT
            # Ignore: path does not exist
          rescue Errno::ENOTDIR
            # Ignore: path is not a dir
          rescue Errno::ENOTEMPTY, Errno::EEXIST
            # Ignore: dir is not empty
          end
        end
      end

      def clean_cache!(seconds)
        Dir.glob(::File.expand_path(::File.join(uploader.cache_dir, '*'), CarrierWave.root)).each do |dir|
          # generate_cache_id returns key formated TIMEINT-PID(-COUNTER)-RND
          time = dir.scan(/(\d+)-\d+-\d+(?:-\d+)?/).first.map(&:to_i)
          time = Time.at(*time)
          if time < (Time.now.utc - seconds)
            FileUtils.rm_rf(dir)
          end
        end
      end

      private

      def ftp_file(path)
        CarrierWave::Storage::FTP::File.new(uploader, self, path)
      end

      class File
        attr_reader :path

        def initialize(uploader, base, path)
          @uploader = uploader
          @base = base
          @path = path
        end

        def store(file)
          connection do |ftp|
            ftp.mkdir_p(::File.dirname("#{@uploader.ftp_folder}/#{path}"))
            ftp.chdir(::File.dirname("#{@uploader.ftp_folder}/#{path}"))
            ftp.put(file.path, filename)
            chmod(ftp) if @uploader.ftp_chmod
          end
        end

        def chmod(ftp)
          ftp.sendcmd(
            "SITE CHMOD #{@uploader.permissions.to_s(8)} " \
            "#{@uploader.ftp_folder}/#{path}"
          )
        end

        def url
          "#{@uploader.ftp_url}/#{path}"
        end

        def filename(_options = {})
          url.gsub(%r{.*\/(.*?$)}, '\1')
        end

        def to_file
          temp_file = Tempfile.new(filename)
          temp_file.binmode
          connection do |ftp|
            ftp.chdir(::File.dirname("#{@uploader.ftp_folder}/#{path}"))
            ftp.get(filename, nil) do |data|
              temp_file.write(data)
            end
          end
          temp_file.rewind
          temp_file
        end

        def size
          size = nil

          connection do |ftp|
            ftp.chdir(::File.dirname("#{@uploader.ftp_folder}/#{path}"))
            size = ftp.size(filename)
          end

          size
        end

        def exists?
          size ? true : false
        end

        def read
          file = to_file
          content = file.read
          file.close
          content
        end

        def content_type
          @content_type || inferred_content_type
        end

        attr_writer :content_type

        def delete
          connection do |ftp|
            ftp.chdir(::File.dirname("#{@uploader.ftp_folder}/#{path}"))
            ftp.delete(filename)
          end
        rescue StandardError
          nil
        end

        private

        def inferred_content_type
          SanitizedFile.new(path).content_type
        end

        def ftp_conn
          if @uploader.ftp_tls
            ftp = ExFTPTLS.new
            ftp.ssl_context = DoubleBagFTPS.create_ssl_context(
              verify_mode: OpenSSL::SSL::VERIFY_NONE
            )
          else
            ftp = ExFTP.new
          end
          ftp.connect(@uploader.ftp_host, @uploader.ftp_port)
          ftp
        end

        def connection
          ftp = ftp_conn
          ftp.passive = @uploader.ftp_passive
          ftp.login(@uploader.ftp_user, @uploader.ftp_passwd)

          yield ftp
        ensure
          ftp.quit
        end
      end
    end
  end
end

CarrierWave::Storage.autoload :FTP, 'carrierwave/storage/ftp'

module CarrierWave
  module Uploader
    class Base
      add_config :ftp_host
      add_config :ftp_port
      add_config :ftp_user
      add_config :ftp_passwd
      add_config :ftp_folder
      add_config :ftp_url
      add_config :ftp_passive
      add_config :ftp_tls
      add_config :ftp_chmod

      configure do |config|
        config.storage_engines[:ftp] = 'CarrierWave::Storage::FTP'
        config.ftp_host = 'localhost'
        config.ftp_port = 21
        config.ftp_user = 'anonymous'
        config.ftp_passwd = ''
        config.ftp_folder = '/'
        config.ftp_url = 'http://localhost'
        config.ftp_passive = false
        config.ftp_tls = false
        config.ftp_chmod = true
      end
    end
  end
end
