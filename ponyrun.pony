use "files"
use "cli"
use "process"
use "collections"
use "signals"
use "debug"

primitive FileCopy

  fun copy(from: FilePath, to_file: FilePath): Bool =>
    match OpenFile(from)
    | let source: File =>
      match CreateFile(to_file)
      | let target: File =>
        var gimme_more = true
        while gimme_more and (source.errno() is FileOK) and (target.errno() is FileOK) do
          let source_line = source.read(1024)
          try
            if (source_line(0)? == '#') and (source_line(1)? == '!') then
              // skip until newline
              let shebang_newline = source_line.find('\n')?
              source_line.trim_in_place(shebang_newline + 1, source_line.size())
            end
          end
          gimme_more = target.write(consume source_line)
        end
        true
      else
        Debug("could not open " + to_file.path + " for writing")
        false
      end
    else
      Debug("could not open " + from.path + " for reading")
      false
    end

primitive Environ
  fun apply(env: Env): Map[String val, String val] val =>
    let map = recover trn Map[String val, String val] end
    for kv in env.vars.values() do
      let splitted = kv.split_by("=")
      try
        map(splitted(0)?) = splitted(1)?
      end
    end
    consume map

primitive Ponyc


  fun find(env: Env): FilePath ? =>
    let envvars = Environ(env)
    if envvars.contains("PONYC") then
      let path = FilePath(env.root as AmbientAuth, envvars("PONYC")?)?
      if path.exists() then
        return path
      end
    elseif envvars.contains("PATH") then
      for path_entry in Path.split_list(envvars("PATH")?).values() do
        let ponyc_candidate = FilePath(env.root as AmbientAuth, Path.join(path_entry, "ponyc"))?
        Debug("trying " + ponyc_candidate.path)
        if ponyc_candidate.exists() then
          return ponyc_candidate
        end
      end
    end
    Debug("could not find ponyc")
    error

actor Main

  new create(env: Env) =>
    try
      let auth = env.root as AmbientAuth
      let cs =
        try
          CommandSpec.leaf(
            "ponyrun",
            "Shebang your pony",
            [],
            [
              ArgSpec.string("file", "pony source file")
            ])? .> add_help()?
        else
          Debug("could not create command spec")
          env.exitcode(1)
          return
        end
      let cmd =
        match CommandParser(cs).parse(env.args, env.vars)
        | let c: Command => c
        | let ch: CommandHelp =>
          ch.print_help(env.out)
          env.exitcode(0)
          return
        | let se: SyntaxError =>
          env.err.print(se.string())
          env.exitcode(1)
          return
        end
      let file_arg = cmd.arg("file").string()
      let source_file =
        try
          FilePath(auth, file_arg)?
        else
          env.err.print("unable to access " + file_arg)
          env.exitcode(1)
          return
        end
      let ponyc =
        try
          Ponyc.find(env)?
        else
          env.err.print("could not find ponyc on the PATH or with PONYC")
          env.exitcode(1)
          return
        end
      let envvars = Environ(env)
      let tmp_dir_base =
        FilePath(
          auth,
          try
            envvars("TMPDIR")?
          else
            "/tmp"
          end)?
      Debug("tmp dir is " + tmp_dir_base.path)

      // create temp directory
      let tmp_dir =
        try
          FilePath.mkdtemp(
            tmp_dir_base,
            "ponyrun_" + Path.base(file_arg, false))?
        else
          env.err.print("could not create tmp dir")
          env.exitcode(1)
          return
        end
      Debug("created " + tmp_dir.path)

      let ctrlc_handler = SignalHandler(
        object iso is SignalNotify
        fun ref apply(count: U32): Bool =>
          if count > 0 then
            tmp_dir.remove()
            false
          end
          true
        end,
        Sig.int())

      let tmp_pony_dir = tmp_dir.join("src")?
      if not tmp_pony_dir.mkdir() then
        env.err.print("could not create tmp pony dir: " + tmp_pony_dir.path)

        tmp_dir.remove()
        env.exitcode(1)
        return
      end

      // copy source_file there
      let compile_source_path = tmp_pony_dir.join("source.pony")?
      if not FileCopy.copy(source_file, compile_source_path) then
        env.err.print("could not copy source file to " + compile_source_path.path)

        tmp_dir.remove()
        env.exitcode(1)
        return
      end

      let resulting_binary_path = tmp_dir.join(Path.base(file_arg, false))?
      let notifier =
        object iso is ProcessNotify
          // TODO: - add possibility to hand through args to the pony program
          //       - support writing to stdin
          fun ref stdout(process: ProcessMonitor ref, data: Array[U8] iso) =>
            Debug(consume data)
          fun ref stderr(process: ProcessMonitor ref, data: Array[U8] iso) =>
            Debug(consume data)
          fun ref failed(process: ProcessMonitor ref, err: ProcessError) =>
            env.err.print("ponyc failed")
          fun ref dispose(process: ProcessMonitor ref, child_exit_code: I32) =>
            Debug("ponyc finished with " + child_exit_code.string())
            if not resulting_binary_path.exists() then
              env.err.print("ponyc failed compiling the binary")
              tmp_dir.remove()
              env.exitcode(1)
              return
            end
            Debug("starting " + resulting_binary_path.path)
            // run the resulting binary
            let ppm = ProcessMonitor(
              auth,
              auth,
              object iso is ProcessNotify
                fun ref stdout(process: ProcessMonitor ref, data: Array[U8] iso) =>
                  Debug("received something")
                  env.out.write(consume data)
                fun ref stderr(process: ProcessMonitor ref, data: Array[U8] iso) =>
                  env.err.write(consume data)
                fun ref failed(process: ProcessMonitor ref, err: ProcessError) =>
                  env.err.print(resulting_binary_path.path + " failed")
                fun ref dispose(process: ProcessMonitor ref, child_exit_code: I32) =>
                  env.exitcode(child_exit_code)
                  tmp_dir.remove()
                  Debug("DONE")
              end,
              resulting_binary_path,
              recover
              Array[String](1).>push(Path.base(resulting_binary_path.path)) end,
              env.vars)
            ppm.done_writing()

        end
      let args: Array[String] iso = recover Array[String](4) end
      args
        .>push("ponyc")
        .>push("--output=" + tmp_dir.path)
        .>push("--bin-name=" + Path.base(file_arg, false))
        .>push(tmp_pony_dir.path)

      let pm = ProcessMonitor(
        auth,
        auth,
        consume notifier,
        ponyc,
        consume args,
        env.vars)
      pm.done_writing()
    else
      env.err.print("some unspecific error happened!")
      env.exitcode(1)
    end




