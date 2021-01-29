require 'carrierwave'
require 'carrierwave/storage/ftp/ex_sftp'

module CarrierWave
  module Storage
    class SFTP < Abstract
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
        CarrierWave::Storage::SFTP::File.new(uploader, self, path)
      end

      class File
        attr_reader :path

        def initialize(uploader, base, path)
          @uploader = uploader
          @base = base
          @path = path
        end

        def store(file)
          connection do |sftp|
            sftp.mkdir_p!(::File.dirname(full_path))
            sftp.upload!(file.path, full_path)
          end
        end

        def url
          "#{@uploader.sftp_url}/#{path}"
        end

        def filename(_options = {})
          url.gsub(%r{.*\/(.*?$)}, '\1')
        end

        def to_file
          temp_file = Tempfile.new(filename)
          temp_file.binmode
          connection do |sftp|
            sftp.download!(full_path, temp_file)
          end
          temp_file.open
          temp_file.rewind
          temp_file
        end

        def size
          size = nil

          connection do |sftp|
            size = sftp.stat!(full_path).size
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
          connection do |sftp|
            sftp.remove!(full_path)
          end
        rescue StandardError
          nil
        end

        private

        def inferred_content_type
          SanitizedFile.new(path).content_type
        end

        def use_ssl?
          @uploader.sftp_url.start_with?('https')
        end

        def full_path
          "#{@uploader.sftp_folder}/#{path}"
        end

        def connection
          sftp = Net::SFTP.start(
            @uploader.sftp_host,
            @uploader.sftp_user,
            @uploader.sftp_options
          )
          yield sftp
          sftp.close_channel
        end
      end
    end
  end
end

CarrierWave::Storage.autoload :SFTP, 'carrierwave/storage/sftp'

module CarrierWave
  module Uploader
    class Base
      add_config :sftp_host
      add_config :sftp_user
      add_config :sftp_options
      add_config :sftp_folder
      add_config :sftp_url

      configure do |config|
        config.storage_engines[:sftp] = 'CarrierWave::Storage::SFTP'
        config.sftp_host = 'localhost'
        config.sftp_user = 'anonymous'
        config.sftp_options = {}
        config.sftp_folder = ''
        config.sftp_url = 'http://localhost'
      end
    end
  end
end
