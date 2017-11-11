require "digest"
require "uri"
require "tempfile"

module MCollective
  module Util
    class TasksSupport
      attr_reader :cache_dir, :choria

      def initialize(choria, cache_dir=nil)
        @choria = choria
        @cache_dir = cache_dir || @choria.get_option("choria.tasks_cache")
      end

      # Path to binaries like wrappers etc
      def bin_path
        if Util.windows?
          'C:\Program Files\Puppet Labs\Puppet\bin'
        else
          "/opt/puppetlabs/puppet/bin"
        end
      end

      # Path to the task wrapper executable
      #
      # @return [String]
      def wrapper_path
        if Util.windows?
          File.join(bin_path, "task_wrapper.exe")
        else
          File.join(bin_path, "task_wrapper")
        end
      end

      # Path to the powershell shim for powershell input method
      #
      # @return [String]
      def ps_shim_path
        File.join(bin_path, "PowershellShim.ps1")
      end

      # Expands the path into a platform specific version
      #
      # @see https://github.com/puppetlabs/puppet-specifications/tree/730a2aa23e58b93387d194dbac64af508bdeab01/tasks#task-execution
      # @param path [Array<String>] the path to the executable and any arguments
      # @raise [StandardError] when execution of a specific file is not supported
      def platform_specific_command(path)
        return [path] unless Util.windows?

        extension = File.extname(path)

        # https://github.com/puppetlabs/pxp-agent/blob/3e7cada3cedf7f78703781d44e70010d0c5ad209/lib/src/modules/task.cc#L98-L107
        case extension
        when ".rb"
          ["ruby", path]
        when ".pp"
          ["puppet", "apply", path]
        when ".ps1"
          ["powershell", "-NoProfile", "-NonInteractive", "-NoLogo", "-ExecutionPolicy", "Bypass", "-File", path]
        else
          [path]
        end
      end

      # Given a task description checks all files are correctly cached
      #
      # @note this checks all files, though for now there's only ever one file
      # @see #task_file?
      # @param files [Array] files list
      # @return [Boolean]
      def cached?(files)
        files.map {|f| task_file?(f)}.all?
      end

      # Given a task spec figures out the input method
      #
      # @param task [Hash] task specification
      # @return ["powershell", "both", "stdin", "environment"]
      def task_input_method(task)
        # the spec says only 1 executable, no idea what the point of the 'files' is
        file_extension = File.extname(task["files"][0]["filename"])

        input_method = task["input_method"]
        input_method = "powershell" if input_method.nil? && file_extension == ".ps1"
        input_method ||= "both"

        input_method
      end

      # Given a task spec figures out the command to run using the wrapper
      #
      # @param task [Hash] task specification
      # @return [String] path to the command
      def task_command(task)
        file_spec = task["files"][0]
        file_name = File.join(task_dir(file_spec), file_spec["filename"])

        command = platform_specific_command(file_name)

        command.unshift(ps_shim_path) if task_input_method(task) == "powershell"

        command
      end

      # Given a task spec calculates the correct environment hash
      #
      # @param task [Hash] task specification
      # @return [Hash]
      def task_environment(task)
        environment = {}

        return environment unless ["both", "environment"].include?(task_input_method(task))

        JSON.parse(task["input"]).each do |k, v|
          environment["PT_%s" % k] = v
        end

        environment
      end

      # Generate the path to the spool for a specific request
      #
      # @param requestid [String] task id
      # @return [String] directory
      def request_spooldir(requestid)
        File.join(choria.tasks_spool_dir, requestid)
      end

      # Generates the spool path and create it
      #
      # @param requestid [String] unique mco request id
      # @return [String] path to the spool dir
      # @raise [StandardError] should it not be able to make the directory
      def create_request_spooldir(requestid)
        dir = request_spooldir(requestid)

        FileUtils.mkdir_p(dir, :mode => 0o0750)

        dir
      end

      # Given a task spec, creates the standard input
      #
      # @param task [Hash] task specification
      # @return [Hash, nil]
      def task_input(task)
        task["input"] if ["both", "powershell", "stdin"].include?(task_input_method(task))
      end

      # Runs the wrapper command detached from mcollective
      #
      # We always detach we have no idea how long these tasks will run
      # since people can do whatever they like, we'll then check them
      # till the agent timeout but if timeout happens they keep running
      #
      # The idea is that UI will in that case present the user with a request
      # id - which is also the spool name - and the user can later come and
      # act on these tasks either by asking for their status or perhaps killing
      # them?
      #
      # @param command [Array<String>] command to run
      # @param environment [Hash] environment to run with
      # @param stdin [String] stdin to send to the command
      # @param spooldir [String] path to the spool for this specific request
      # @return [Integer] the pid that was spawned
      def spawn_command(command, environment, stdin, spooldir)
        wrapper_input = File.join(spooldir, "wrapper_stdin")
        wrapper_stdout = File.join(spooldir, "wrapper_stdout")
        wrapper_stderr = File.join(spooldir, "wrapper_stderr")
        wrapper_pid = File.join(spooldir, "wrapper_pid")

        options = {
          :chdir => "/",
          :in => :close,
          :out => wrapper_stdout,
          :err => wrapper_stderr
        }

        if stdin
          File.open(wrapper_input, "w") {|i| i.print(stdin) }
          options[:in] = wrapper_input
        end

        pid = Process.spawn(environment, command, options)

        sleep 0.1 until File.exist?(wrapper_stdout)

        File.open(wrapper_pid, "w") {|p| p.write(pid)}

        Process.detach(pid)

        pid
      end

      # Determines if a task already ran by checkinf if its spool exist
      #
      # @param requestid [String] request id for the task
      # @return [Boolean]
      def task_ran?(requestid)
        File.directory?(request_spooldir(requestid))
      end

      # Determines if a task is completed
      #
      # Tasks are run under the wrapper which will write the existcode
      # to a file only after the command have exited, so this will wait
      # for that to appear
      #
      # @param requestid [String] request id for the task
      # @return [Boolean]
      def task_complete?(requestid)
        exitcode = File.join(request_spooldir(requestid), "exitcode")
        wrapper_stderr = File.join(request_spooldir(requestid), "wrapper_stderr")

        File.exist?(wrapper_stderr) && file_size(wrapper_stderr) > 0 || File.exist?(exitcode) && file_size(exitcode) > 0
      end

      # Waits for a task to complete
      #
      # @param requestid [String] request id for the task
      def wait_for_task_completion(requestid)
        sleep 0.1 until task_complete?(requestid)
      end

      # Given a task spec runs it via the Puppet wrappers
      #
      # The task is run in the background and this method waits for it to
      # finish, but should the thread this method runs in be killed the process
      # will continue and one can later check again using the request id
      #
      # @note before this should be run be sure to download the tasks first
      # @param task [Hash] task specification
      # @param requestid [String] the task requestid
      # @param wait [Boolean] should the we wait for the task to complete
      # @return [Hash] the task result as per {#task_result}
      # @raise [StandardError] when calling the wrapper fails etc
      def run_task_command(requestid, task, wait=true)
        raise("The task wrapper %s does not exist, please upgrade Puppet" % wrapper_path) unless File.exist?(wrapper_path)
        raise("Task %s is not available or does not match the specification, please download it" % task["task"]) unless cached?(task["files"])
        raise("Task spool for request %s already exist, cannot rerun", requestid) if task_ran?(requestid)

        command = task_command(task)
        spool = create_request_spooldir(requestid)

        Log.debug("Trying to spawn task %s in spool %s using command %s" % [task["task"], spool, command])

        wrapper_input = {
          "executable" => command[0],
          "arguments" => command[1..-1],
          "input" => task_input(task),
          "stdout" => File.join(spool, "stdout"),
          "stderr" => File.join(spool, "stderr"),
          "exitcode" => File.join(spool, "exitcode")
        }

        pid = spawn_command(wrapper_path, task_environment(task), wrapper_input.to_json, spool)

        Log.info("Spawned task %s in spool %s with pid %s" % [task["task"], spool, pid])

        wait_for_task_completion(requestid) if wait

        task_status(requestid)
      end

      # Determines how long a task ran for
      #
      # Tasks that had wrapper failures will have a 0 run time, still
      # running tasks will calculate runtime till now and so increase on
      # each invocation
      #
      # @param requestid [String] the request if for the task
      # @return [Float]
      def task_runtime(requestid)
        spool = request_spooldir(requestid)
        wrapper_stderr = File.join(spool, "wrapper_stderr")
        wrapper_pid = File.join(spool, "wrapper_pid")
        exitcode = File.join(spool, "exitcode")

        if task_complete?(requestid) && File.exist?(exitcode)
          Float(File::Stat.new(exitcode).mtime - File::Stat.new(wrapper_pid).mtime)
        elsif task_complete?(requestid) && file_size(wrapper_stderr) > 0
          0.0
        else
          Float(Time.now - File::Stat.new(wrapper_pid).mtime)
        end
      end

      # Determines the task status for given request
      #
      # @param requestid [String] request id for the task
      # @return [Hash] the task status
      def task_status(requestid)
        raise("Task %s have not been requested" % requestid) unless task_ran?(requestid)

        spool = request_spooldir(requestid)
        stdout = File.join(spool, "stdout")
        stderr = File.join(spool, "stderr")
        exitcode = File.join(spool, "exitcode")
        wrapper_stderr = File.join(spool, "wrapper_stderr")
        wrapper_pid = File.join(spool, "wrapper_pid")

        result = {
          "spool" => spool,
          "stdout" => "",
          "stderr" => "",
          "exitcode" => 127,
          "runtime" => task_runtime(requestid),
          "start_time" => Time.at(0).utc,
          "wrapper_spawned" => false,
          "wrapper_error" => "",
          "wrapper_pid" => nil,
          "completed" => task_complete?(requestid)
        }

        result["exitcode"] = Integer(File.read(exitcode)) if File.exist?(exitcode)

        if task_ran?(requestid)
          result["stdout"] = File.read(stdout) if File.exist?(stdout)
          result["stderr"] = File.read(stderr) if File.exist?(stderr)
          result["wrapper_spawned"] = File.exist?(wrapper_stderr) && file_size(wrapper_stderr) == 0

          if File.exist?(wrapper_stderr) && file_size(wrapper_stderr) > 0
            result["wrapper_error"] = File.read(wrapper_stderr)
            result["completed"] = true
          end

          if File.exist?(wrapper_pid) && file_size(wrapper_pid) > 0
            result["start_time"] = File::Stat.new(wrapper_pid).mtime.utc
            result["wrapper_pid"] = Integer(File.read(wrapper_pid))
          end
        end

        result
      end

      # Retrieves the list of known tasks in an environment
      #
      # @param environment [String] the environment to query
      # @return [Hash] the v3 task list
      # @raise [StandardError] on http failure
      def tasks(environment)
        resp = http_get("/puppet/v3/tasks?environment=%s" % [environment])

        raise("Failed to retrieve task list: %s: %s" % [$!.class, $!.to_s]) unless resp.code == "200"

        tasks = JSON.parse(resp.body)

        tasks.sort_by {|t| t["name"]}
      end

      # Retrieves the list of known task names
      #
      # @param environment [String] the environment to query
      # @return [Array<String>] list of task names
      # @raise [StandardError] on http failure
      def task_names(environment)
        tasks(environment).map {|t| t["name"]}
      end

      # Parse a task name like module::task into it's 2 pieces
      #
      # @param task [String]
      # @return [Array<String>] 2 part array, first the module name then the task name
      # @raise [StandardError] for invalid task names
      def parse_task(task)
        parts = task.split("::")

        parts << "init" if parts.size == 1

        parts
      end

      # Determines the cache path for a task file
      #
      # @param file [Hash] a file hash as per the task metadata
      # @return [String] the directory the file would go into
      def task_dir(file)
        File.join(cache_dir, file["sha256"])
      end

      # Determines the full path to cache the task file into
      #
      # @param file [Hash] a file hash as per the task metadata
      # @return [String] the file path to cache into
      def task_file_name(file)
        File.join(task_dir(file), file["filename"])
      end

      # Does a HTTP GET against the Puppet Server
      #
      # @param path [String] the path to get
      # @param headers [Hash] headers to passs
      # @return [Net::HTTPRequest]
      def http_get(path, headers={}, &blk)
        transport = choria.https(choria.puppet_server, true)
        request = choria.http_get(path)

        headers.each do |k, v|
          request[k] = v
        end

        transport.request(request, &blk)
      end

      # Requests a task metadata from Puppet Server
      #
      # @param task [String] a task name like module::task
      # @param environment [String] the puppet environmnet like production
      # @return [Hash] the metadata according to the v3 spec
      # @raise [StandardError] when the request failed
      def task_metadata(task, environment)
        parsed = parse_task(task)
        path = "/puppet/v3/tasks/%s/%s?environment=%s" % [parsed[0], parsed[1], environment]

        resp = http_get(path)

        raise("Failed to request task metadata: %s: %s" % [resp.code, resp.body]) unless resp.code == "200"

        JSON.parse(resp.body)
      end

      # Calculates a hex digest SHA256 for a specific file
      #
      # @param file_path [String] a full path to the file to check
      # @return [String]
      # @raise [StandardError] when the file does not exist
      def file_sha256(file_path)
        Digest::SHA256.file(file_path).hexdigest
      end

      # Determines the file size of a specific file
      #
      # @param file_path [String] a full path to the file to check
      # @return [Integer] bytes
      # @raise [StandardError] when the file does not exist
      def file_size(file_path)
        File.stat(file_path).size
      end

      # Validates a task cache file
      #
      # @param file [Hash] a file hash as per the task metadata
      # @return [Boolean]
      def task_file?(file)
        file_name = task_file_name(file)

        Log.debug("Checking if file %s is cached using %s" % [file_name, file.pretty_inspect])

        return false unless File.directory?(task_dir(file))
        return false unless File.exist?(file_name)
        return false unless file_size(file_name) == file["size_bytes"]
        return false unless file_sha256(file_name) == file["sha256"]

        true
      end

      # Attempts to download and cache the file
      #
      # @note Does not first check if the cache is ok, unconditionally downloads
      # @see #task_file?
      # @param file [Hash] a file hash as per the task metadata
      # @raise [StandardError] when downloading fails
      def cache_task_file(file)
        path = [file["uri"]["path"], URI.encode_www_form(file["uri"]["params"])].join("?")

        file_name = task_file_name(file)

        Log.debug("Caching task to %s" % file_name)

        http_get(path, "Accept" => "application/octet-stream") do |resp|
          raise("Failed to request task content %s: %s: %s" % [path, resp.code, resp.body]) unless resp.code == "200"

          FileUtils.mkdir_p(task_dir(file), :mode => 0o0750)

          task_file = Tempfile.new("tasks_%s" % file["filename"])
          task_file.binmode

          resp.read_body do |segment|
            task_file.write(segment)
          end

          task_file.close

          FileUtils.chmod(0o0750, task_file.path)
          FileUtils.mv(task_file.path, file_name)
        end
      end

      # Downloads all the files in a task
      #
      # @param files [Array] the files description
      # @return [Boolean] indicating download success
      # @raise [StandardError] on download failures
      def download_task(task)
        download_files(task["files"])
      end

      # Downloads and caches a file set
      #
      # @param files [Array] the files description
      # @return [Boolean] indicating download success
      # @raise [StandardError] on download failures
      def download_files(files)
        Log.info("Downloading %d task files" % files.size)

        files.each do |file|
          next if task_file?(file)

          try = 0

          begin
            return false if try == 2

            try += 1

            Log.debug("Downloading task file %s (try %s/2)" % [file["filename"], try])

            cache_task_file(file)
          rescue
            Log.error(msg = "Could not download task file: %s: %s" % [$!.class, $!.to_s])

            sleep 0.1

            retry if try < 2

            raise(msg)
          end
        end

        true
      end
    end
  end
end
