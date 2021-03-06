module Listen
  class File
    def self.change(record, path)
      lstat = path.lstat

      data = { mtime: lstat.mtime.to_f, mode: lstat.mode }

      record_data = record.file_data(path)

      if record_data.empty?
        record.async.set_path(:file, path, data)
        return :added
      end

      if data[:mode] != record_data[:mode]
        record.async.set_path(:file, path, data)
        return :modified
      end

      if data[:mtime] != record_data[:mtime]
        record.async.set_path(:file, path, data)
        return :modified
      end

      unless /1|true/ =~ ENV['LISTEN_GEM_DISABLE_HASHING']
        if self.inaccurate_mac_time?(lstat)
          # Check if change happened within 1 second (maybe it's even
          # too much, e.g. 0.3-0.5 could be sufficient).
          #
          # With rb-fsevent, there's a (configurable) latency between
          # when file was changed and when the event was triggered.
          #
          # If a file is saved at ???14.998, by the time the event is
          # actually received by Listen, the time could already be e.g.
          # ???15.7.
          #
          # And since Darwin adapter uses directory scanning, the file
          # mtime may be the same (e.g. file was changed at ???14.001,
          # then at ???14.998, but the fstat time would be ???14.0 in
          # both cases).
          #
          # If change happend at ???14.999997, the mtime is 14.0, so for
          # an mtime=???14.0 we assume it could even be almost ???15.0
          #
          # So if Time.now.to_f is ???15.999998 and stat reports mtime
          # at ???14.0, then event was due to that file'd change when:
          #
          # ???15.999997 - ???14.999998 < 1.0s
          #
          # So the "2" is "1 + 1" (1s to cover rb-fsevent latency +
          # 1s maximum difference between real mtime and that recorded
          # in the file system)
          #
          if data[:mtime].to_i + 2 > Time.now.to_f
            begin
              md5 = Digest::MD5.file(path).digest
              record.async.set_path(:file, path, data.merge(md5: md5))
              :modified if record_data[:md5] && md5 != record_data[:md5]

            rescue SystemCallError
              # ignore failed md5
            end
          end
        end
      end
    rescue SystemCallError
      record.async.unset_path(path)
      :removed
    rescue
      Celluloid::Logger.debug "lstat failed for: #{path} (#{$!})"
      raise
    end

    def self.inaccurate_mac_time?(stat)
      # 'mac' means Modified/Accessed/Created

      # Since precision depends on mounted FS (e.g. you can have a FAT partiion
      # mounted on Linux), check for fields with a remainder to detect this

      [stat.mtime, stat.ctime, stat.atime].map(&:usec).all?(&:zero?)
    end
  end
end
