# Ponyrun

Shebang your pony code

## Usage

- Ensure `ponyrun` is on your `PATH`.
- Write your pony file
- Put a shebang in it, like this:

```pony
#!/usr/bin/env ponyrun

actor Main
  new create(env: Env) =>
    env.out.print("Hello World!")
```

- Make the file executable:

```
$ chmod +x hello.pony
```

- Make sure that `ponyc` is on your `PATH` or point the `PONYC`
  environment variable towards ypur ponyc executable.
- Execute it:

```
$ ./hello.pony
```

### Usage with BINFMT_MISC

- Mount binfmt_misc (if it is not already done on your machine):

```
$ mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
```

- Register ponyrun as `.pony` file interpreter

```
$ echo ':ponylang:E::pony::/path/to/ponyrun:OC' | sudo tee /proc/sys/fs/binfmt_misc/register
```

Now you can remove the shebang from your `.pony` file and it will be executable nonetheless.

```
$ ./hello.pony
```

